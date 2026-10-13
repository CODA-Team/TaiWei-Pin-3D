# =========================================
# Buffer Insertion V22: 2-Step + Multi-Buffer
# =========================================
# V22:
#   Step 1: Leaf-level LP insertion (bulk improvement, fewer buffers)
#     - Insert buffer BEFORE leaf buffers → all FFs under leaf shift together
#     - Same-leaf FF pairs: hold automatically preserved
#     - Cross-leaf edges only: setup/hold checked
#   Step 2: Per-FF LP insertion (fine-tuning, method)
#     - Insert buffer at individual FF clock pins
#     - Full STA validation per buffer
#   + Multi-buffer cell selection (choose best cell per insertion)
#   + Per-location delay estimation (Strategy A)
# =========================================

# Global counter for unique buffer names
variable skew_buf_idx 0

# Track inserted buffers for potential rollback
variable inserted_buffer_info [list]

# ===============================================================
# SHARED PROCS (insert/remove buffer via ODB)
# ===============================================================

# Insert delay buffer using direct ODB API (avoids insert_buffer crash)
# Returns: list {buf_name old_net_name new_net_name pin_name} or empty list on failure
proc insert_delay_buffer_odb {pin_name buf_master_name} {
  variable skew_buf_idx

  set db [ord::get_db]
  set chip [$db getChip]
  if {$chip eq ""} {
    puts "ERROR: No chip loaded"
    return [list]
  }
  set block [$chip getBlock]

  # Find the pin
  set pin [get_pins $pin_name]
  if {$pin eq ""} {
    return [list]
  }

  set sta_pin [sta::sta_to_db_pin $pin]
  if {$sta_pin eq ""} {
    puts "WARNING: Cannot convert pin $pin_name"
    return [list]
  }

  set iterm $sta_pin
  set inst [$iterm getInst]

  # Get location for placing the buffer (near the target instance)
  set inst_box [$inst getBBox]
  set buf_x [expr {([$inst_box xMin] + [$inst_box xMax]) / 2}]
  set buf_y [expr {([$inst_box yMin] + [$inst_box yMax]) / 2}]

  # Find the buffer master
  set master [$db findMaster $buf_master_name]
  if {$master eq "" || $master eq "NULL"} {
    # Try without tier suffix
    set base_name [regsub {_(upper|bottom)$} $buf_master_name ""]
    set master [$db findMaster $base_name]
    if {$master eq "" || $master eq "NULL"} {
      puts "WARNING: Buffer master $buf_master_name (also tried $base_name) not found"
      return [list]
    }
  }

  # V23: Clamp buffer position to stay within die boundary
  set die_box [$block getDieArea]
  set master_w [$master getWidth]
  set master_h [$master getHeight]
  set die_xmin [$die_box xMin]
  set die_ymin [$die_box yMin]
  set die_xmax [$die_box xMax]
  set die_ymax [$die_box yMax]
  if {[expr {$buf_x + $master_w}] > $die_xmax} {
    set buf_x [expr {$die_xmax - $master_w}]
  }
  if {$buf_x < $die_xmin} {
    set buf_x $die_xmin
  }
  if {[expr {$buf_y + $master_h}] > $die_ymax} {
    set buf_y [expr {$die_ymax - $master_h}]
  }
  if {$buf_y < $die_ymin} {
    set buf_y $die_ymin
  }

  # Get the net connected to the pin
  set old_net [$iterm getNet]
  if {$old_net eq ""} {
    puts "WARNING: Pin $pin_name not connected to any net"
    return [list]
  }
  set old_net_name [$old_net getName]

  # Create unique buffer name
  set buf_name "skew_buf_${skew_buf_idx}"
  incr skew_buf_idx

  # Create new buffer instance
  if {[catch {
    set new_buf [odb::dbInst_create $block $master $buf_name]
  } err]} {
    puts "WARNING: Failed to create buffer: $err"
    return [list]
  }

  if {$new_buf eq "" || $new_buf eq "NULL"} {
    puts "WARNING: Buffer creation returned null for $buf_master_name"
    return [list]
  }

  # Set buffer location and placement status
  $new_buf setLocation $buf_x $buf_y
  $new_buf setPlacementStatus "PLACED"
  $new_buf setSourceType "TIMING"

  # Find buffer input and output pins
  set buf_in_iterm ""
  set buf_out_iterm ""
  foreach iterm_obj [$new_buf getITerms] {
    set mterm [$iterm_obj getMTerm]
    set sig_type [$mterm getSigType]
    set io_type [$mterm getIoType]
    if {$sig_type eq "SIGNAL"} {
      if {$io_type eq "INPUT"} {
        set buf_in_iterm $iterm_obj
      } elseif {$io_type eq "OUTPUT"} {
        set buf_out_iterm $iterm_obj
      }
    }
  }

  if {$buf_in_iterm eq "" || $buf_out_iterm eq ""} {
    puts "WARNING: Could not find buffer I/O pins"
    odb::dbInst_destroy $new_buf
    return [list]
  }

  # Create new net for buffer output
  set new_net_name "${old_net_name}_skew_${skew_buf_idx}"
  set new_net [odb::dbNet_create $block $new_net_name]
  if {$new_net eq ""} {
    puts "WARNING: Failed to create net $new_net_name"
    odb::dbInst_destroy $new_buf
    return [list]
  }

  # Wire: old_net -> buf_in -> buf_out -> new_net -> target_pin
  $iterm disconnect
  $buf_in_iterm connect $old_net
  $buf_out_iterm connect $new_net
  $iterm connect $new_net

  return [list $buf_name $old_net_name $new_net_name $pin_name]
}

# Remove a buffer and restore original connection
proc remove_buffer {buf_info} {
  if {[llength $buf_info] < 4} {
    return 0
  }

  set buf_name [lindex $buf_info 0]
  set old_net_name [lindex $buf_info 1]
  set new_net_name [lindex $buf_info 2]
  set pin_name [lindex $buf_info 3]

  set db [ord::get_db]
  set block [[$db getChip] getBlock]

  set buf_inst [$block findInst $buf_name]
  if {$buf_inst eq "NULL" || $buf_inst eq ""} {
    puts "WARNING: Buffer $buf_name not found for removal"
    return 0
  }

  set old_net [$block findNet $old_net_name]
  if {$old_net eq "NULL" || $old_net eq ""} {
    puts "WARNING: Original net $old_net_name not found"
    return 0
  }

  set pin [get_pins $pin_name]
  if {$pin eq ""} {
    puts "WARNING: Pin $pin_name not found"
    return 0
  }
  set target_iterm [sta::sta_to_db_pin $pin]

  # Reconnect target pin to original net
  $target_iterm disconnect
  $target_iterm connect $old_net

  # Delete new net
  set new_net [$block findNet $new_net_name]
  if {$new_net ne "NULL" && $new_net ne ""} {
    odb::dbNet_destroy $new_net
  }

  # Delete buffer instance
  odb::dbInst_destroy $buf_inst
  return 1
}

# Insert buffer(s) at a pin with specific cell selection
# V22: Added optional buf_cell parameter for multi-buffer support
proc insert_buffers_at_pin {pin_name num_buffers tier {buf_cell ""}} {
  # Determine buf_cell if not specified
  if {$buf_cell eq ""} {
    set actual_tier $tier
    if {[string match "*__upper*" $pin_name]} { set actual_tier 1 }
    if {[string match "*__bottom*" $pin_name]} { set actual_tier 0 }

    if {$actual_tier == 1} {
      if {[info exists ::env(CTS_BUF_UPPER)]} {
        set buf_cell [lindex $::env(CTS_BUF_UPPER) 0]
      } else {
        set buf_cell "BUFx2_ASAP7_75t_R_upper"
      }
    } else {
      if {[info exists ::env(CTS_BUF_BOTTOM)]} {
        set buf_cell [lindex $::env(CTS_BUF_BOTTOM) 0]
      } else {
        set buf_cell "BUFx2_ASAP7_75t_R_bottom"
      }
    }
  }

  set inserted_list [list]
  for {set i 0} {$i < $num_buffers} {incr i} {
    set buf_info [insert_delay_buffer_odb $pin_name $buf_cell]
    if {[llength $buf_info] > 0} {
      lappend inserted_list $buf_info
    } else {
      break
    }
  }
  return $inserted_list
}

# Remove all buffers in a list (rollback, reverse order)
proc remove_buffers {buf_list} {
  set removed 0
  for {set i [expr {[llength $buf_list] - 1}]} {$i >= 0} {incr i -1} {
    set buf_info [lindex $buf_list $i]
    if {[remove_buffer $buf_info]} {
      incr removed
    }
  }
  return $removed
}

# Timing queries
proc get_current_tns {} {
  return [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
}
proc get_current_hold_wns {} {
  return [expr {[sta::worst_slack_cmd "min"] * 1e12}]
}
proc get_current_hold_tns {} {
  return [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
}

# ===============================================================
# NEW: EXTRACTION PROCS
# ===============================================================

# Estimate buffer delay from drive strength
# Calibrated for ASAP7: BUFx4 ≈ 12ps
proc estimate_buf_delay_from_strength {strength} {
  if {$strength <= 0} { set strength 4 }
  # Model: delay ≈ k / sqrt(strength), with k calibrated to BUFx4=12ps
  return [expr {0.024 / sqrt(double($strength))}]
}

# Try to measure actual delay of an existing buffer instance from STA
proc measure_inst_delay {inst_name} {
  set db [ord::get_db]
  set block [[$db getChip] getBlock]
  set inst [$block findInst $inst_name]
  if {$inst eq "NULL" || $inst eq ""} { return -1 }

  # Find input and output pin names
  set in_pin_name ""
  set out_pin_name ""
  foreach iterm [$inst getITerms] {
    set mterm [$iterm getMTerm]
    if {[$mterm getSigType] ne "SIGNAL"} continue
    if {[$mterm getIoType] eq "INPUT"} {
      set in_pin_name "${inst_name}/[$mterm getName]"
    } elseif {[$mterm getIoType] eq "OUTPUT"} {
      set out_pin_name "${inst_name}/[$mterm getName]"
    }
  }
  if {$in_pin_name eq "" || $out_pin_name eq ""} { return -1 }

  # Try STA arrival-based measurement
  if {[catch {
    set in_pin [get_pins $in_pin_name]
    set out_pin [get_pins $out_pin_name]
    if {$in_pin eq "" || $out_pin eq ""} { return -1 }

    # Try sta::pin_arrival (OpenROAD internal)
    set in_arr ""
    set out_arr ""
    catch { set in_arr [sta::pin_arrival $in_pin "rise" "max"] }
    catch { set out_arr [sta::pin_arrival $out_pin "rise" "max"] }

    if {$in_arr ne "" && $out_arr ne "" &&
        [string is double -strict $in_arr] && [string is double -strict $out_arr]} {
      set delay [expr {$out_arr - $in_arr}]
      if {$delay > 0 && $delay < 0.5} {
        return $delay
      }
    }
  } err]} {}

  return -1
}

# Extract available buffer cells and their estimated delays
# Strategy A: tries to measure actual delay from existing instances
# Fallback: drive-strength-based estimation
proc extract_buffer_cell_delays {output_csv} {
  puts "Extracting buffer cell delays (Strategy A)..."

  set db [ord::get_db]
  set block [[$db getChip] getBlock]

  # Map: cell_name -> first instance name (for delay measurement)
  set cell_to_inst [dict create]
  foreach inst [$block getInsts] {
    set cell [[$inst getMaster] getName]
    if {![string match "*BUF*" [string toupper $cell]]} continue
    if {![string match "*_bottom" $cell] && ![string match "*_upper" $cell]} continue
    if {![dict exists $cell_to_inst $cell]} {
      dict set cell_to_inst $cell [$inst getName]
    }
  }

  # Also add available masters from ODB not yet instantiated
  foreach lib [$db getLibs] {
    foreach master [$lib getMasters] {
      set name [$master getName]
      if {![string match "*BUF*" [string toupper $name]]} continue
      if {![string match "*_bottom" $name] && ![string match "*_upper" $name]} continue
      # Exclude inverters (INV)
      if {[string match "*INV*" [string toupper $name]]} continue
      if {![dict exists $cell_to_inst $name]} {
        dict set cell_to_inst $name ""
      }
    }
  }

  set fp [open $output_csv w]
  puts $fp "buf_cell,tier,delay_ns,drive_strength"

  set count 0
  set measured 0
  set estimated 0

  foreach cell [dict keys $cell_to_inst] {
    set tier [expr {[string match "*_upper" $cell] ? 1 : 0}]

    # Extract drive strength
    set strength 4
    if {[regexp {BUFx(\d+)f?_} $cell -> s]} { set strength $s }
    if {[regexp {BUF_X(\d+)_} $cell -> s]} { set strength $s }

    # Strategy A: try measuring from existing instance
    set inst_name [dict get $cell_to_inst $cell]
    set delay_ns -1
    if {$inst_name ne ""} {
      set delay_ns [measure_inst_delay $inst_name]
    }

    if {$delay_ns > 0} {
      incr measured
    } else {
      # Fallback: drive-strength estimation
      set delay_ns [estimate_buf_delay_from_strength $strength]
      incr estimated
    }

    puts $fp "$cell,$tier,[format %.6f $delay_ns],$strength"
    incr count
  }

  close $fp
  puts "  Found $count buffer cells ($measured STA-measured, $estimated estimated)"
  puts "  Written to $output_csv"
  return $count
}

# Extract leaf buffer groups: leaf buffers and their driven FFs
proc extract_leaf_buffer_groups {output_csv} {
  puts "Extracting leaf buffer groups..."

  set db [ord::get_db]
  set block [[$db getChip] getBlock]

  set fp [open $output_csv w]
  puts $fp "leaf_inst,leaf_cell,leaf_input_pin,tier,driven_ffs"

  set leaf_count 0
  set total_ffs 0

  foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    set master [$inst getMaster]
    set cell_name [$master getName]

    # Must be a BUF cell with tier suffix
    if {![string match "*BUF*" [string toupper $cell_name]]} continue
    if {![string match "*_bottom" $cell_name] && ![string match "*_upper" $cell_name]} continue

    # Find input pin and driven FFs
    set input_pin_name ""
    set driven_ffs [list]

    foreach iterm [$inst getITerms] {
      set mterm [$iterm getMTerm]
      set sig_type [$mterm getSigType]
      set io_type [$mterm getIoType]

      if {$sig_type eq "SIGNAL" && $io_type eq "INPUT"} {
        set input_pin_name "${inst_name}/[$mterm getName]"
      }

      if {$sig_type eq "SIGNAL" && $io_type eq "OUTPUT"} {
        set out_net [$iterm getNet]
        if {$out_net eq "NULL" || $out_net eq ""} continue

        foreach fanout_iterm [$out_net getITerms] {
          set fanout_inst [$fanout_iterm getInst]
          set fanout_master [$fanout_inst getMaster]

          if {[$fanout_master isSequential]} {
            set fanout_mterm [$fanout_iterm getMTerm]
            set pin_name [$fanout_mterm getName]

            if {[string match "*CLK*" [string toupper $pin_name]] || \
                [string match "*CK" [string toupper $pin_name]]} {
              lappend driven_ffs [$fanout_inst getName]
            }
          }
        }
      }
    }

    # Only include if this buffer drives at least one FF (it's a leaf buffer)
    if {[llength $driven_ffs] == 0} continue

    set tier [expr {[string match "*_upper" $cell_name] ? 1 : 0}]
    set ffs_str [join $driven_ffs ";"]

    puts $fp "$inst_name,$cell_name,$input_pin_name,$tier,$ffs_str"
    incr leaf_count
    incr total_ffs [llength $driven_ffs]
  }

  close $fp
  puts "  Found $leaf_count leaf buffers driving $total_ffs FFs"
  puts "  Written to $output_csv"
  return $leaf_count
}

# Select best buffer cell + count for a target delay
# Returns: {buf_cell num_bufs actual_delay_ns}
proc select_best_buffer {target_delay_ns buf_delays_list tier {max_bufs 3}} {
  set best_cell ""
  set best_count 0
  set best_diff 999.0
  set best_delay 0.0

  foreach entry $buf_delays_list {
    set cell [lindex $entry 0]
    set cell_tier [lindex $entry 1]
    set cell_delay [lindex $entry 2]

    if {$cell_tier != $tier} continue
    if {$cell_delay <= 0} continue

    for {set n 1} {$n <= $max_bufs} {incr n} {
      set actual [expr {$n * $cell_delay}]
      set diff [expr {abs($actual - $target_delay_ns)}]
      if {$diff < $best_diff} {
        set best_diff $diff
        set best_cell $cell
        set best_count $n
        set best_delay $actual
      }
    }
  }

  return [list $best_cell $best_count $best_delay]
}

# Load buffer cell delays from CSV into a list
# Returns: list of {cell_name tier delay_ns}
proc load_buf_delays {csv_file} {
  set delays [list]
  if {![file exists $csv_file]} { return $delays }

  set fp [open $csv_file r]
  gets $fp header
  while {[gets $fp line] >= 0} {
    set fields [split $line ","]
    if {[llength $fields] < 3} continue
    set cell [lindex $fields 0]
    set tier [lindex $fields 1]
    set delay [lindex $fields 2]
    lappend delays [list $cell $tier $delay]
  }
  close $fp
  return $delays
}

# ===============================================================
# STEP 1: LEAF-LEVEL INSERTION
# ===============================================================

proc run_leaf_level_insertion {} {
  global env
  variable skew_buf_idx

  puts "\n=========================================="
  puts "STEP 1: LEAF-LEVEL BUFFER INSERTION (V22)"
  puts "=========================================="

  set results_dir $env(CTS3D_WORK_DIR)
  set script_dir [file dirname [info script]]
  set verilog_file "$results_dir/4_cts.v"

  # CSV file paths
  set leaf_csv "$results_dir/leaf_buffer_groups.csv"
  set timing_csv "$results_dir/ff_timing_graph.csv"
  set buf_delays_csv "$results_dir/buffer_cell_delays.csv"
  set leaf_plan_csv "$results_dir/leaf_insertion_plan.csv"
  set python_script "$script_dir/buffer_insertion_leaf_lp.py"

  if {![file exists $python_script]} {
    puts "ERROR: Leaf LP script not found: $python_script"
    puts "Skipping leaf-level insertion."
    return 0
  }

  # Parameters (shared with per-FF phase)
  set max_skew [expr {[info exists env(USEFUL_SKEW_MAX_NS)] ? $env(USEFUL_SKEW_MAX_NS) : 0.060}]
  set delta_hb [expr {[info exists env(USEFUL_SKEW_DELTA_HB)] ? $env(USEFUL_SKEW_DELTA_HB) : 0.005}]
  set max_total_buffers [expr {[info exists env(USEFUL_SKEW_MAX_BUFFERS)] ? $env(USEFUL_SKEW_MAX_BUFFERS) : 200}]
  set hold_margin [expr {[info exists env(USEFUL_SKEW_HOLD_MARGIN)] ? $env(USEFUL_SKEW_HOLD_MARGIN) : 0.01}]
  set hold_weight [expr {[info exists env(HOLD_WEIGHT)] ? $env(HOLD_WEIGHT) : 1.0}]
  set setup_tol [expr {[info exists env(SETUP_TOLERANCE)] ? $env(SETUP_TOLERANCE) : 5.0}]
  set max_consec_rejects [expr {[info exists env(MAX_CONSEC_REJECTS)] ? $env(MAX_CONSEC_REJECTS) : 20}]
  set max_bufs_per_leaf [expr {[info exists env(MAX_BUFS_PER_LEAF)] ? $env(MAX_BUFS_PER_LEAF) : 3}]
  # Leaf-level gets half the total budget (rest for per-FF)
  set leaf_budget [expr {$max_total_buffers / 2}]

  puts "Parameters:"
  puts "  max_skew:       ${max_skew}ns ([expr {$max_skew * 1000}]ps)"
  puts "  hold_margin:    ${hold_margin}ns"
  puts "  delta_hb:       ${delta_hb}ns"
  puts "  leaf_budget:    $leaf_budget buffers (of $max_total_buffers total)"
  puts "  hold_guard:     strict (no degradation allowed)"
  puts "  max_bufs/leaf:  $max_bufs_per_leaf"

  # Baseline timing
  set baseline_tns [get_current_tns]
  set baseline_hold_wns [get_current_hold_wns]
  puts "\nBaseline:"
  puts "  Setup TNS: [format %.2f $baseline_tns] ps"
  puts "  Hold  WNS: [format %.2f $baseline_hold_wns] ps"

  # --- Extract leaf groups ---
  puts "\n--- Extracting leaf buffer groups ---"
  set n_leafs [extract_leaf_buffer_groups $leaf_csv]
  if {$n_leafs == 0} {
    puts "  No leaf buffers found. Skipping leaf-level insertion."
    return 0
  }

  # --- Extract timing graph ---
  puts "\n--- Extracting timing graph ---"
  if {![file exists $verilog_file]} {
    puts "  WARNING: Verilog not found, trying 3_place.v"
    set verilog_file "$env(RESULTS_DIR)/3_place.v"
  }
  if {[catch {dcts::extract_ff_timing_graph_verilog $verilog_file $timing_csv} err]} {
    puts "WARNING: Timing graph extraction failed: $err"
    return 0
  }

  # --- Extract buffer cell delays ---
  puts "\n--- Extracting buffer cell delays ---"
  extract_buffer_cell_delays $buf_delays_csv

  # --- Run Python leaf LP ---
  puts "\n--- Running leaf-level LP ---"
  set cmd "python3 $python_script $leaf_csv $timing_csv $buf_delays_csv $leaf_plan_csv"
  append cmd " --max-skew $max_skew"
  append cmd " --hold-margin $hold_margin"
  append cmd " --delta-hb $delta_hb"
  append cmd " --max-buffers $leaf_budget"
  append cmd " --hold-weight $hold_weight"
  append cmd " --max-bufs-per-leaf $max_bufs_per_leaf"

  if {[catch {exec {*}$cmd} output]} {
    if {![file exists $leaf_plan_csv]} {
      puts "  Leaf LP failed. Skipping."
      puts "  Error: $output"
      return 0
    }
  }
  puts $output

  # --- Parse leaf insertion plan ---
  if {![file exists $leaf_plan_csv]} {
    puts "  No leaf plan generated."
    return 0
  }

  set fp [open $leaf_plan_csv r]
  gets $fp header
  set leaf_plan [list]
  while {[gets $fp line] >= 0} {
    set fields [split $line ","]
    if {[llength $fields] < 7} continue
    set leaf_inst [lindex $fields 0]
    set buf_cell [lindex $fields 1]
    set num_bufs [lindex $fields 2]
    set delay_ns [lindex $fields 3]
    set n_ffs [lindex $fields 4]
    set tier [lindex $fields 5]
    set input_pin [lindex $fields 6]
    if {$num_bufs > 0} {
      lappend leaf_plan [list $leaf_inst $buf_cell $num_bufs $delay_ns $n_ffs $tier $input_pin]
    }
  }
  close $fp

  puts "\n--- Leaf insertion plan: [llength $leaf_plan] leafs ---"
  if {[llength $leaf_plan] == 0} {
    puts "  Nothing to insert."
    return 0
  }

  # --- Iterative insertion with STA validation ---
  puts "\n--- Inserting buffers (STA validated) ---"
  set total_inserted 0
  set total_rejected 0
  set total_bufs_inserted 0
  set prev_tns $baseline_tns
  set prev_hold_wns $baseline_hold_wns
  set consec_rejects 0

  foreach plan $leaf_plan {
    set leaf_inst [lindex $plan 0]
    set buf_cell [lindex $plan 1]
    set num_bufs [lindex $plan 2]
    set delay_ns [lindex $plan 3]
    set n_ffs [lindex $plan 4]
    set tier [lindex $plan 5]
    set input_pin [lindex $plan 6]

    # Insert buffer(s) before the leaf buffer's input pin
    set buf_list [insert_buffers_at_pin $input_pin $num_bufs $tier $buf_cell]
    if {[llength $buf_list] == 0} {
      puts "  SKIP $leaf_inst (insertion failed)"
      continue
    }

    # Placement + parasitics
    if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
      # Skip DPL in heterogeneous mode
    } else {
      if {[catch {detailed_placement} err]} {
        # Non-fatal
      }
    }
    estimate_parasitics -placement

    # Check setup/hold (strict guard)
    set new_tns [get_current_tns]
    set new_hold_wns [get_current_hold_wns]
    set setup_delta [expr {$prev_tns - $new_tns}]

    set accept 1
    set reason ""

    # Hold guard: reject if worse than baseline
    if {$new_hold_wns < $baseline_hold_wns} {
      set accept 0
      set reason "hold (WNS=[format %.1f $new_hold_wns]ps < baseline=[format %.1f $baseline_hold_wns]ps)"
    }

    # Hold guard: reject if worse than previous accepted
    if {$accept && $new_hold_wns < $prev_hold_wns} {
      set accept 0
      set reason "hold jump (WNS=[format %.1f $new_hold_wns]ps < prev=[format %.1f $prev_hold_wns]ps)"
    }

    # Setup guard: reject if setup worsens beyond tolerance
    if {$accept && $setup_delta < -$setup_tol} {
      set accept 0
      set reason "setup worsened [format %.1f [expr {-$setup_delta}]]ps"
    }

    if {$accept} {
      set prev_tns $new_tns
      set prev_hold_wns $new_hold_wns
      incr total_inserted
      incr total_bufs_inserted [llength $buf_list]
      set consec_rejects 0
      puts "  ACCEPT $leaf_inst ($buf_cell x[llength $buf_list], ${n_ffs}FFs) | TNS=[format %.1f $new_tns] delta=[format %+.1f [expr {-$setup_delta}]] hold=[format %.1f $new_hold_wns]ps"
    } else {
      remove_buffers $buf_list
      estimate_parasitics -placement
      incr total_rejected
      incr consec_rejects
      puts "  REJECT $leaf_inst ($buf_cell x[llength $buf_list], ${n_ffs}FFs) | $reason"
    }

    if {$consec_rejects >= $max_consec_rejects} {
      puts "\n  CONVERGED: $max_consec_rejects consecutive rejections."
      break
    }
  }

  # Summary
  set final_tns [get_current_tns]
  set final_hold_wns [get_current_hold_wns]
  set setup_improve [expr {$baseline_tns - $final_tns}]
  set hold_delta [expr {$final_hold_wns - $baseline_hold_wns}]

  puts "\n=========================================="
  puts "STEP 1 COMPLETE: LEAF-LEVEL INSERTION"
  puts "=========================================="
  puts "  Leafs modified: $total_inserted"
  puts "  Leafs rejected: $total_rejected"
  puts "  Buffers inserted: $total_bufs_inserted"
  puts "--- Setup Timing ---"
  puts "  Baseline TNS: [format %.2f $baseline_tns] ps"
  puts "  Final    TNS: [format %.2f $final_tns] ps"
  puts "  Improvement:  [format %.2f $setup_improve] ps"
  puts "--- Hold Timing ---"
  puts "  Baseline Hold WNS: [format %.2f $baseline_hold_wns] ps"
  puts "  Final    Hold WNS: [format %.2f $final_hold_wns] ps"
  puts "  Hold WNS delta: [format %+.2f $hold_delta] ps (positive=improved)"
  puts "=========================================="

  return $total_bufs_inserted
}

# ===============================================================
# STEP 2: PER-FF INSERTION (method with multi-buffer)
# ===============================================================

proc run_per_ff_insertion {remaining_budget} {
  global env
  variable skew_buf_idx

  puts "\n=========================================="
  puts "STEP 2: PER-FF BUFFER INSERTION (V22)"
  puts "=========================================="

  set results_dir $env(CTS3D_WORK_DIR)
  set script_dir [file dirname [info script]]
  set verilog_file "$results_dir/4_cts.v"
  set ff_graph_file "$results_dir/ff_timing_graph.csv"
  set lp_output_file "$results_dir/buffer_insertion_lp_result.csv"
  set buf_delays_csv "$results_dir/buffer_cell_delays.csv"
  set python_script "$script_dir/buffer_insertion_lp.py"

  if {![file exists $python_script]} {
    puts "ERROR: LP solver script not found: $python_script"
    return
  }
  if {![file exists $verilog_file]} {
    set verilog_file "$env(RESULTS_DIR)/3_place.v"
  }

  # Parameters
  set max_skew [expr {[info exists env(USEFUL_SKEW_MAX_NS)] ? $env(USEFUL_SKEW_MAX_NS) : 0.060}]
  set buf_delay [expr {[info exists env(USEFUL_SKEW_BUF_DELAY_NS)] ? $env(USEFUL_SKEW_BUF_DELAY_NS) : 0.012}]
  set max_ffs [expr {[info exists env(USEFUL_SKEW_MAX_FFS)] ? $env(USEFUL_SKEW_MAX_FFS) : 9999}]
  set skip_hold [expr {[info exists env(USEFUL_SKEW_SKIP_HOLD)] ? $env(USEFUL_SKEW_SKIP_HOLD) : 0}]
  set delta_hb [expr {[info exists env(USEFUL_SKEW_DELTA_HB)] ? $env(USEFUL_SKEW_DELTA_HB) : 0.005}]
  set hold_margin [expr {[info exists env(USEFUL_SKEW_HOLD_MARGIN)] ? $env(USEFUL_SKEW_HOLD_MARGIN) : 0.01}]
  set hold_weight [expr {[info exists env(HOLD_WEIGHT)] ? $env(HOLD_WEIGHT) : 1.0}]
  set max_iters [expr {[info exists env(INSERTION_MAX_ITERS)] ? $env(INSERTION_MAX_ITERS) : 500}]
  set setup_tol [expr {[info exists env(SETUP_TOLERANCE)] ? $env(SETUP_TOLERANCE) : 5.0}]
  set max_consec_rejects [expr {[info exists env(MAX_CONSEC_REJECTS)] ? $env(MAX_CONSEC_REJECTS) : 20}]

  # Load buffer delay options for multi-buffer selection
  set buf_delays_list [load_buf_delays $buf_delays_csv]

  puts "Parameters:"
  puts "  remaining_budget: $remaining_budget buffers"
  puts "  max_skew:       ${max_skew}ns"
  puts "  buf_delay:      ${buf_delay}ns (LP default)"
  puts "  hold_margin:    ${hold_margin}ns"
  puts "  hold_guard:     strict (no degradation allowed)"
  puts "  multi-buffer:   [llength $buf_delays_list] cell options"

  # Baseline timing (after Step 1)
  set baseline_tns [get_current_tns]
  set baseline_hold_wns [get_current_hold_wns]
  set baseline_hold_tns [get_current_hold_tns]
  puts "\nBaseline (post Step 1):"
  puts "  Setup TNS: [format %.2f $baseline_tns] ps"
  puts "  Hold  WNS: [format %.2f $baseline_hold_wns] ps"

  # Per-buffer iteration
  set total_inserted 0
  set total_rejected 0
  set total_skipped 0
  set prev_tns $baseline_tns
  set prev_hold_wns $baseline_hold_wns
  set consec_rejects 0
  set blocked_ffs [dict create]

  # V35-fix: Extract timing graph and solve LP ONCE before the loop
  # Previously called every iteration, causing:
  #   - SIGSEGV crash in STA (ClkInfo::cmp dangling pointer after repeated netlist mods)
  #   - Timeout on large designs (85K edges x 5739 startpoints x N iterations)
  write_verilog $results_dir/4_cts.v

  if {[catch {dcts::extract_ff_timing_graph_verilog $verilog_file $ff_graph_file} err]} {
    puts "WARNING: Graph extraction failed: $err"
    return
  }

  set cmd "python3 $python_script $ff_graph_file $lp_output_file"
  append cmd " --max-skew $max_skew --buf-delay $buf_delay"
  append cmd " --max-ffs $max_ffs"
  append cmd " --delta-hb $delta_hb"
  append cmd " --max-buffers $remaining_budget"
  append cmd " --hold-margin $hold_margin"
  append cmd " --hold-weight $hold_weight"
  if {$skip_hold} {
    append cmd " --skip-hold"
  }

  if {[catch {exec {*}$cmd} output]} {
    if {![file exists $lp_output_file]} {
      puts "  LP solver failed. Stopping."
      return
    }
  } else {
    puts $output
  }

  # Parse LP results (full priority list)
  set fp [open $lp_output_file r]
  set header [gets $fp]
  set lp_results [list]
  while {[gets $fp line] >= 0} {
    set fields [split $line ","]
    if {[llength $fields] < 4} continue
    set ff [lindex $fields 0]
    set skew_ns [lindex $fields 1]
    set num_bufs [lindex $fields 2]
    set tier [lindex $fields 3]
    if {$num_bufs > 0} {
      lappend lp_results [list $ff $skew_ns $num_bufs $tier]
    }
  }
  close $fp

  if {[llength $lp_results] == 0} {
    puts "\n  LP: no FFs to optimize. Converged."
    return
  }

  puts "\n  LP produced [llength $lp_results] candidates. Starting greedy insertion..."

  for {set iter 0} {$iter < $max_iters} {incr iter} {
    if {$remaining_budget <= 0} {
      puts "\n>>> Budget exhausted."
      break
    }

    # Pick best non-blocked FF from pre-computed LP list
    set target ""
    foreach result $lp_results {
      set ff [lindex $result 0]
      if {![dict exists $blocked_ffs $ff]} {
        set target $result
        break
      }
    }

    if {$target eq ""} {
      puts "\n  All [llength $lp_results] LP targets blocked ([dict size $blocked_ffs] FFs). Stopping."
      break
    }

    set ff [lindex $target 0]
    set skew_ns [lindex $target 1]
    set tier [lindex $target 3]
    set clean_ff [string map {\\ ""} $ff]

    # V22: Multi-buffer selection — pick best cell for target delay
    set selected_cell ""
    if {[llength $buf_delays_list] > 0 && $skew_ns > 0} {
      set sel [select_best_buffer $skew_ns $buf_delays_list $tier 1]
      set selected_cell [lindex $sel 0]
    }

    # Insert 1 buffer with selected cell
    set buf_list [insert_buffers_at_pin "${clean_ff}/CLK" 1 $tier $selected_cell]
    if {[llength $buf_list] == 0} {
      set buf_list [insert_buffers_at_pin "${clean_ff}/CK" 1 $tier $selected_cell]
    }
    if {[llength $buf_list] == 0} {
      dict set blocked_ffs $ff 1
      incr total_skipped
      puts "  [format %3d [expr {$iter+1}]] SKIP $clean_ff (insertion failed)"
      continue
    }

    # Placement + parasitics
    if {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)} {
      # Skip DPL
    } else {
      if {[catch {detailed_placement} err]} {}
    }
    estimate_parasitics -placement

    # Check setup/hold (strict guard)
    set new_tns [get_current_tns]
    set new_hold_wns [get_current_hold_wns]
    set setup_delta [expr {$prev_tns - $new_tns}]

    set accept 1
    set reason ""

    # Hold guard: reject if worse than baseline
    if {$new_hold_wns < $baseline_hold_wns} {
      set accept 0
      set reason "hold (WNS=[format %.1f $new_hold_wns]ps < baseline=[format %.1f $baseline_hold_wns]ps)"
    }

    # Hold guard: reject if worse than previous
    if {$accept && $new_hold_wns < $prev_hold_wns} {
      set accept 0
      set reason "hold jump (WNS=[format %.1f $new_hold_wns]ps < prev=[format %.1f $prev_hold_wns]ps)"
    }

    # Setup guard
    if {$accept && $setup_delta < -$setup_tol} {
      set accept 0
      set reason "setup worsened [format %.1f [expr {-$setup_delta}]]ps"
    }

    if {$accept} {
      incr total_inserted
      incr remaining_budget -1
      set prev_tns $new_tns
      set prev_hold_wns $new_hold_wns
      set consec_rejects 0
      set used_cell [lindex [lindex $buf_list 0] 0]
      puts "  [format %3d [expr {$iter+1}]] ACCEPT $clean_ff | TNS=[format %.1f $new_tns] delta=[format %+.1f [expr {-$setup_delta}]] hold=[format %.1f $new_hold_wns]ps"
    } else {
      remove_buffers $buf_list
      estimate_parasitics -placement
      incr total_rejected
      dict set blocked_ffs $ff 1
      incr consec_rejects
      puts "  [format %3d [expr {$iter+1}]] REJECT $clean_ff | $reason"
    }

    if {$consec_rejects >= $max_consec_rejects} {
      puts "\n  CONVERGED: $max_consec_rejects consecutive rejections."
      break
    }
  }

  # Summary
  set final_tns [get_current_tns]
  set final_hold_wns [get_current_hold_wns]
  set final_hold_tns [get_current_hold_tns]
  set setup_improve [expr {$baseline_tns - $final_tns}]
  set hold_delta [expr {$final_hold_wns - $baseline_hold_wns}]

  puts "\n=========================================="
  puts "STEP 2 COMPLETE: PER-FF INSERTION"
  puts "=========================================="
  puts "  Total iterations: [expr {min($iter + 1, $max_iters)}]"
  puts "  Buffers inserted: $total_inserted"
  puts "  Rejected: $total_rejected"
  puts "  Skipped: $total_skipped"
  puts "  FFs blocked: [dict size $blocked_ffs]"
  puts "  Remaining budget: $remaining_budget"
  puts "--- Setup Timing ---"
  puts "  Baseline TNS: [format %.2f $baseline_tns] ps"
  puts "  Final    TNS: [format %.2f $final_tns] ps"
  puts "  Improvement:  [format %.2f $setup_improve] ps"
  puts "--- Hold Timing ---"
  puts "  Baseline Hold WNS: [format %.2f $baseline_hold_wns] ps"
  puts "  Final    Hold WNS: [format %.2f $final_hold_wns] ps"
  puts "  Hold WNS delta: [format %+.2f $hold_delta] ps (positive=improved)"
  puts "=========================================="
}

# ===============================================================
# ORCHESTRATOR: 2-Step Buffer Insertion (V25)
# ===============================================================

proc run_buffer_insertion {} {
  global env

  puts "\n######################################################"
  puts "# BUFFER INSERTION V25: 2-Step + Multi-Buffer        #"
  puts "#   Step 1: Leaf-level (bulk, fewer buffers)          #"
  puts "#   Step 2: Per-FF (fine-tuning, LP-based TNS)        #"
  puts "######################################################"

  set max_total_buffers [expr {[info exists env(USEFUL_SKEW_MAX_BUFFERS)] ? $env(USEFUL_SKEW_MAX_BUFFERS) : 200}]

  # Record global baseline
  set global_baseline_tns [get_current_tns]
  set global_baseline_hold_wns [get_current_hold_wns]
  set global_baseline_hold_tns [get_current_hold_tns]

  puts "\nGlobal Baseline:"
  puts "  Setup TNS: [format %.2f $global_baseline_tns] ps"
  puts "  Hold  WNS: [format %.2f $global_baseline_hold_wns] ps"
  puts "  Total buffer budget: $max_total_buffers"

  # ===== Step 1: Leaf-level insertion =====
  set step1_bufs [run_leaf_level_insertion]

  # Re-write verilog after Step 1 (so Step 2 extraction sees new buffers)
  set results_dir $env(CTS3D_WORK_DIR)
  puts "\n>>> Re-writing verilog after Step 1..."
  write_verilog $results_dir/4_cts.v

  # ===== Step 2: Per-FF insertion =====
  set remaining_budget [expr {$max_total_buffers - $step1_bufs}]
  if {$remaining_budget <= 0} {
    puts "\n>>> Budget fully used in Step 1. Skipping Step 2."
    set remaining_budget 0
  }
  run_per_ff_insertion $remaining_budget

  # ===== Global Summary =====
  set final_tns [get_current_tns]
  set final_hold_wns [get_current_hold_wns]
  set final_hold_tns [get_current_hold_tns]
  set total_setup_improve [expr {$global_baseline_tns - $final_tns}]
  set total_hold_delta [expr {$final_hold_wns - $global_baseline_hold_wns}]

  puts "\n######################################################"
  puts "# BUFFER INSERTION COMPLETE                      #"
  puts "######################################################"
  puts "--- Setup Timing ---"
  puts "  Global Baseline TNS: [format %.2f $global_baseline_tns] ps"
  puts "  Final          TNS: [format %.2f $final_tns] ps"
  puts "  TOTAL Improvement:  [format %.2f $total_setup_improve] ps"
  puts "--- Hold Timing ---"
  puts "  Global Baseline Hold WNS: [format %.2f $global_baseline_hold_wns] ps"
  puts "  Final          Hold WNS: [format %.2f $final_hold_wns] ps"
  puts "  Hold WNS delta: [format %+.2f $total_hold_delta] ps (positive=improved)"
  puts "######################################################"
}

# ===============================================================
# ENTRY POINT
# ===============================================================
if {[info exists env(ENABLE_BUFFER_INSERTION)] && $env(ENABLE_BUFFER_INSERTION)} {
  run_buffer_insertion
} else {
  puts "Buffer insertion disabled (set ENABLE_BUFFER_INSERTION=1 to enable)"
}
