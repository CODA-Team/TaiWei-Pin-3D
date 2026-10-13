# =========================================
# Phase 1: Balanced CTS + Propagated-Clock Timing Graph Extraction (V46)
#
# changes from V44:
#   After balanced CTS + estimate_parasitics, switch to propagated clock and
#   re-extract FF->FF timing graph and IO timing edges.
#   This makes LP directly see cross-tier hold constraints correctly:
#     slack_propagated_ij = slack_ideal_ij + (lat_j - lat_i)
#   No manual base-latency correction needed in Phase 2 LP.
#
# outputs:
#   $CTS3D_WORK_DIR/cts_base_latency.csv          (per-FF latency, kept for debug)
#   $CTS3D_WORK_DIR/pre_cts_leaf_bounds.csv       (per-FF t_max bounds, for LP --bounds-csv)
#   $CTS3D_WORK_DIR/pre_cts_ff_timing_graph.csv   (propagated-clock FF->FF slacks -> LP)
#   $CTS3D_WORK_DIR/pre_cts_io_timing_edges.csv   (propagated-clock PI->FF slacks -> LP)
#
# This is a standalone sub-OpenROAD script invoked via:
#   exec $OPENROAD_EXE -threads $NUM_CORES -exit phase1_extract.tcl
# Inherits all env vars from the parent OpenROAD session.
# =========================================

# V44: Force relay=0 in this sub-process. The main Phase 1 still uses relays.
# CTS_ENABLE_PER_FF_RELAY is read by HTreeBuilder C++ via std::getenv().
set ::env(CTS_ENABLE_PER_FF_RELAY) 0

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

# Load design (same as cts_3d.tcl main session)
if {![info exists ::env(CTS3D_WORK_DIR)] || $::env(CTS3D_WORK_DIR) eq ""} {
  error "Phase 1 requires CTS3D_WORK_DIR"
}
file mkdir $::env(CTS3D_WORK_DIR)
load_design 3_place.def 3_place.sdc "Phase 1: Loading design for base latency measurement..."

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/floorplan_utils.tcl
source $::env(SCRIPTS_3DCTS_DIR)/platform_config.tcl

# Set ODB tier from master name suffixes

# V46: No pre-computed skew targets. Run plain balanced CTS (3-phase flow).
# CKMeans clustering will use default distance without target penalty.
puts ">>> \[Phase 1\] Running plain balanced CTS (no pre-computed skew targets, 3-phase flow)"

# Run balanced H-tree CTS (relay=0 forced via env var above)
repair_clock_inverters

# V48c: Dynamic buf_list (same logic as cts_3d.tcl build_buf_list_3d).
# Prevents NG45 charBuf selection → wrong wireSegmentUnit for ASAP7-majority designs.
set _block [ord::get_db_block]
set _bottom_ff 0
set _upper_ff 0
foreach _inst [$_block getInsts] {
  set _mname [[$_inst getMaster] getName]
  if {![regexp -nocase {DFF|SDFF} $_mname]} { continue }
  if {[string match "*bottom*" $_mname]} { incr _bottom_ff
  } elseif {[string match "*upper*" $_mname]} { incr _upper_ff }
}
set _total [expr {$_bottom_ff + $_upper_ff}]
puts "Phase1 buf_list: bottom_ff=$_bottom_ff, upper_ff=$_upper_ff, total=$_total"
# Macro designs (CTS_USE_ODB_EXTRACTION=1): always include both-tier buffers.
# Cross-tier clock net → macro pin causes DRT-0255 (maze route failure).
set _use_odb [expr {[info exists ::env(CTS_USE_ODB_EXTRACTION)] && $::env(CTS_USE_ODB_EXTRACTION)}]
if {$_use_odb && $_bottom_ff > 0} {
  set buf_list_3d "$::env(CTS_BUF_BOTTOM) $::env(CTS_BUF_UPPER)"
  puts "Phase1 buf_list = both-tier (macro design, $_bottom_ff bottom FFs) ($buf_list_3d)"
} elseif {$_total > 0 && [expr {double($_bottom_ff) / $_total}] < 0.5} {
  set buf_list_3d "$::env(CTS_BUF_UPPER)"
  puts "Phase1 buf_list = upper-only ($buf_list_3d)"
} else {
  set buf_list_3d "$::env(CTS_BUF_BOTTOM) $::env(CTS_BUF_UPPER)"
  puts "Phase1 buf_list = both ($buf_list_3d)"
}

set cts_args [list \
  -sink_clustering_enable \
  -repair_clock_nets \
  -root_buf $::env(CTS_BUF_CELL) \
  -buf_list $buf_list_3d
]

# V58: Macro designs need -no_insertion_delay in Phase 1 too
# (prevents LatencyBalancer delay buffer explosion during balanced CTS reference)
if {[info exists ::env(CTS_NO_INSERTION_DELAY)] && $::env(CTS_NO_INSERTION_DELAY)} {
  lappend cts_args -no_insertion_delay
  puts ">>> \[Phase 1\] CTS_NO_INSERTION_DELAY=1: LatencyBalancer disabled"
}

append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1

puts ">>> \[Phase 1\] Running balanced CTS (relay=0)..."
clock_tree_synthesis_3d {*}$cts_args

# Estimate parasitics for propagated-clock STA
estimate_parasitics -placement
puts ">>> \[Phase 1\] Parasitics estimated"

# V46: Generate per-FF physical achievability bounds (t_max per FF).
# Used by Phase 2 LP as --bounds-csv to cap a_i values.
# Bottom-tier: t_max = max_skew. Upper-tier: t_max = max_skew + t_via (HBT delay).
set max_skew_ns [expr {[info exists ::env(PRE_CTS_MAX_SKEW)] ? $::env(PRE_CTS_MAX_SKEW) : 0.100}]
set bounds_csv "$::env(CTS3D_WORK_DIR)/pre_cts_leaf_bounds.csv"
puts ">>> \[Phase 1\] Estimating leaf latency bounds (max_skew=${max_skew_ns}ns)..."
if {[catch {dcts::estimate_leaf_latencies $bounds_csv $max_skew_ns} err]} {
  puts "WARNING: \[Phase 1\] estimate_leaf_latencies failed: $err"
} else {
  puts ">>> \[Phase 1\] Leaf bounds written to $bounds_csv"
}

# Extract per-FF clock latency via STA (kept for debug/reference)
# Uses target_clk_delay from setup/hold paths (propagated clock after estimate_parasitics).
# Two passes to maximize FF coverage: setup paths (capture + launch FFs) + hold paths.
puts ">>> \[Phase 1\] Extracting per-FF base clock latency..."

set num_paths 10000
array set ff_base_latency {}

# Pass 1: Worst setup paths -> capture FFs (target_clk_delay) + launch FFs (source_clk_latency)
if {[catch {
  set path_ends [find_timing_paths -sort_by_slack -path_delay max \
                  -group_path_count $num_paths]
  foreach path_end $path_ends {
    set end_pin [get_full_name [$path_end pin]]
    set capture_ff [regsub {/[^/]+$} $end_pin ""]
    set capture_clk_ps [expr {[$path_end target_clk_delay] * 1e12}]

    if {![info exists ff_base_latency($capture_ff)]} {
      set ff_base_latency($capture_ff) $capture_clk_ps
    }

    # Also record launch FF from path start
    set all_pins [[$path_end path] pins]
    if {[llength $all_pins] > 0} {
      set start_pin [get_full_name [lindex $all_pins end]]
      set launch_ff [regsub {/[^/]+$} $start_pin ""]
      set launch_clk_ps [expr {[$path_end source_clk_latency] * 1e12}]
      if {![info exists ff_base_latency($launch_ff)]} {
        set ff_base_latency($launch_ff) $launch_clk_ps
      }
    }
  }
} err]} {
  puts "WARNING: \[Phase 1\] Setup path extraction: $err"
}
puts ">>> \[Phase 1\] Pass 1 (setup): [array size ff_base_latency] FFs covered"

# Pass 2: Worst hold paths -> may cover additional FFs with tight hold paths
if {[catch {
  set hold_ends [find_timing_paths -sort_by_slack -path_delay min \
                  -group_path_count $num_paths]
  foreach path_end $hold_ends {
    set end_pin [get_full_name [$path_end pin]]
    set capture_ff [regsub {/[^/]+$} $end_pin ""]
    if {![info exists ff_base_latency($capture_ff)]} {
      set ff_base_latency($capture_ff) [expr {[$path_end target_clk_delay] * 1e12}]
    }
    # Also record launch FF
    set all_pins [[$path_end path] pins]
    if {[llength $all_pins] > 0} {
      set start_pin [get_full_name [lindex $all_pins end]]
      set launch_ff [regsub {/[^/]+$} $start_pin ""]
      if {![info exists ff_base_latency($launch_ff)]} {
        set ff_base_latency($launch_ff) [expr {[$path_end source_clk_latency] * 1e12}]
      }
    }
  }
} err]} {
  puts "WARNING: \[Phase 1\] Hold path extraction: $err"
}
puts ">>> \[Phase 1\] Pass 2 (hold):  [array size ff_base_latency] FFs covered total"

# Compute statistics
set sum 0.0
set n [array size ff_base_latency]
if {$n > 0} {
  foreach ff [array names ff_base_latency] {
    set sum [expr {$sum + $ff_base_latency($ff)}]
  }
  set mean_ps [expr {$sum / $n}]
  puts ">>> \[Phase 1\] Mean base clock latency: [format %.2f $mean_ps] ps"
}

# Write base latency CSV: ff_name,base_latency_ps (kept for debug)
set out_csv "$::env(CTS3D_WORK_DIR)/cts_base_latency.csv"
set fp [open $out_csv w]
puts $fp "ff_name,base_latency_ps"
foreach ff [lsort [array names ff_base_latency]] {
  puts $fp "$ff,[format %.3f $ff_base_latency($ff)]"
}
close $fp
puts ">>> \[Phase 1\] Base latency written to $out_csv ($n FFs)"

# =========================================
# V46: Switch to propagated clock and re-extract timing graphs.
# Extracts propagated-clock timing graphs for Phase 2 LP.
# After set_propagated_clock, STA slacks automatically encode latency differences:
#   slack_propagated_ij = slack_ideal_ij + (lat_j - lat_i)
# Cross-tier: lat_upper > lat_bottom -> hold more tight, setup more slack.
# Phase 2 LP reads these propagated-clock CSVs directly (no manual correction).
# =========================================
set_propagated_clock [all_clocks]
puts ">>> \[Phase 1\] Switched to propagated clock mode (V46)"

# =========================================
# Acceptance Gate (monotonic guarantee) — save balanced-baseline TNS.
# Rationale: on low-headroom designs (e.g. aes) quantized cascaded-TAP useful-
# skew delivery + tier-structural latency bias can net-HARM timing vs a balanced
# tree (setup: ~25% wrong-sign realized skew; hold: base-latency tax from the
# inserted delay buffers on PI->FF paths). Phase 3 compares its delivery TNS
# against this balanced reference (measured here under the SAME propagated-clock
# pipeline) and reverts to a balanced rebuild if delivery regressed, so the
# framework is provably never worse than the balanced 3D baseline.
# =========================================
if {[catch {
  set _bal_s_tns [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]
  set _bal_h_tns [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
  set _bf [open "$::env(CTS3D_WORK_DIR)/cts_balanced_tns.txt" w]
  puts $_bf "$_bal_s_tns $_bal_h_tns"
  close $_bf
  puts [format ">>> \[Phase 1\] Balanced baseline saved (acceptance gate): setup TNS=%.1f ps  hold TNS=%.1f ps" $_bal_s_tns $_bal_h_tns]
} _gerr]} {
  puts "WARNING: \[Phase 1\] balanced TNS save failed: $_gerr"
}

# Re-extract FF->FF timing graph with propagated-clock slacks.
# Overwrites pre_cts_ff_timing_graph.csv for Phase 2 LP to read.
set verilog_file "$::env(RESULTS_DIR)/3_place.v"
set timing_csv   "$::env(CTS3D_WORK_DIR)/pre_cts_ff_timing_graph.csv"

# Skip extraction if CSV already exists and CTS_REUSE_TIMING_GRAPH=1.
# Place DB unchanged → timing graph identical. Saves ~30min for large designs (IBEX 2M edges).
set reuse_graph [expr {[info exists ::env(CTS_REUSE_TIMING_GRAPH)] && $::env(CTS_REUSE_TIMING_GRAPH)}]
if {$reuse_graph && [file exists $timing_csv]} {
  puts ">>> \[Phase 1\] Reusing existing timing graph: $timing_csv ([file size $timing_csv] bytes)"
} else {
  puts ">>> \[Phase 1\] Extracting FF->FF timing graph (propagated clock)..."
  # ODB+STA-based extraction (handles macro designs, superset of Verilog BFS)
  if {[catch {dcts::extract_ff_timing_graph_odb $timing_csv} err]} {
    puts "WARNING: \[Phase 1\] FF timing graph extraction failed: $err"
  } else {
    puts ">>> \[Phase 1\] Propagated-clock FF timing graph written to $timing_csv"
  }
}

# Re-extract IO timing edges with propagated-clock slacks.
# PI->FF hold slack already accounts for H-tree latency (lat_j subtracted).
# Proc definition inlined from cts_3d.tcl (not in scope for this subprocess).
proc extract_io_timing_edges_phase1a {output_csv {num_paths 10000}} {
  puts "  Extracting IO timing edges (PI->FF + FF->PO, propagated clock)..."

  array set pi_setup {}
  array set pi_hold {}
  array set pi_port {}
  array set po_setup {}
  array set po_hold {}
  array set po_port {}

  # Pass 1: PI->FF setup paths
  if {[catch {
    set paths [find_timing_paths -from [all_inputs] -to [all_registers] \
                -sort_by_slack -path_delay max -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff   [regsub {/[^/]+$} $end_pin ""]
      set port [regsub {/[^/]+$} $start_pin ""]
      if {![info exists pi_setup($ff)] || $slack_ns < $pi_setup($ff)} {
        set pi_setup($ff) $slack_ns
        set pi_port($ff)  $port
      }
    }
  } err]} { puts "  Warning: PI->FF setup: $err" }
  puts "  PI->FF setup: [array size pi_setup] unique FFs"

  # Pass 2: PI->FF hold paths
  if {[catch {
    set paths [find_timing_paths -from [all_inputs] -to [all_registers] \
                -sort_by_slack -path_delay min -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set ff   [regsub {/[^/]+$} $end_pin ""]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set port [regsub {/[^/]+$} $start_pin ""]
      if {![info exists pi_hold($ff)] || $slack_ns < $pi_hold($ff)} {
        set pi_hold($ff) $slack_ns
        if {![info exists pi_port($ff)]} { set pi_port($ff) $port }
      }
    }
  } err]} { puts "  Warning: PI->FF hold: $err" }
  puts "  PI->FF hold: [array size pi_hold] unique FFs"

  # Pass 3: FF->PO setup paths
  if {[catch {
    set paths [find_timing_paths -from [all_registers] -to [all_outputs] \
                -sort_by_slack -path_delay max -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff   [regsub {/[^/]+$} $start_pin ""]
      set port [regsub {/[^/]+$} $end_pin ""]
      if {![info exists po_setup($ff)] || $slack_ns < $po_setup($ff)} {
        set po_setup($ff) $slack_ns
        set po_port($ff)  $port
      }
    }
  } err]} { puts "  Warning: FF->PO setup: $err" }
  puts "  FF->PO setup: [array size po_setup] unique FFs"

  # Pass 4: FF->PO hold paths
  if {[catch {
    set paths [find_timing_paths -from [all_registers] -to [all_outputs] \
                -sort_by_slack -path_delay min -group_path_count $num_paths]
    foreach path_end $paths {
      set slack_ns [expr {[$path_end slack] * 1e9}]
      set end_pin [get_full_name [$path_end pin]]
      set all_pins [[$path_end path] pins]
      if {[llength $all_pins] == 0} continue
      set start_pin [get_full_name [lindex $all_pins end]]
      set ff   [regsub {/[^/]+$} $start_pin ""]
      set port [regsub {/[^/]+$} $end_pin ""]
      if {![info exists po_hold($ff)] || $slack_ns < $po_hold($ff)} {
        set po_hold($ff) $slack_ns
        if {![info exists po_port($ff)]} { set po_port($ff) $port }
      }
    }
  } err]} { puts "  Warning: FF->PO hold: $err" }
  puts "  FF->PO hold: [array size po_hold] unique FFs"

  # Write CSV
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
  puts "  Total IO edges: $count (PI->FF: [llength $all_pi_ffs], FF->PO: [llength $all_po_ffs])"
}

# V51_IO: Try C++ exhaustive IO extraction first, Tcl fallback.
set io_csv "$::env(CTS3D_WORK_DIR)/pre_cts_io_timing_edges.csv"
set _io_done 0
if {$reuse_graph && [file exists $io_csv]} {
  puts ">>> \[Phase 1\] Reusing existing IO timing edges: $io_csv"
  set _io_done 1
} else {
  puts ">>> \[Phase 1\] Extracting IO timing edges (propagated clock)..."
  # ODB-based IO extraction (exhaustive per-port STA, no Verilog needed)
  if {[catch {dcts::extract_io_timing_edges_odb $io_csv} err]} {
    puts ">>> \[Phase 1\] C++ IO extraction not available ($err), using Tcl fallback..."
    if {[catch {extract_io_timing_edges_phase1a $io_csv} err2]} {
      puts "WARNING: \[Phase 1\] IO timing edge extraction failed: $err2"
    } else {
      set _io_done 1
    }
  } else {
    set _io_done 1
  }
}
if {$_io_done} {
  puts ">>> \[Phase 1\] Propagated-clock IO timing edges written to $io_csv"
}

puts ">>> \[Phase 1\] Phase 1 complete (V46: propagated-clock timing graphs ready for Phase 2 LP)"
