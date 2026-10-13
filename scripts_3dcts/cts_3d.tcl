# =========================================
# True 3D CTS — Useful-Skew Clock Tree Synthesis for F2F 3D ICs
#
# Flow:
#   Phase 1  — Balanced CTS + propagated-clock timing extraction
#   Phase 2  — LP-TNS solve (delivery-constrained, hold-safe skew targets)
#   Phase 3  — Useful-skew CTS (per-tier H-tree + cascaded TAP delivery)
#   Phase 3b — Post-CTS LP + iterative TAP refinement (optional)
#   Phase 4  — repair_clock_nets (tier-aware) + DPL legalization
#   Phase 5  — Buffer sizing (Liberty-based LP)
#   Phase 6  — Hold repair (data-path delay insertion)
# =========================================

utl::set_metrics_stage "cts_3d__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

foreach required_env {RESULTS_DIR REPORTS_DIR LOG_DIR OBJECTS_DIR CTS3D_WORK_DIR SCRIPTS_3DCTS_DIR} {
  if {![info exists ::env($required_env)] || $::env($required_env) eq ""} {
    error "3DCTS requires environment variable $required_env"
  }
}

file mkdir $::env(CTS3D_WORK_DIR)
file mkdir $::env(REPORTS_DIR)
file mkdir $::env(LOG_DIR)

foreach input_name {3_place.def 3_place.v 3_place.sdc} {
  set input_path [file join $::env(RESULTS_DIR) $input_name]
  if {![file isfile $input_path]} {
    error "3DCTS input is missing: $input_path"
  }
}

# Remove only this stage's formal outputs.  A failed rerun must not leave an
# older 4_cts handoff that looks like the result of the current invocation.
foreach output_name {4_cts.def 4_cts.v 4_cts.sdc 4_cts.odb} {
  set output_path [file join $::env(RESULTS_DIR) $output_name]
  if {[file exists $output_path]} {
    file delete -force $output_path
  }
}

# The current TaiWei loader no longer reads an associated DEF after loading a
# Verilog file.  Load the placement DEF directly so coordinates and netlist are
# taken from the official placement handoff.
load_design 3_place.def 3_place.sdc "Starting 3D CTS..."

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/floorplan_utils.tcl
source $::env(SCRIPTS_3DCTS_DIR)/platform_config.tcl

# 3D Construction Policy Engine (Item 1, ): when CTS_POLICY_ENGINE=1,
# measure design structure from the loaded ODB and decide the 3D-CTS levers
# algorithmically (HETEROGENEOUS_3D, CTS_NO_INSERTION_DELAY,
# CTS_ENABLE_UNIFIED_TREE, CTS_ENABLE_PER_TIER_CTS, CTS_ENABLE_DIR_SKEW).
# Explicitly-set env vars win (logged as OVERRIDE in cts_policy_decisions.csv).
# Default off -> byte-identical flow.
if {[info exists ::env(CTS_POLICY_ENGINE)] && $::env(CTS_POLICY_ENGINE) == 1} {
  source $::env(SCRIPTS_3DCTS_DIR)/policy_engine.tcl
  cpe::run
}

# Enable native getTier() from master name suffixes (*_bottom / *_upper)

# Clamp OpenSTA infinity WNS to 0.0 (timing met → no violating paths)
proc clamp_wns {val} {
  if {$val > 1e20} { return 0.0 }
  return $val
}

# Timing summary helper — call at each stage checkpoint
proc report_timing_summary {label} {
  set s_tns [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]
  set s_wns [expr {[clamp_wns [sta::worst_slack_cmd "max"]] * 1e12}]
  set h_tns [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
  set h_wns [expr {[clamp_wns [sta::worst_slack_cmd "min"]] * 1e12}]
  puts [format "  \[%s\] Setup TNS=%.1f ps  WNS=%.1f ps | Hold TNS=%.1f ps  WNS=%.1f ps" \
    $label $s_tns $s_wns $h_tns $h_wns]
  return [list $s_tns $s_wns $h_tns $h_wns]
}

# =========================================
# Tcl IO Edge Extraction (PI→FF + FF→PO)
# Fallback when C++ extraction is unavailable.
# Output: CSV with per-FF worst IO slacks across all ports.
# =========================================
proc extract_io_timing_edges {output_csv {num_paths 10000}} {
  puts "  Extracting IO timing edges (PI→FF + FF→PO)..."

  array set pi_setup {}
  array set pi_hold {}
  array set pi_port {}
  array set po_setup {}
  array set po_hold {}
  array set po_port {}

  # Pass 1: PI→FF setup
  if {[catch {
    set paths [find_timing_paths -from [all_inputs] -to [all_registers] \
                -sort_by_slack -path_delay max -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff [regsub {/[^/]+$} $end_pin ""]
      set port [regsub {/[^/]+$} $start_pin ""]
      if {![info exists pi_setup($ff)] || $slack_ns < $pi_setup($ff)} {
        set pi_setup($ff) $slack_ns
        set pi_port($ff) $port
      }
    }
  } err]} {
    puts "  Warning: PI→FF setup extraction: $err"
  }
  puts "  PI→FF setup: [array size pi_setup] unique FFs"

  # Pass 2: PI→FF hold
  if {[catch {
    set paths [find_timing_paths -from [all_inputs] -to [all_registers] \
                -sort_by_slack -path_delay min -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set ff [regsub {/[^/]+$} $end_pin ""]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set port [regsub {/[^/]+$} $start_pin ""]
      if {![info exists pi_hold($ff)] || $slack_ns < $pi_hold($ff)} {
        set pi_hold($ff) $slack_ns
        if {![info exists pi_port($ff)]} { set pi_port($ff) $port }
      }
    }
  } err]} {
    puts "  Warning: PI→FF hold extraction: $err"
  }
  puts "  PI→FF hold: [array size pi_hold] unique FFs"

  # Pass 3: FF→PO setup
  if {[catch {
    set paths [find_timing_paths -from [all_registers] -to [all_outputs] \
                -sort_by_slack -path_delay max -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff [regsub {/[^/]+$} $start_pin ""]
      set port [regsub {/[^/]+$} $end_pin ""]
      if {![info exists po_setup($ff)] || $slack_ns < $po_setup($ff)} {
        set po_setup($ff) $slack_ns
        set po_port($ff) $port
      }
    }
  } err]} {
    puts "  Warning: FF→PO setup extraction: $err"
  }
  puts "  FF→PO setup: [array size po_setup] unique FFs"

  # Pass 4: FF→PO hold
  if {[catch {
    set paths [find_timing_paths -from [all_registers] -to [all_outputs] \
                -sort_by_slack -path_delay min -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff [regsub {/[^/]+$} $start_pin ""]
      set port [regsub {/[^/]+$} $end_pin ""]
      if {![info exists po_hold($ff)] || $slack_ns < $po_hold($ff)} {
        set po_hold($ff) $slack_ns
        if {![info exists po_port($ff)]} { set po_port($ff) $port }
      }
    }
  } err]} {
    puts "  Warning: FF→PO hold extraction: $err"
  }
  puts "  FF→PO hold: [array size po_hold] unique FFs"

  # Write aggregated CSV
  set fp [open $output_csv w]
  puts $fp "edge_type,port_name,ff_name,slack_setup_ns,slack_hold_ns"

  set count 0
  set all_pi_ffs [lsort -unique [concat [array names pi_setup] [array names pi_hold]]]
  foreach ff $all_pi_ffs {
    set s_setup [expr {[info exists pi_setup($ff)] ? $pi_setup($ff) : ""}]
    set s_hold  [expr {[info exists pi_hold($ff)]  ? $pi_hold($ff)  : ""}]
    set port    [expr {[info exists pi_port($ff)]   ? $pi_port($ff)  : ""}]
    puts $fp "PI_TO_FF,$port,$ff,$s_setup,$s_hold"
    incr count
  }

  set all_po_ffs [lsort -unique [concat [array names po_setup] [array names po_hold]]]
  foreach ff $all_po_ffs {
    set s_setup [expr {[info exists po_setup($ff)] ? $po_setup($ff) : ""}]
    set s_hold  [expr {[info exists po_hold($ff)]  ? $po_hold($ff)  : ""}]
    set port    [expr {[info exists po_port($ff)]   ? $po_port($ff)  : ""}]
    puts $fp "FF_TO_PO,$port,$ff,$s_setup,$s_hold"
    incr count
  }

  close $fp
  puts "  Total IO edges: $count (PI→FF: [llength $all_pi_ffs], FF→PO: [llength $all_po_ffs])"
}

# =========================================
# Dynamic buf_list: select characterization buffer based on tier FF ratio.
# TechChar uses highest-maxcap buffer → must match the die's primary technology.
# =========================================
proc build_buf_list_3d {} {
  set _block [ord::get_db_block]
  set _bottom_ff 0
  set _upper_ff 0
  foreach _inst [$_block getInsts] {
    set _mname [[$_inst getMaster] getName]
    if {![regexp -nocase {DFF|SDFF} $_mname]} { continue }
    if {[string match "*bottom*" $_mname]} {
      incr _bottom_ff
    } elseif {[string match "*upper*" $_mname]} {
      incr _upper_ff
    }
  }
  set _total [expr {$_bottom_ff + $_upper_ff}]
  set _is_hetero [expr {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)}]

  if {$_is_hetero} {
    # Heterogeneous: upper-only to ensure correct wireSegmentUnit
    set _result "$::env(CTS_BUF_UPPER)"
    puts "  buf_list = upper-only (heterogeneous, $_bottom_ff bottom FFs)"
  } elseif {$_total > 0 && [expr {double($_bottom_ff) / $_total}] < 0.5} {
    set _result "$::env(CTS_BUF_UPPER)"
    puts "  buf_list = upper-only ($_bottom_ff/$_total bottom FFs < 50%)"
  } else {
    set _result "$::env(CTS_BUF_BOTTOM) $::env(CTS_BUF_UPPER)"
    puts "  buf_list = both-tier ($_bottom_ff/$_total bottom FFs)"
  }
  return $_result
}

# =========================================
# Auto-detect clock wire RC from platform setRC.tcl
# Sets CTS_RELAY_RW_PER_UM / CTS_RELAY_CW_PER_UM for Elmore x_useful model.
# =========================================
proc auto_set_relay_rc {} {
  if {[info exists ::env(CTS_RELAY_RW_PER_UM)] && \
      [string is double $::env(CTS_RELAY_RW_PER_UM)] && \
      $::env(CTS_RELAY_RW_PER_UM) > 1e-9} {
    puts "  RC manually set: rw=$::env(CTS_RELAY_RW_PER_UM) kOhm/um — skip auto-detect"
    return
  }

  if {![info exists ::env(SET_RC_TCL)] || ![file exists $::env(SET_RC_TCL)]} {
    puts "WARNING: SET_RC_TCL not found — Elmore RC auto-detect skipped"
    return
  }

  set fh [open $::env(SET_RC_TCL) r]
  set content [read $fh]
  close $fh

  set rw 0.0
  set cw 0.0
  if {[regexp {set_wire_rc[^;\n#]*-clock[^;\n#]*-resistance\s+(\S+)[^;\n#]*-capacitance\s+(\S+)} \
         $content -> rw cw] ||
      [regexp {set_wire_rc[^;\n#]*-resistance\s+(\S+)[^;\n#]*-capacitance\s+(\S+)[^;\n#]*-clock} \
         $content -> rw cw]} {
    set ::env(CTS_RELAY_RW_PER_UM) $rw
    set ::env(CTS_RELAY_CW_PER_UM) $cw
    puts "  Clock wire RC from [file tail $::env(SET_RC_TCL)]: rw=${rw} cw=${cw} rc=[format %.5f [expr {$rw * $cw}]]"
  } else {
    puts "WARNING: set_wire_rc -clock not found in $::env(SET_RC_TCL)"
  }

  if {[catch {
    set dbu [[ord::get_db_tech] getDbUnitsPerMicron]
    set ::env(CTS_DBU_PER_UM) $dbu
    puts "  DBU/um=${dbu} from ODB tech"
  } err]} {
    puts "WARNING: Could not read DBU/um: $err"
  }
}

# =========================================
# Cross-tier net statistics
# =========================================
proc count_cross_tier_nets {{net_pattern "*"}} {
  set block [ord::get_db_block]
  set cross_count 0
  set total_count 0
  set cross_list {}

  foreach net [$block getNets] {
    set nname [$net getName]
    if {$net_pattern ne "*" && ![string match $net_pattern $nname]} { continue }
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} { continue }
    incr total_count

    set has_upper 0
    set has_bottom 0
    foreach iterm [$net getITerms] {
      set master_obj [[$iterm getInst] getMaster]
      if {$master_obj eq "" || $master_obj eq "NULL"} { continue }
      set master [$master_obj getName]
      if {[string match "*upper*" $master]} { set has_upper 1 }
      if {[string match "*bottom*" $master]} { set has_bottom 1 }
      if {$has_upper && $has_bottom} { break }
    }
    if {$has_upper && $has_bottom} {
      incr cross_count
      lappend cross_list $nname
    }
  }
  return [list $cross_count $total_count $cross_list]
}

proc report_cross_tier_stats {} {
  puts "\n========== Cross-Tier Statistics =========="
  lassign [count_cross_tier_nets "*"] all_cross all_total all_list

  # Clock net detection: sigType==CLOCK OR name contains "clk" (catches t1_clknet_*,
  # clknet_*, clkbuf_*, ghtap, grp, sg_leaf/trunk/root/dly, and original clock nets).
  # Name-only "clk*" missed per-tier t1_ prefix nets. sigType-only misses leaf nets
  # that TritonCTS doesn't mark USE CLOCK. Using both (union) is most accurate.
  set block [ord::get_db_block]
  set clk_cross 0
  set clk_total 0
  set clk_cross_list {}
  set clk_patterns {*clk* *ghtap* *grp_* *sg_leaf* *sg_trunk* *sg_root* *sg_dly*}

  foreach net [$block getNets] {
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} { continue }
    set nname [$net getName]

    # Check if this is a clock net: sigType CLOCK or name matches CTS patterns
    set is_clock 0
    if {$sig_type eq "CLOCK"} {
      set is_clock 1
    } else {
      foreach pat $clk_patterns {
        if {[string match $pat $nname]} { set is_clock 1; break }
      }
    }
    if {!$is_clock} { continue }

    incr clk_total
    set has_upper 0
    set has_bottom 0
    foreach iterm [$net getITerms] {
      set master_obj [[$iterm getInst] getMaster]
      if {$master_obj eq "" || $master_obj eq "NULL"} { continue }
      set master [$master_obj getName]
      if {[string match "*upper*" $master]} { set has_upper 1 }
      if {[string match "*bottom*" $master]} { set has_bottom 1 }
      if {$has_upper && $has_bottom} { break }
    }
    if {$has_upper && $has_bottom} {
      incr clk_cross
      lappend clk_cross_list $nname
    }
  }

  puts [format "  All nets:   %d / %d cross-tier (%.1f%%)" $all_cross $all_total \
    [expr {$all_total > 0 ? double($all_cross)/$all_total*100 : 0}]]
  puts [format "  Clock nets: %d / %d cross-tier (%.1f%%)" $clk_cross $clk_total \
    [expr {$clk_total > 0 ? double($clk_cross)/$clk_total*100 : 0}]]

  set upper_count 0
  set bottom_count 0
  foreach inst [$block getInsts] {
    set master_obj [$inst getMaster]
    if {$master_obj eq "" || $master_obj eq "NULL"} { continue }
    set master [$master_obj getName]
    if {[string match "*upper*" $master]} { incr upper_count }
    if {[string match "*bottom*" $master]} { incr bottom_count }
  }
  set total_inst [expr {$upper_count + $bottom_count}]
  puts [format "  Instances:  upper=%d (%.1f%%)  bottom=%d (%.1f%%)" \
    $upper_count [expr {$total_inst > 0 ? double($upper_count)/$total_inst*100 : 0}] \
    $bottom_count [expr {$total_inst > 0 ? double($bottom_count)/$total_inst*100 : 0}]]

  # Write report file
  set rpt_file [open $::env(REPORTS_DIR)/4_cts_cross_tier.rpt w]
  puts $rpt_file "Cross-Tier Statistics After CTS"
  puts $rpt_file [format "All nets:   %d / %d cross-tier" $all_cross $all_total]
  puts $rpt_file [format "Clock nets: %d / %d cross-tier" $clk_cross $clk_total]
  puts $rpt_file [format "Instances:  upper=%d  bottom=%d" $upper_count $bottom_count]
  puts $rpt_file ""
  puts $rpt_file "Cross-tier clock nets:"
  foreach net $clk_cross_list { puts $rpt_file "  $net" }
  close $rpt_file
}

# =====================================================================
# Phase 1: Balanced CTS + Propagated-Clock Timing Graph Extraction
#
# Runs sub-OpenROAD (phase1_extract.tcl):
#   1. clock_tree_synthesis_3d (relay=0, balanced tree as timing reference)
#   2. estimate_parasitics → set_propagated_clock
#   3. Re-extract FF→FF + IO timing graphs with propagated-clock slacks
#
# CTS_REUSE_TIMING_GRAPH=1: skip Phase 1 sub-OpenROAD if pre-CTS CSVs
# already exist (e.g., re-running Phase 3+ without re-extracting graphs).
# Useful for large designs (IBEX ~3h, ariane133 ~10h) where Phase 1 is
# the bottleneck and graphs from a previous run are still valid.
# =====================================================================
if {[info exists ::env(ENABLE_PROPAGATED_CTS)] && $::env(ENABLE_PROPAGATED_CTS)} {

  set scripts_dir $::env(SCRIPTS_3DCTS_DIR)
  set targets_csv "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv"
  set phase1a_script "$scripts_dir/phase1_extract.tcl"

  # Use absolute RESULTS_DIR (not relative ./results/) for DOE compatibility.
  set _ff_csv  "$::env(CTS3D_WORK_DIR)/pre_cts_ff_timing_graph.csv"
  set _io_csv  "$::env(CTS3D_WORK_DIR)/pre_cts_io_timing_edges.csv"

  # HOLD-BUDGET FIX: the C++ hold-budget loader
  # (loadPerFfHoldBudgets, HTreeBuilder.cpp) reads CTS_TIMING_GRAPH_CSV /
  # CTS_IO_TIMING_CSV. These were unset → it fell back to a malformed
  # "./results///openroad/..." path (empty PLATFORM/DESIGN) → CTS-0422 fail →
  # perFfHoldBudget_ empty → TARP 997 FFs fail-closed (budget=0) → the TAP
  # delivery had NO hold protection → catastrophic hold (esp. macro designs).
  # Point these env vars at the correct absolute CSVs so hold budgets load and
  # the delivery becomes hold-aware.
  set ::env(CTS_TIMING_GRAPH_CSV) $_ff_csv
  set ::env(CTS_IO_TIMING_CSV)    $_io_csv

  # Check CTS_REUSE_TIMING_GRAPH: skip Phase 1 if CSVs already exist.
  set _reuse_graphs [expr {
    [info exists ::env(CTS_REUSE_TIMING_GRAPH)] &&
    $::env(CTS_REUSE_TIMING_GRAPH) &&
    [file exists $_ff_csv] && [file exists $_io_csv]
  }]

  if {$_reuse_graphs} {
    puts "\n========== Phase 1: SKIPPED (CTS_REUSE_TIMING_GRAPH=1, CSVs exist) =========="
    puts ">>> Reusing: $_ff_csv"
    puts ">>> Reusing: $_io_csv"
    set _phase1_ok 1
  } else {
    puts "\n========== Phase 1: Balanced CTS + Propagated-Clock Extraction =========="
    set _phase1_t0 [clock seconds]
    set openroad_exe $::env(OPENROAD_EXE)
    set num_cores $::env(NUM_CORES)
    set phase1a_cmd [list $openroad_exe -threads $num_cores -exit $phase1a_script]
    puts ">>> Sub-OpenROAD: $phase1a_cmd"
    if {[catch {exec {*}$phase1a_cmd} phase1a_out]} {
      puts "WARNING: Phase 1 failed:\n$phase1a_out"
      puts ">>> Skipping Phase 2 (propagated-clock graphs unavailable)"
      set _phase1_ok 0
    } else {
      puts $phase1a_out
      set _phase1_ok 1
    }
    set _phase1_elapsed [expr {[clock seconds] - $_phase1_t0}]
    puts ">>> Phase 1 elapsed: ${_phase1_elapsed}s ([expr {$_phase1_elapsed/60}]m [expr {$_phase1_elapsed%60}]s)"
  }

  if {$_phase1_ok} {
    # ==========================================================
    # Phase 2: C++ LP-TNS Solve (OR-Tools GLOP)
    # Delivery-constrained, endpoint-TNS, 2-phase (WNS→TNS).
    # ==========================================================
    puts "\n========== Phase 2: C++ LP-TNS Solve =========="
    set _phase2_t0 [clock seconds]

    set sigma_local [expr {[info exists ::env(PRE_CTS_SIGMA_LOCAL)] ? $::env(PRE_CTS_SIGMA_LOCAL) : 0.005}]
    set sigma_pi    [expr {[info exists ::env(PRE_CTS_SIGMA_PI)]    ? $::env(PRE_CTS_SIGMA_PI) : 0.005}]
    set lambda_reg  [expr {[info exists ::env(PRE_CTS_LAMBDA_REG)]  ? $::env(PRE_CTS_LAMBDA_REG) : 0.01}]
    set hold_margin [expr {[info exists ::env(PRE_CTS_HOLD_MARGIN)] ? $::env(PRE_CTS_HOLD_MARGIN) : 0.010}]
    set gamma_wns   [expr {[info exists ::env(PRE_CTS_GAMMA_WNS)]   ? $::env(PRE_CTS_GAMMA_WNS) : 10.0}]
    set weight_io   [expr {[info exists ::env(PRE_CTS_WEIGHT_IO)]   ? $::env(PRE_CTS_WEIGHT_IO) : 1.0}]
    set hard_pi_hold [expr {[info exists ::env(PRE_CTS_HARD_PI_HOLD)] ? $::env(PRE_CTS_HARD_PI_HOLD) : 0}]
    set max_skew    [expr {[info exists ::env(PRE_CTS_MAX_SKEW)]    ? $::env(PRE_CTS_MAX_SKEW) : 0.100}]

    set verilog_file "$::env(RESULTS_DIR)/[file tail [glob -nocomplain $::env(RESULTS_DIR)/3_place.v]]"
    if {![file exists $verilog_file]} {
      set verilog_file [lindex [glob -nocomplain $::env(RESULTS_DIR)/3_*.v] 0]
      if {$verilog_file eq ""} { set verilog_file "" }
    }

    set ::env(CTS_FF_TIMING_GRAPH_CSV) $_ff_csv
    set ::env(CTS_IO_TIMING_EDGES_CSV) $_io_csv
    set ::env(CTS_SKEW_TARGETS_CSV)    "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv"

    puts "  LP params: sigma=$sigma_local pi=$sigma_pi lambda=$lambda_reg hold=$hold_margin"
    puts "             gamma_wns=$gamma_wns io=$weight_io max_skew=$max_skew"

    if {[catch {
      dcts::solve_skew_lp $verilog_file \
        $sigma_local $sigma_pi $lambda_reg $hold_margin \
        $gamma_wns $weight_io $hard_pi_hold $max_skew
    } lp_err]} {
      puts "WARNING: Phase 2 LP failed: $lp_err"
    } else {
      puts ">>> Phase 2 complete — targets stored in C++ memory"
    }
    set _phase2_elapsed [expr {[clock seconds] - $_phase2_t0}]
    puts ">>> Phase 2 elapsed: ${_phase2_elapsed}s ([expr {$_phase2_elapsed/60}]m [expr {$_phase2_elapsed%60}]s)"
  }
}

# =====================================================================
# Phase 3: Useful-Skew CTS (per-tier H-tree + cascaded TAP delivery)
# =====================================================================

auto_set_relay_rc

puts "\n========== Phase 3: Useful-Skew CTS =========="
set _phase3_t0 [clock seconds]

set cts_layer "bottom"
set fix_layer "upper"
if {[info exists ::env(CTS_LAYER)]} {
  set cts_layer $::env(CTS_LAYER)
  set fix_layer [expr {$cts_layer eq "bottom" ? "upper" : "bottom"}]
}

repair_clock_inverters

set buf_list_3d [build_buf_list_3d]

set cts_args [list \
  -sink_clustering_enable \
  -root_buf $::env(CTS_BUF_CELL) \
  -buf_list $buf_list_3d
]

# V58: Macro designs need -no_insertion_delay to disable LatencyBalancer
# (28 macros + LatencyBalancer ON = 226 delay buffers = catastrophic hold).
if {[info exists ::env(CTS_NO_INSERTION_DELAY)] && $::env(CTS_NO_INSERTION_DELAY)} {
  lappend cts_args -no_insertion_delay
  puts "  CTS_NO_INSERTION_DELAY=1: LatencyBalancer disabled (macro design mode)"
}

append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1

# Snapshot pre-CTS instances for new-cell detection
set _pre_cts_insts [dict create]
set _pre_cts_pos [dict create]
set _block [ord::get_db_block]
foreach _inst [$_block getInsts] {
  set _n [$_inst getName]
  dict set _pre_cts_insts $_n 1
  dict set _pre_cts_pos $_n [list [lindex [$_inst getOrigin] 0] [lindex [$_inst getOrigin] 1]]
}
puts "  Pre-CTS instances: [dict size $_pre_cts_insts]"

# ---- Conservative useful-skew damping (candidate-E fix: a_i <- lambda * a_i) ----
# Env-gated, default off. Scales the LP targets before CTS delivery and reloads them
# into Cts3DDatabase memory so Phase 3 clock_tree_synthesis_3d uses the damped a_i.
# Motivation: fresh endpoint-TNS LP can over-skew under incomplete timing coverage,
# producing a schedule that is harmful even under ideal delivery. Damping recovers a
# realization- and model-safe schedule (AES: lambda=0.25 -> +1,043ps ideal vs -985 at 1.0).
if {[info exists ::env(CTS_SKEW_DAMP_LAMBDA)] && $::env(CTS_SKEW_DAMP_LAMBDA) ne "" \
    && $::env(CTS_SKEW_DAMP_LAMBDA) != 1.0} {
  set _lam $::env(CTS_SKEW_DAMP_LAMBDA)
  set _src "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv"
  set _dst "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets_damped.csv"
  if {[file exists $_src]} {
    set _fin [open $_src r]; set _fout [open $_dst w]
    set _hdr [gets $_fin]; puts $_fout $_hdr
    while {[gets $_fin _line] >= 0} {
      set _c [split $_line ,]
      if {[llength $_c] >= 2 && [lindex $_c 0] ne ""} {
        set _sv [expr {[lindex $_c 1] * $_lam}]
        puts $_fout "[lindex $_c 0],$_sv,[join [lrange $_c 2 end] ,]"
      }
    }
    close $_fin; close $_fout
    dcts::load_skew_targets $_dst
    puts ">>> CTS_SKEW_DAMP_LAMBDA=$_lam: scaled LP a_i, reloaded [file tail $_dst]"
  }
}

log_cmd clock_tree_synthesis_3d {*}$cts_args

# Detect new CTS cells
set _cts_bottom_cells {}
set _cts_upper_cells {}
set _block [ord::get_db_block]
foreach _inst [$_block getInsts] {
  set _iname [$_inst getName]
  if {[dict exists $_pre_cts_insts $_iname]} { continue }
  if {[string match "*bottom*" [[$_inst getMaster] getName]]} {
    lappend _cts_bottom_cells $_iname
  } else {
    lappend _cts_upper_cells $_iname
  }
}
puts "  New CTS cells: bottom=[llength $_cts_bottom_cells]  upper=[llength $_cts_upper_cells]"

# Timing after CTS (before any DPL/optimization)
estimate_parasitics -placement
set _cts_timing [report_timing_summary "After CTS"]

# =====================================================================
# Acceptance Gate — monotonic guarantee (revert to balanced if delivery worse).
# Guards the low-headroom regression root-caused on aes: quantized cascaded-TAP
# useful-skew delivery + tier-structural latency bias insert delay buffers whose
# (a) wrong-sign realized skew (setup) and (b) base-latency tax on PI->FF paths
# (hold) can net-HARM timing vs the balanced 3D tree. We compare the delivery
# setup TNS against the Phase-1 balanced baseline (both under propagated clock)
# and, only if delivery regressed, restore the pre-CTS DB and rebuild a balanced
# tree. No cost when delivery wins (8/9 designs) — the rebuild fires only on a
# genuine regression (e.g. aes). NOTE (paper framing): this gate is a safety
# corollary; the contribution is the characterization of WHY delivery is
# non-monotonic under quantized 3D-tier realization, not the gate itself.
# =====================================================================
set _gate_on [expr {[info exists ::env(CTS_ACCEPTANCE_GATE)] && $::env(CTS_ACCEPTANCE_GATE)}]
# : report-only mode — when CTS_GATE_REF_TNS is set but the gate is
# OFF, still print the delivery-vs-reference delta (no decision, no revert).
if {!$_gate_on && [info exists ::env(CTS_GATE_REF_TNS)] && $::env(CTS_GATE_REF_TNS) ne ""} {
  set_propagated_clock [all_clocks]
  set _rep_tns [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]
  set _rep_ref $::env(CTS_GATE_REF_TNS)
  puts [format ">>> \[Gate report-only\] delivery setup TNS=%.1f ps vs ref=%.1f ps (delta=%+.1f ps)" \
        $_rep_tns $_rep_ref [expr {$_rep_tns - $_rep_ref}]]
}
set _bal_tns_file "$::env(CTS3D_WORK_DIR)/cts_balanced_tns.txt"
set _decision_file "$::env(CTS3D_WORK_DIR)/cts_gate_decision.txt"
# Only a gate-ENABLED run writes the decision file (a fresh verdict every time, so no
# stale "revert" can leak across runs). The pure balanced re-run has the gate OFF, so
# it never clobbers the audit trail.
if {$_gate_on} {
  set _decision "accept"
  # V88_SEED gate fix: under CTS_REUSE_TIMING_GRAPH=1 Phase 1 is
  # skipped and cts_balanced_tns.txt never exists -> the gate silently FAIL-OPENED
  # (always accept). CTS_GATE_REF_TNS (setup TNS in ps, e.g. the measured
  # TARP-off arm) provides an explicit reference so the gate can anchor to the
  # baseline the experiment actually cares about.
  set _ref_env_ok [expr {[info exists ::env(CTS_GATE_REF_TNS)] && $::env(CTS_GATE_REF_TNS) ne ""}]
  if {$_ref_env_ok || [file exists $_bal_tns_file]} {
    # Measure delivery setup TNS under propagated clock (match the balanced ref).
    set_propagated_clock [all_clocks]
    set _deliv_s_tns [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]
    if {$_ref_env_ok} {
      set _bal_s_tns $::env(CTS_GATE_REF_TNS)
    } else {
      set _bf [open $_bal_tns_file r]; set _bl [gets $_bf]; close $_bf
      set _bal_s_tns [lindex $_bl 0]
    }
    set _gate_margin [expr {[info exists ::env(CTS_ACCEPTANCE_MARGIN_PS)] ? $::env(CTS_ACCEPTANCE_MARGIN_PS) : 0.0}]
    puts [format ">>> \[Acceptance gate\] delivery setup TNS=%.1f ps vs balanced=%.1f ps (margin=%.1f ps)" \
          $_deliv_s_tns $_bal_s_tns $_gate_margin]
    # TNS are negative (violations); "worse" = more negative. Because OpenROAD cannot
    # reload a DB mid-session (ORD-0047) and clearing it would drop Liberty and break
    # STA, the revert is done by a FRESH balanced re-run at the run.sh level (the ORFS
    # one-process-per-stage pattern). Here we only DECIDE and record the verdict; the
    # wrapper re-runs pure CTS when the decision is "revert".
    if {$_deliv_s_tns < [expr {$_bal_s_tns - $_gate_margin}]} {
      set _decision "revert"
      puts ">>> \[Acceptance gate\] DELIVERY REGRESSED below balanced baseline — flagging revert (run.sh re-runs pure)."
    } else {
      puts ">>> \[Acceptance gate\] delivery accepted (>= balanced baseline)."
    }
  } else {
    puts ">>> \[Acceptance gate\] no balanced baseline (Phase 1 skipped) — defaulting to accept."
  }
  set _dfh [open $_decision_file w]; puts $_dfh $_decision; close $_dfh
}

# =====================================================================
# Validation artifact (opt-in, ): post-CTS propagated-clock IO slacks.
# Dumps PI→FF + FF→PO setup/hold slack per (port,ff) AFTER the real delivery tree
# is built, under propagated clock. Uses the (V67-fixed) exhaustive C++ extractor to
# also validate the FF→PO extraction fix; falls back to the Tcl worst-N proc.
# PURE OUTPUT — no LP re-solve, delivery/DB unchanged. Env-gated (CTS_DUMP_POSTCTS_IO=1),
# default OFF → byte-identical behavior. Consumed by parallel sessions budgeting
# common-mode latency shift as IO-path slack.
# CSV cols: edge_type,port_name,ff_name,slack_setup_ns,slack_hold_ns[,ff_clock_net]
# =====================================================================
if {[info exists ::env(CTS_DUMP_POSTCTS_IO)] && $::env(CTS_DUMP_POSTCTS_IO)} {
  set_propagated_clock [all_clocks]
  set _postio_csv "$::env(CTS3D_WORK_DIR)/post_cts_io_timing_edges.csv"
  puts ">>> \[Validation\] post-CTS propagated-clock IO slacks → $_postio_csv"
  if {[catch { dcts::extract_io_timing_edges_odb $_postio_csv } err]} {
    puts ">>> \[Validation\] C++ ODB extractor unavailable ($err) — using Tcl proc"
    if {[catch { extract_io_timing_edges $_postio_csv } err2]} {
      puts "WARNING: post-CTS IO dump failed: $err2"
    }
  }
}

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

# =====================================================================
# Phase 3b: Post-CTS LP + Optional Iterative TAP Refinement
# =====================================================================

# Post-CTS LP solve (guides buffer sizing)
# Bug fix: extraction must be inside the ENABLE_POST_CTS_LP guard —
# running it unconditionally wastes time when post-CTS LP is disabled.
if {[info exists ::env(ENABLE_POST_CTS_LP)] && $::env(ENABLE_POST_CTS_LP)} {
  # Post-CTS timing graph extraction (propagated clock)
  set post_cts_csv "$::env(CTS3D_WORK_DIR)/post_cts_ff_timing_graph.csv"
  puts "\n>>> Extracting post-CTS timing graph..."
  dcts::extract_ff_timing_graph_odb $post_cts_csv
  set post_cts_targets "$::env(CTS3D_WORK_DIR)/post_cts_skew_targets.csv"

  set reuse_post_lp [expr {[info exists ::env(CTS_REUSE_POST_CTS_LP)] && $::env(CTS_REUSE_POST_CTS_LP)}]
  if {$reuse_post_lp && [file exists $post_cts_targets]} {
    puts ">>> Post-CTS LP: REUSING $post_cts_targets"
    if {[catch {dcts::load_skew_targets $post_cts_targets} err]} {
      puts "WARNING: Failed to load cached targets: $err — will re-run"
      set reuse_post_lp 0
    } else {
      set ::env(POST_CTS_SKEW_TARGETS) $post_cts_targets
    }
  }

  if {!$reuse_post_lp || ![file exists $post_cts_targets]} {
    set scripts_dir $::env(SCRIPTS_3DCTS_DIR)
    set post_sigma [expr {[info exists ::env(POST_CTS_SIGMA_LOCAL)] ? $::env(POST_CTS_SIGMA_LOCAL) : 0.005}]
    set post_hold_margin [expr {[info exists ::env(POST_CTS_HOLD_MARGIN)] ? $::env(POST_CTS_HOLD_MARGIN) : 0.005}]
    set post_lambda [expr {[info exists ::env(POST_CTS_LAMBDA_REG)] ? $::env(POST_CTS_LAMBDA_REG) : 0.001}]
    set post_max_skew [expr {[info exists ::env(POST_CTS_MAX_SKEW)] ? $::env(POST_CTS_MAX_SKEW) : 0.100}]

    set ::env(CTS_SKEW_TARGETS_CSV) $post_cts_targets
    set ::env(CTS_FF_TIMING_GRAPH_CSV) $post_cts_csv

    # Re-extract IO edges with Phase 3 propagated-clock timing.
    # Phase 1 IO edges have stale PI→FF hold slacks that don't reflect
    # the Phase 3 CTS base latency change (TARP clustering → different H-tree).
    # Post-CTS LP needs updated IO edges so PI-hold-clip reflects actual timing.
    set post_io_csv "$::env(CTS3D_WORK_DIR)/post_cts_io_timing_edges.csv"
    puts ">>> Re-extracting IO edges with post-CTS propagated timing..."
    if {[catch {
      extract_io_timing_edges $post_io_csv
    } err]} {
      puts "WARNING: Post-CTS IO extraction failed: $err — using pre-CTS IO edges"
      set post_io_csv ""
    }
    if {$post_io_csv ne "" && [file exists $post_io_csv]} {
      set ::env(CTS_IO_TIMING_EDGES_CSV) $post_io_csv
      puts ">>> Post-CTS IO edges: $post_io_csv"
    } else {
      # Fallback to pre-CTS IO edges
      set _res_dir_io "$::env(CTS3D_WORK_DIR)"
      set ::env(CTS_IO_TIMING_EDGES_CSV) "${_res_dir_io}/pre_cts_io_timing_edges.csv"
      puts ">>> Fallback: using pre-CTS IO edges"
    }

    puts ">>> Running post-CTS LP..."
    if {[catch {
      dcts::solve_skew_lp "" \
        $post_sigma 0.005 $post_lambda $post_hold_margin \
        10.0 1.0 0 $post_max_skew
    } err]} {
      puts "WARNING: Post-CTS LP failed: $err"
    } else {
      puts ">>> Post-CTS LP complete"
      # BUG #4 FIX: If CTS_AUTO_UPDATE_TAP=1, solve_skew_lp already called
      # updateTapDepths internally. Re-estimate parasitics so buffer sizing
      # sees the updated clock topology.
      if {[info exists ::env(CTS_AUTO_UPDATE_TAP)] && $::env(CTS_AUTO_UPDATE_TAP)} {
        puts ">>> TAP depths auto-updated — re-estimating parasitics"
        estimate_parasitics -placement
        set_propagated_clock [all_clocks]
      }
    }
    set ::env(POST_CTS_SKEW_TARGETS) $post_cts_targets
  }
}

# Iterative TAP depth refinement (optional)
if {[info exists ::env(CTS_ENABLE_ITERATION)] && $::env(CTS_ENABLE_ITERATION)} {
  set _max_iter [expr {[info exists ::env(CTS_ITERATION_MAX)] ? $::env(CTS_ITERATION_MAX) : 2}]
  puts "\n========== Phase 3b: Iterative TAP Refinement (max $_max_iter) =========="

  for {set _iter 1} {$_iter <= $_max_iter} {incr _iter} {
    puts "\n--- Iteration $_iter / $_max_iter ---"

    estimate_parasitics -placement
    set_propagated_clock [all_clocks]

    set _iter_csv "$::env(CTS3D_WORK_DIR)/iter${_iter}_ff_timing_graph.csv"
    dcts::extract_ff_timing_graph_odb $_iter_csv
    set ::env(CTS_FF_TIMING_GRAPH_CSV) $_iter_csv

    set _iter_targets "$::env(CTS3D_WORK_DIR)/iter${_iter}_skew_targets.csv"
    set ::env(CTS_SKEW_TARGETS_CSV) $_iter_targets

    set _iter_sigma [expr {[info exists ::env(PRE_CTS_SIGMA_LOCAL)] ? $::env(PRE_CTS_SIGMA_LOCAL) : 0.005}]
    set _iter_lambda [expr {[info exists ::env(PRE_CTS_LAMBDA_REG)] ? $::env(PRE_CTS_LAMBDA_REG) : 0.001}]
    set _iter_hold [expr {[info exists ::env(PRE_CTS_HOLD_MARGIN)] ? $::env(PRE_CTS_HOLD_MARGIN) : 0.005}]
    set _iter_maxskew [expr {[info exists ::env(PRE_CTS_MAX_SKEW)] ? $::env(PRE_CTS_MAX_SKEW) : 0.100}]

    if {[catch {
      dcts::solve_skew_lp "" \
        $_iter_sigma 0.005 $_iter_lambda $_iter_hold \
        10.0 1.0 0 $_iter_maxskew
    } err]} {
      puts "WARNING: Iteration $_iter LP failed: $err — stopping"
      break
    }

    # Compare old vs new targets
    set _old_targets_file [expr {$_iter == 1 ?
      "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv" :
      "$::env(CTS3D_WORK_DIR)/iter[expr {$_iter - 1}]_skew_targets.csv"}]

    set _old_targets [dict create]
    set _new_targets [dict create]
    if {[file exists $_old_targets_file]} {
      set _fh [open $_old_targets_file r]
      gets $_fh
      while {[gets $_fh _line] >= 0} {
        set _parts [split $_line ","]
        if {[llength $_parts] >= 2} { dict set _old_targets [lindex $_parts 0] [lindex $_parts 1] }
      }
      close $_fh
    }
    if {[file exists $_iter_targets]} {
      set _fh [open $_iter_targets r]
      gets $_fh
      while {[gets $_fh _line] >= 0} {
        set _parts [split $_line ","]
        if {[llength $_parts] >= 2} { dict set _new_targets [lindex $_parts 0] [lindex $_parts 1] }
      }
      close $_fh
    }

    set _d_buf [expr {[info exists ::env(CTS_PER_FF_BUF_DELAY_NS)] ? $::env(CTS_PER_FF_BUF_DELAY_NS) : 0.025}]
    set _max_depth [expr {[info exists ::env(CTS_GROUPED_DELAY_MAX_DEPTH)] ? $::env(CTS_GROUPED_DELAY_MAX_DEPTH) : 8}]
    set _changed 0
    set _total 0
    dict for {_ff _new_val} $_new_targets {
      incr _total
      set _old_val [expr {[dict exists $_old_targets $_ff] ? [dict get $_old_targets $_ff] : 0.0}]
      set _old_depth [expr {min($_max_depth, max(0, int(round($_old_val / $_d_buf))))}]
      set _new_depth [expr {min($_max_depth, max(0, int(round($_new_val / $_d_buf))))}]
      if {$_old_depth != $_new_depth} { incr _changed }
    }

    puts "  $_changed / $_total FFs would change depth"
    if {$_changed == 0} {
      puts ">>> Converged at iteration $_iter"
      break
    }

    dcts::update_tap_depths $_iter_targets
    set ::env(POST_CTS_SKEW_TARGETS) $_iter_targets
  }
}

# Phase 3 elapsed
set _phase3_elapsed [expr {[clock seconds] - $_phase3_t0}]
puts ">>> Phase 3 elapsed: ${_phase3_elapsed}s ([expr {$_phase3_elapsed/60}]m [expr {$_phase3_elapsed%60}]s)"

# =====================================================================
# Phase 4: repair_clock_nets (tier-aware) + DPL Legalization
# =====================================================================
puts "\n========== Phase 4: Tier-Aware repair_clock_nets + DPL =========="
set _phase4_t0 [clock seconds]

estimate_parasitics -placement

# Skip repair_timing (CTS only, not data path optimization)
if { ![info exists ::env(SKIP_CTS_REPAIR_TIMING)] } { set ::env(SKIP_CTS_REPAIR_TIMING) 1 }
if { !$::env(SKIP_CTS_REPAIR_TIMING) } {
  repair_timing_helper
  if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
    puts "  Skipping repair_timing DPL (heterogeneous 3D)"
  } elseif {[catch {detailed_placement} err]} {
    puts "WARNING: repair_timing DPL failed: $err"
  }
  catch {check_placement -verbose}
}

mark_insts_by_master "*${fix_layer}*" PLACED

# Tier-aware repair_clock_nets: fix max-cap/max-slew, swap new buffers to correct tier
set _pre_repair_insts [dict create]
set _block [ord::get_db_block]
foreach _inst [$_block getInsts] { dict set _pre_repair_insts [$_inst getName] 1 }

puts ">>> repair_clock_nets (pre-count: [dict size $_pre_repair_insts])"
# Heterogeneous 3D: force RSZ to use only upper-tier cells for repair buffers.
# Without this, RSZ picks bottom NG45 cells (higher max-cap) -> cross-tier clock nets.
# NG45 naming (INV_X8_bottom) != ASAP7 naming (INVx2_ASAP7_75t_R_upper) ->
# existing string map swap cannot fix the mismatch.
if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
  set_dont_use "*_bottom"
  puts "  HETERO: set_dont_use *_bottom -- force upper-only repair buffers"
}
if {[catch {repair_clock_nets} err]} {
  puts "WARNING: repair_clock_nets failed: $err"
}
if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
  unset_dont_use "*_bottom"
  puts "  HETERO: unset_dont_use *_bottom -- restored"
}

set _new_bufs 0
set _swapped 0
set _db [ord::get_db]
foreach _inst [$_block getInsts] {
  set _iname [$_inst getName]
  if {[dict exists $_pre_repair_insts $_iname]} { continue }
  incr _new_bufs
  set _master_name [[$_inst getMaster] getName]

  # Determine tier from output net sinks (majority vote)
  set _bottom_sinks 0
  set _upper_sinks 0
  foreach _iterm [$_inst getITerms] {
    set _net [$_iterm getNet]
    if {$_net == "NULL" || [$_iterm isOutputSignal] == 0} { continue }
    foreach _sink_iterm [$_net getITerms] {
      set _sink_inst [$_sink_iterm getInst]
      if {$_sink_inst == $_inst} { continue }
      set _sink_master [[$_sink_inst getMaster] getName]
      if {[string match "*bottom*" $_sink_master]} { incr _bottom_sinks }
      if {[string match "*upper*" $_sink_master]}  { incr _upper_sinks }
    }
  }

  set _target_tier [expr {$_bottom_sinks > $_upper_sinks ? 0 : 1}]
  set _need_swap 0
  if {$_target_tier == 0 && [string match "*_upper*" $_master_name]} {
    set _new_master [string map {_upper _bottom} $_master_name]
    set _need_swap 1
  } elseif {$_target_tier == 1 && [string match "*_bottom*" $_master_name]} {
    set _new_master [string map {_bottom _upper} $_master_name]
    set _need_swap 1
  }

  if {$_need_swap} {
    set _db_master [$_db findMaster $_new_master]
    if {$_db_master != "NULL"} {
      $_inst swapMaster $_db_master
      incr _swapped
    }
  }
}
puts "  Repair: $_new_bufs new buffers, $_swapped tier-swapped"

# Timing after repair_clock_nets, before DPL
estimate_parasitics -placement
report_timing_summary "After repair_clock_nets (before DPL)"

# DPL Pass 1 + COVER-tier grid snap
# Bug fix: HETEROGENEOUS_3D (asap7_nangate45_3D) has no NG45 ROW in DEF.
# DPL cannot legalize bottom NG45 CTS buffers, and upper DPL displaces
# buffers up to 182um → hold 10x worse. Skip DPL when SKIP_HETERO_DPL=1.
set _skip_hetero_dpl [expr {[info exists ::env(SKIP_HETERO_DPL)] && $::env(SKIP_HETERO_DPL) && \
                             [info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)}]
if {!$_skip_hetero_dpl} {
  puts ">>> Post-repair DPL (FIRM-protected: pre-CTS cells frozen)"
  # FIRM all pre-CTS cells to prevent data path displacement.
  # Only CTS buffers + repair buffers (post-CTS insertions) are free to move.
  set _dpl_freed 0
  foreach _inst [$_block getInsts] {
    $_inst setPlacementStatus FIRM
  }
  foreach _inst [$_block getInsts] {
    if {![dict exists $_pre_cts_insts [$_inst getName]]} {
      $_inst setPlacementStatus PLACED
      incr _dpl_freed
    }
  }
  puts "  FIRM: [dict size $_pre_cts_insts] pre-CTS cells, FREE: $_dpl_freed post-CTS cells"
  if {[catch {detailed_placement} err]} {
    puts "WARNING: Post-repair DPL failed: $err"
  }
  # Restore all to PLACED for subsequent steps
  foreach _inst [$_block getInsts] {
    $_inst setPlacementStatus PLACED
  }
} else {
  puts ">>> Post-repair DPL: skipped (SKIP_HETERO_DPL=1 + HETEROGENEOUS_3D=1, no NG45 ROW in DEF)"
}

# Grid snap CTS buffers to ROW grid (required for coarse-grid platforms).
# Upper cells: always snap to ASAP7 ROW grid (first ROW site in DEF).
# Bottom cells (HETEROGENEOUS_3D): snap to NG45 grid (0.190um x 1.400um).
#   Bug fix: original code used ASAP7 grid (54x270) for ALL cells including bottom
#   NG45 — off-track placement caused DRT-0073 for asap7_nangate45_3D designs.
#   Cells on different tiers do not conflict, so separate collision sets per tier.
set _rows [$_block getRows]
set _row0 [lindex $_rows 0]
set _site [$_row0 getSite]
set _site_w [$_site getWidth]
set _site_h [$_site getHeight]
set _row_y0 [lindex [$_row0 getOrigin] 1]

# For HETEROGENEOUS_3D, compute NG45 grid from block dbu/um.
# FreePDK45 site pitch: 0.190um (x) x 1.400um (y).
# Use $_skip_hetero_dpl (defined before Phase 4) instead of $_is_hetero (local to build_buf_list_3d proc).
set _bot_site_w $_site_w
set _bot_site_h $_site_h
set _bot_row_y0 0
if {$_skip_hetero_dpl} {
  set _dbu_per_um [$_block getDbUnitsPerMicron]
  set _bot_site_w [expr {int(round(0.190 * $_dbu_per_um))}]
  set _bot_site_h [expr {int(round(1.400 * $_dbu_per_um))}]
  # Compute NG45 grid y-origin from existing bottom cells (not hardcoded 0).
  # NG45 rows may not start at y=0 in the merged 3D DEF.
  foreach _inst [$_block getInsts] {
    if {[string match "*bottom*" [[$_inst getMaster] getName]]} {
      set _by [lindex [$_inst getOrigin] 1]
      set _bot_row_y0 [expr {$_by % $_bot_site_h}]
      break
    }
  }
  puts "  Grid: upper(ASAP7)=${_site_w}x${_site_h} dbu, bottom(NG45)=${_bot_site_w}x${_bot_site_h} dbu, y0=${_bot_row_y0}"
}

# Build occupied sets per tier (cells on different tiers don't conflict).
set _occ_upper [dict create]
set _occ_bottom [dict create]
foreach _inst [$_block getInsts] {
  set _mname [[$_inst getMaster] getName]
  set _iname [$_inst getName]
  # Skip CTS cells themselves — they are the ones being snapped.
  if {[string match "clkbuf_*" $_iname] || [string match "clkload*" $_iname] || \
      [string match "*relay*" $_iname] || [string match "sg_*" $_iname] || \
      [string match "*repair*" $_iname]} { continue }
  set _key "[lindex [$_inst getOrigin] 0],[lindex [$_inst getOrigin] 1]"
  if {[string match "*upper*" $_mname]} {
    dict set _occ_upper $_key 1
  } elseif {[string match "*bottom*" $_mname]} {
    dict set _occ_bottom $_key 1
  }
}

# Helper: snap one list of cells to a given grid with collision avoidance.
proc _snap_cells_to_grid {cell_list block sw sh y0 occ_var} {
  upvar $occ_var occ
  set cnt 0
  foreach _iname $cell_list {
    set _inst [$block findInst $_iname]
    if {$_inst eq "" || $_inst eq "NULL"} { continue }
    set _ox [lindex [$_inst getOrigin] 0]
    set _oy [lindex [$_inst getOrigin] 1]
    set _sx [expr {int(round(double($_ox) / $sw)) * $sw}]
    set _sy [expr {$y0 + int(round(double($_oy - $y0) / $sh)) * $sh}]
    if {[dict exists $occ "${_sx},${_sy}"]} {
      set _found 0
      for {set _r 1} {$_r <= 10 && !$_found} {incr _r} {
        foreach _dy [list 0 $_r [expr {-$_r}]] {
          foreach _dx [list 0 $_r [expr {-$_r}]] {
            if {$_dx == 0 && $_dy == 0} { continue }
            set _tx [expr {$_sx + $_dx * $sw}]
            set _ty [expr {$_sy + $_dy * $sh}]
            if {![dict exists $occ "${_tx},${_ty}"]} {
              set _sx $_tx; set _sy $_ty; set _found 1; break
            }
          }
          if {$_found} { break }
        }
      }
    }
    $_inst setOrigin $_sx $_sy
    dict set occ "${_sx},${_sy}" 1
    incr cnt
  }
  return $cnt
}

set _snap_upper  [_snap_cells_to_grid $_cts_upper_cells  $_block $_site_w    $_site_h    $_row_y0     _occ_upper]
set _snap_bottom [_snap_cells_to_grid $_cts_bottom_cells $_block $_bot_site_w $_bot_site_h $_bot_row_y0 _occ_bottom]
set _snap_count [expr {$_snap_upper + $_snap_bottom}]
puts "  Grid-snapped $_snap_count CTS buffers (upper: ${_site_w}x${_site_h}, bottom: ${_bot_site_w}x${_bot_site_h} dbu)"

estimate_parasitics -placement
report_timing_summary "After DPL"

set _phase4_elapsed [expr {[clock seconds] - $_phase4_t0}]
puts ">>> Phase 4 elapsed: ${_phase4_elapsed}s ([expr {$_phase4_elapsed/60}]m [expr {$_phase4_elapsed%60}]s)"

# =====================================================================
# Phase 5: Buffer Sizing
# =====================================================================
set _phase5_t0 [clock seconds]
if {[info exists ::env(ENABLE_BUFFER_SIZING)] && $::env(ENABLE_BUFFER_SIZING)} {
  set use_iterative [expr {[info exists ::env(BUFFER_SIZING_ITERATIVE)] && $::env(BUFFER_SIZING_ITERATIVE)}]

  if {$use_iterative} {
    puts "\n========== Phase 5: Iterative Buffer Sizing =========="
    source $::env(SCRIPTS_3DCTS_DIR)/buffer_sizing_iterative.tcl
    run_buffer_sizing_iterative "both"
  } else {
    puts "\n========== Phase 5: Buffer Sizing =========="
    source $::env(SCRIPTS_3DCTS_DIR)/buffer_sizing.tcl
    run_buffer_sizing "both"
  }

  estimate_parasitics -placement
  report_timing_summary "After BufSizing"
}

# Layer assignment (setup→lower metal, hold→higher metal)
if {[info exists ::env(CTS_ENABLE_LAYER_ASSIGNMENT)] && $::env(CTS_ENABLE_LAYER_ASSIGNMENT)} {
  source $::env(SCRIPTS_3DCTS_DIR)/clock_layer_assignment.tcl
  identify_lp_based_subnets \
    "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv" \
    "$::env(CTS3D_WORK_DIR)/pre_cts_io_timing_edges.csv" \
    "$::env(CTS3D_WORK_DIR)/v43_layer_assignment.txt"
}

# Buffer insertion (currently disabled, kept for experimental use)
if {[info exists ::env(ENABLE_BUFFER_INSERTION)] && $::env(ENABLE_BUFFER_INSERTION)} {
  puts "\n========== Buffer Insertion =========="
  write_verilog $::env(CTS3D_WORK_DIR)/4_cts.v
  source $::env(SCRIPTS_3DCTS_DIR)/buffer_insertion.tcl
  estimate_parasitics -placement
  report_timing_summary "After BufInsert"
}

set _phase5_elapsed [expr {[clock seconds] - $_phase5_t0}]
puts ">>> Phase 5 elapsed: ${_phase5_elapsed}s ([expr {$_phase5_elapsed/60}]m [expr {$_phase5_elapsed%60}]s)"

# =====================================================================
# Phase 6: Hold Repair (data-path delay insertion)
# =====================================================================
set _phase6_t0 [clock seconds]
if { ![info exists ::env(ENABLE_HOLD_REPAIR)] } { set ::env(ENABLE_HOLD_REPAIR) 1 }

if { $::env(ENABLE_HOLD_REPAIR) } {
  puts "\n========== Phase 6: Hold Repair =========="
  estimate_parasitics -placement
  set hold_wns_before [expr {[clamp_wns [sta::worst_slack_cmd "min"]] * 1e12}]
  set hold_tns_before [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
  puts [format "  Before: Hold WNS=%.1f ps  TNS=%.1f ps" $hold_wns_before $hold_tns_before]

  if {$hold_wns_before < 0} {
    repair_timing_helper -hold

    if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
      mark_insts_by_master "*upper*" FIRM
      catch {detailed_placement}
      mark_insts_by_master "*upper*" PLACED
      mark_insts_by_master "*bottom*" FIRM
      catch {detailed_placement}
      mark_insts_by_master "*bottom*" PLACED
    } elseif {[catch {detailed_placement} err]} {
      puts "WARNING: Hold repair DPL failed: $err"
    }

    estimate_parasitics -placement
    set hold_wns_after [expr {[clamp_wns [sta::worst_slack_cmd "min"]] * 1e12}]
    set hold_tns_after [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
    puts [format "  After:  Hold WNS=%.1f ps  TNS=%.1f ps" $hold_wns_after $hold_tns_after]
    puts [format "  Delta:  WNS %+.1f ps  TNS %+.1f ps" \
      [expr {$hold_wns_after - $hold_wns_before}] \
      [expr {$hold_tns_after - $hold_tns_before}]]
  } else {
    puts "  No hold violations — skipping repair"
  }
}

# =====================================================================
# Debug extraction (optional)
# =====================================================================
if {[info exists ::env(CTS_ENABLE_DEBUG_EXTRACT)] && $::env(CTS_ENABLE_DEBUG_EXTRACT)} {
  puts "\n>>> CTS Debug Extraction"
  source $::env(SCRIPTS_3DCTS_DIR)/debug_extract.tcl
  run_cts_debug_extract \
    "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv" \
    "$::env(CTS3D_WORK_DIR)/pre_cts_ff_timing_graph.csv"
}

# =====================================================================
# Phase 4-CTR: post-CTS adaptive ladder restructuring
# PAPER framework: component of Phase 4 (post-CTS skew-aware optimization,
# alongside buffer sizing); script-internal phases 4-6 are Phase-4 sub-steps.
# Re-tap + tap-buffer downsizing with batched real-STA accept gate
# (TNS objective, WNS no-regression guard). Runs BEFORE "Write outputs",
# so 4_cts.def / 4_cts_timing.rpt / routing all inherit the result.
# Gate: CTS_ENABLE_CTR=1. Requires the debug-extract CSVs above.
# =====================================================================
if {[info exists ::env(CTS_ENABLE_CTR)] && $::env(CTS_ENABLE_CTR)} {
  puts "\n========== Phase 4-CTR (adaptive ladder restructuring) =========="
  if {![file exists "$::env(CTS3D_WORK_DIR)/cts_debug_per_ff.csv"]} {
    puts ">>> CTR: debug CSVs missing — running extraction now"
    source $::env(SCRIPTS_3DCTS_DIR)/debug_extract.tcl
    run_cts_debug_extract \
      "$::env(CTS3D_WORK_DIR)/pre_cts_skew_targets.csv" \
      "$::env(CTS3D_WORK_DIR)/pre_cts_ff_timing_graph.csv"
  }
  dcts::run_ctr_refinement
}

set _phase6_elapsed [expr {[clock seconds] - $_phase6_t0}]
puts ">>> Phase 6 elapsed: ${_phase6_elapsed}s ([expr {$_phase6_elapsed/60}]m [expr {$_phase6_elapsed%60}]s)"

# =====================================================================
# Write outputs
# =====================================================================
write_db $::env(RESULTS_DIR)/4_cts.odb
write_def $::env(RESULTS_DIR)/4_cts.def
write_verilog $::env(RESULTS_DIR)/4_cts.v
write_sdc $::env(RESULTS_DIR)/4_cts.sdc

# Cross-tier statistics
report_cross_tier_stats

# Refresh parasitics before writing timing report and final summary.
# estimate_parasitics must run BEFORE report_checks; otherwise the report
# uses stale STA state from inside buffer_sizing_iterative.tcl (which runs
# its own parasitics refreshes internally), producing ~10x worse TNS/WNS
# than the actual post-sizing result.
estimate_parasitics -placement

# Timing report file
report_checks -path_delay max -slack_max 0 -group_count 10 \
  > $::env(REPORTS_DIR)/4_cts_timing.rpt
report_checks -path_delay min -slack_max 0 -group_count 10 \
  >> $::env(REPORTS_DIR)/4_cts_timing.rpt

set rpt_file [open $::env(REPORTS_DIR)/4_cts_timing.rpt a]
puts $rpt_file "\n========== Summary =========="
puts $rpt_file [format "setup_tns %.2f ps" [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]]
puts $rpt_file [format "setup_wns %.2f ps" [expr {[clamp_wns [sta::worst_slack_cmd "max"]] * 1e12}]]
puts $rpt_file [format "hold_tns  %.2f ps" [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]]
puts $rpt_file [format "hold_wns  %.2f ps" [expr {[clamp_wns [sta::worst_slack_cmd "min"]] * 1e12}]]
close $rpt_file

# --- REALM measurement dump (env-gated, default OFF; ) ---
# CTS_REALM_DUMP_ARRIVALS=1 dumps every clkbuf_leaf_* INPUT-pin arrival (ps)
# under propagated clocks -> $CTS3D_WORK_DIR/leaf_arrivals.csv. This is the
# MEASURED per-cluster base latency that a REALM pass (CTS_REALM=1, V92+
# binary) consumes for the realization-aware cluster->tip assignment.
# Run in the OFF reference pass; read-only STA, changes nothing.
if {[info exists ::env(CTS_REALM_DUMP_ARRIVALS)] && $::env(CTS_REALM_DUMP_ARRIVALS) == 1} {
  set _realm_csv "$::env(CTS3D_WORK_DIR)/leaf_arrivals.csv"
  set _rfp [open $_realm_csv w]
  # member_ff = first FF driven by this leaf: robust cluster<->leaf key for the
  # V93 seeded scoring (immune to leaf-numbering shifts from tier/target splits).
  # arrival stays the LAST column so older parsers (rfind comma) keep working.
  puts $_rfp "leaf_name,x_dbu,y_dbu,member_ff,arrival_ps"
  set _rblk [ord::get_db_block]
  set _rn 0
  set _rfail 0
  set _rerr1 ""
  foreach _rinst [$_rblk getInsts] {
    set _rname [$_rinst getName]
    if {![string match "*clkbuf_leaf*" $_rname]} { continue }
    set _rmember ""
    catch {
      foreach _rot [$_rinst getITerms] {
        if {[[$_rot getMTerm] getIoType] ne "OUTPUT"} { continue }
        set _rnet [$_rot getNet]
        if {$_rnet eq "NULL" || $_rnet eq ""} { break }
        foreach _rsit [$_rnet getITerms] {
          set _rsinst [$_rsit getInst]
          set _rsname [$_rsinst getName]
          if {$_rsname eq $_rname} { continue }
          if {[[$_rsit getMTerm] getIoType] ne "INPUT"} { continue }
          # skip clock-tree cells (ghtap rungs, dummy loads): key must be an FF
          if {[string match "*clkbuf*" $_rsname] || [string match "*clkload*" $_rsname]} { continue }
          set _rmember $_rsname
          break
        }
        break
      }
    }
    foreach _rit [$_rinst getITerms] {
      if {[[$_rit getMTerm] getIoType] ne "INPUT"} { continue }
      if {[[$_rit getMTerm] getSigType] ne "SIGNAL"} { continue }
      set _rpin "${_rname}/[[$_rit getMTerm] getName]"
      if {[catch {
        set _rp [get_pins $_rpin]
        set _rarr [get_property $_rp arrival_max_rise]
        if {$_rarr ne "" && $_rarr ne "NONE" && $_rarr ne "INF"} {
          puts $_rfp "$_rname,0,0,$_rmember,[format %.3f [expr {[sta::time_ui_sta $_rarr] * 1e12}]]"
          incr _rn
        } else {
          incr _rfail
        }
      } _rerr]} {
        incr _rfail
        if {$_rerr1 eq ""} { set _rerr1 "$_rpin: $_rerr" }
      }
      break
    }
  }
  close $_rfp
  puts ">>> \[REALM-dump\] wrote $_rn leaf arrivals to $_realm_csv (fail=$_rfail)"
  if {$_rerr1 ne ""} { puts ">>> \[REALM-dump\] first error: $_rerr1" }
}

# Final summary (parasitics already refreshed above)
puts "\n========== 3D CTS Final Summary =========="
report_timing_summary "FINAL"
puts "  CTS cells: bottom=[llength $_cts_bottom_cells]  upper=[llength $_cts_upper_cells]"
puts "  Report: $::env(REPORTS_DIR)/4_cts_timing.rpt"
puts "========== 3D CTS Complete ==========\n"

# Image generation is optional and must not initialize Qt/X11 on a headless
# batch node.  Match TaiWei's native handoff policy: render only with a display
# or when the caller explicitly selected Qt's offscreen platform.
set _cts_display_ok [expr {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""}]
set _cts_qt_offscreen [expr {
  [info exists ::env(QT_QPA_PLATFORM)] && $::env(QT_QPA_PLATFORM) eq "offscreen"
}]
if {$_cts_display_ok || $_cts_qt_offscreen} {
  if {[catch {save_image -resolution 0.1 $::env(LOG_DIR)/4_cts.webp} _cts_image_err]} {
    puts "WARN(3DCTS): failed to write image $::env(LOG_DIR)/4_cts.webp : $_cts_image_err"
  }
} else {
  puts "INFO(3DCTS): skip image output $::env(LOG_DIR)/4_cts.webp in headless mode"
}

exit
