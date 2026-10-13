# buffer_sizing_iterative.tcl
# Iterative net-benefit buffer sizing with STA re-validation
#
# Strategy:
#   1. Extract timing edges (setup + hold) and buffer info
#   2. Python computes per-buffer net-benefit (setup + hold combined)
#   3. Apply sizing one at a time, highest net-benefit first
#   4. STA re-validation after each change (accept/rollback)
#   5. Periodically re-extract + re-score for fresh timing data
#   6. Converge when max consecutive rejects reached
#
# This sources buffer_sizing.tcl for shared extraction procs.

namespace eval buffer_sizing_iter {
    variable script_dir [file dirname [info script]]
}

# =========================================
# Measure per-master buffer delays via Liberty.
# Reads available_buffers CSV (buf_cell column), queries Liberty for
# each unique master's intrinsic delay (buf driving own input cap).
# Writes CSV: buf_cell,delay_ns.
# =========================================
proc measure_buffer_delays {masters_csv output_csv} {
    set db [ord::get_db]
    set libs [$db getLibs]

    # Collect unique buffer masters from CSV
    set masters [list]
    if {[file exists $masters_csv]} {
        set fp [open $masters_csv r]
        gets $fp header
        while {[gets $fp line] >= 0} {
            set fields [split $line ","]
            if {[llength $fields] < 1} continue
            set cell [string trim [lindex $fields 0]]
            if {$cell ne "" && [lsearch -exact $masters $cell] < 0} {
                lappend masters $cell
            }
        }
        close $fp
    }

    if {[llength $masters] == 0} {
        puts "  WARNING: No buffer masters found for delay measurement"
        return
    }

    set fp [open $output_csv w]
    puts $fp "buf_cell,delay_ns"
    set count 0

    foreach master_name $masters {
        # Find Liberty cell
        set lib_cell ""
        foreach lib $libs {
            set cell [$lib findMaster $master_name]
            if {$cell ne "NULL"} {
                set lib_cell $cell
                break
            }
        }
        if {$lib_cell eq ""} continue

        # Find input and output pins
        set in_pin ""
        set out_pin ""
        foreach mterm [$lib_cell getMTerms] {
            set sig_type [$mterm getSigType]
            set io_type [$mterm getIoType]
            if {$sig_type eq "SIGNAL" || $sig_type eq "CLOCK"} {
                if {$io_type eq "INPUT"} {
                    set in_pin [$mterm getName]
                } elseif {$io_type eq "OUTPUT"} {
                    set out_pin [$mterm getName]
                }
            }
        }
        if {$in_pin eq "" || $out_pin eq ""} continue

        # Query Liberty for delay: input_pin -> output_pin
        # Use STA to get the cell's intrinsic delay
        set liberty_cell [get_lib_cells $master_name]
        if {$liberty_cell eq ""} continue

        # Get input cap (for self-loading model = cascaded scenario)
        set input_cap 0.0
        if {[catch {
            set input_cap [sta::get_property $liberty_cell "capacitance" ]
        }]} {
            # Try per-pin
            if {[catch {
                set lib_pin [get_lib_pins "${master_name}/${in_pin}"]
                if {$lib_pin ne ""} {
                    set input_cap [sta::get_property $lib_pin "capacitance"]
                }
            }]} {
                set input_cap 0.001  ;# fallback 1fF
            }
        }

        # Get cell delay at self-load (buf driving own input cap)
        set delay_ns 0.012  ;# fallback
        if {[catch {
            set lib_pin_out [get_lib_pins "${master_name}/${out_pin}"]
            if {$lib_pin_out ne ""} {
                # Use STA delay calculation for rise transition at given load
                set arcs [sta::get_timing_arcs_of_pin $lib_pin_out]
                if {[llength $arcs] > 0} {
                    set arc [lindex $arcs 0]
                    # Approximate: use NLDM table lookup at self-load cap
                    # sta::arc_delay returns delay for given slew + load
                    set delay_ns [sta::find_delays_from_lib $master_name $in_pin $out_pin $input_cap]
                }
            }
        }]} {
            # Fallback: use report_cell_delay if available
        }

        # Simpler approach: use report_checks through a temporary instance
        # Actually, the cleanest way is to use Liberty NLDM table directly
        # For now, use the analytical model but calibrated per-cell
        # by querying the Liberty cell's max_capacitance and input_cap
        if {[catch {
            set lib_pin_in [get_lib_pins "${master_name}/${in_pin}"]
            set lib_pin_out [get_lib_pins "${master_name}/${out_pin}"]
            if {$lib_pin_in ne "" && $lib_pin_out ne ""} {
                set in_cap [sta::get_property $lib_pin_in "capacitance"]
                # Get delay at load = in_cap (self-loading for cascaded)
                set delay_ns [sta::get_cell_delay $master_name $in_pin $out_pin "rise" $in_cap]
            }
        } err]} {
            # If STA API not available, skip — Python will use analytical fallback
        }

        puts $fp "${master_name},${delay_ns}"
        incr count
    }

    close $fp
    puts "  Measured buffer delays: $count masters -> $output_csv"
}

# =========================================
# Iterative net-benefit sizing main loop
# =========================================

# Complete rewrite - net-benefit + iterative STA
proc run_iterative_buffer_sizing {tier_filter max_iterations} {
    global env

    puts "\n=========================================="
    puts "ITERATIVE BUFFER SIZING (V18: Net-Benefit + STA)"
    puts "=========================================="
    puts "Tier filter: $tier_filter"
    puts "Max iterations: $max_iterations"

    set script_dir $env(SCRIPTS_3DCTS_DIR)
    set results_dir $env(CTS3D_WORK_DIR)

    # Source shared extraction procs from buffer_sizing.tcl
    source $script_dir/buffer_sizing.tcl

    # Parameters
    set slack_threshold [expr {[info exists env(SIZING_SLACK_THRESHOLD)] ? $env(SIZING_SLACK_THRESHOLD) : -100.0}]
    set hold_threshold [expr {[info exists env(SIZING_HOLD_THRESHOLD)] ? $env(SIZING_HOLD_THRESHOLD) : 0.0}]
    set hold_factor [expr {[info exists env(HOLD_WEIGHT)] ? $env(HOLD_WEIGHT) : 1.0}]
    set setup_tol [expr {[info exists env(SETUP_TOLERANCE)] ? $env(SETUP_TOLERANCE) : 5.0}]
    set refresh_interval [expr {[info exists env(SIZING_REFRESH_INTERVAL)] ? $env(SIZING_REFRESH_INTERVAL) : 10}]
    set max_consec_rejects [expr {[info exists env(MAX_CONSEC_REJECTS)] ? $env(MAX_CONSEC_REJECTS) : 20}]
    # V23c: LP constraint margins (ps)
    set lp_setup_margin [expr {[info exists env(LP_SETUP_MARGIN)] ? $env(LP_SETUP_MARGIN) : 0.0}]
    set lp_hold_margin [expr {[info exists env(LP_HOLD_MARGIN)] ? $env(LP_HOLD_MARGIN) : 0.0}]
    # V24a: Skip hold guard (accept changes even if hold worsens)
    set skip_hold_guard [expr {[info exists env(SKIP_HOLD_GUARD)] && $env(SKIP_HOLD_GUARD)}]
    set reg_weight [expr {[info exists env(BUF_SIZING_REG_WEIGHT)] ? $env(BUF_SIZING_REG_WEIGHT) : 0.01}]

    puts "Parameters:"
    puts "  slack_threshold:     ${slack_threshold}ps"
    puts "  hold_threshold:      ${hold_threshold}ps"
    puts "  hold_factor:         $hold_factor"
    puts "  setup_tol:           ${setup_tol}ps"
    if {$skip_hold_guard} {
      puts "  hold_guard:          DISABLED (V24a)"
    } else {
      puts "  hold_guard:          strict (no degradation allowed)"
    }
    puts "  refresh_interval:    $refresh_interval changes"
    puts "  max_consec_rejects:  $max_consec_rejects"
    puts "  lp_setup_margin:    ${lp_setup_margin}ps"
    puts "  lp_hold_margin:     ${lp_hold_margin}ps"

    set db [ord::get_db]
    set block [[$db getChip] getBlock]

    # CSV file paths
    set timing_csv "$results_dir/timing_edges_iter.csv"
    set sizing_csv "$results_dir/buffer_sizing_iter_result.csv"
    puts "  Using LP-based Pareto sizing"

    # Baseline timing
    set baseline_tns [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
    set baseline_hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]
    set baseline_hold_tns [expr {abs([sta::total_negative_slack_cmd "min"]) * 1e12}]
    set hold_tns_tolerance [expr {[info exists env(HOLD_TNS_TOLERANCE)] ? $env(HOLD_TNS_TOLERANCE) : 50.0}]
    puts "\nBaseline:"
    puts "  Setup TNS: [format %.2f $baseline_tns] ps"
    puts "  Hold  WNS: [format %.2f $baseline_hold_wns] ps"
    puts "  Hold  TNS: [format %.2f $baseline_hold_tns] ps (tolerance: ${hold_tns_tolerance}ps)"

    set prev_tns $baseline_tns
    set prev_hold_wns $baseline_hold_wns
    set total_accepted 0
    set total_rejected 0
    set total_errors 0
    set consec_rejects 0
    set needs_rescore 1
    set change_queue [list]
    set change_idx 0

    for {set iter 0} {$iter < $max_iterations} {incr iter} {

        # Re-score if needed (first time, or after refresh_interval accepted changes)
        if {$needs_rescore || $change_idx >= [llength $change_queue]} {
            puts "\n>>> Scoring round (iter $iter, accepted so far: $total_accepted)..."

            # Skew-aware buffer sizing LP, solved in C++: the solver extracts the
            # clock buffers, measures each master's Liberty delay, reads the timing
            # edges, and solves the LP in one call, with no CSV round-trip.
            set skew_csv ""
            if {[info exists env(POST_CTS_SKEW_TARGETS)] && [file exists $env(POST_CTS_SKEW_TARGETS)]} {
                set skew_csv $env(POST_CTS_SKEW_TARGETS)
                set skew_wt [expr {[info exists env(POST_CTS_SKEW_WEIGHT)] ? $env(POST_CTS_SKEW_WEIGHT) : 0.5}]
                puts "  BufSizing: Post-CTS LP skew targets enabled (weight=$skew_wt)"
            } elseif {[info exists env(CTS_SKEW_TARGETS_CSV)] && [file exists $env(CTS_SKEW_TARGETS_CSV)]} {
                # Fallback to pre-CTS LP targets when post-CTS LP was not run
                # (ENABLE_POST_CTS_LP=0): pre-CTS targets still guide buffer sizing
                set skew_csv $env(CTS_SKEW_TARGETS_CSV)
                set skew_wt [expr {[info exists env(POST_CTS_SKEW_WEIGHT)] ? $env(POST_CTS_SKEW_WEIGHT) : 0.5}]
                puts "  BufSizing: Pre-CTS LP skew targets (fallback, weight=$skew_wt)"
            } else {
                set skew_wt 0.5
            }

            # Step 1: Tcl extracts timing edges to CSV (STA query in Tcl, proven)
            extract_timing_edges_simple $timing_csv 5000

            puts ">>> C++ Buffer Sizing LP (Liberty delays, OR-Tools GLOP)..."
            if {[catch {
                dcts::solve_buffer_sizing_lp $timing_csv $sizing_csv $skew_csv \
                    $hold_factor $reg_weight $skew_wt \
                    $lp_setup_margin $lp_hold_margin
            } err]} {
                # No fallback: the sizing LP is solved in C++ (OR-Tools GLOP).
                # A failure here leaves the constructed tree unsized rather than
                # aborting the flow; the sizing CSV is then absent and the change
                # queue below stays empty.
                puts "WARNING: buffer sizing LP failed, skipping sizing: $err"
            }

            # Step 4: Parse sizing results into queue
            set change_queue [list]
            set change_idx 0

            if {[file exists $sizing_csv]} {
                set fp [open $sizing_csv r]
                gets $fp header
                while {[gets $fp line] >= 0} {
                    set fields [split $line ","]
                    if {[llength $fields] < 4} continue

                    set inst_name [lindex $fields 0]
                    set old_cell [lindex $fields 1]
                    set new_cell [lindex $fields 2]
                    set direction [lindex $fields 3]

                    # Apply tier filter
                    if {$tier_filter eq "bottom" && ![string match "*_bottom" $old_cell]} continue
                    if {$tier_filter eq "upper" && ![string match "*_upper" $old_cell]} continue

                    lappend change_queue [list $inst_name $old_cell $new_cell $direction]
                }
                close $fp
            }

            puts "  Queued [llength $change_queue] sizing changes"
            set needs_rescore 0

            if {[llength $change_queue] == 0} {
                puts "  No changes to apply. Stopping."
                break
            }
        }

        # No more changes in queue
        if {$change_idx >= [llength $change_queue]} {
            puts "\n  Queue exhausted. Stopping."
            break
        }

        # Get next change from queue
        set change [lindex $change_queue $change_idx]
        incr change_idx

        set inst_name [lindex $change 0]
        set old_cell [lindex $change 1]
        set new_cell [lindex $change 2]
        set direction [lindex $change 3]

        # Find instance
        set inst [$block findInst $inst_name]
        if {$inst eq "NULL"} {
            incr total_errors
            continue
        }

        # Find new master
        set new_master [$db findMaster $new_cell]
        if {$new_master eq "NULL" || $new_master eq ""} {
            incr total_errors
            continue
        }

        # Verify current cell matches expected (timing may have changed)
        set current_master [$inst getMaster]
        set current_cell [$current_master getName]
        if {$current_cell ne $old_cell} {
            # Already changed by a previous iteration, skip
            continue
        }

        # Apply sizing change. Try swapMaster first (same-family, matching pins).
        # Cross-family swaps (BUF_X4_upper→BUFx2_ASAP7) fail due to pin mismatch (Z≠Y).
        # Fallback: manual destroy+create with IO-type-based reconnection.
        # Safe because estimate_parasitics (below) rebuilds STA after ODB change.
        # Rollback path (reject branch) uses the same destroy+create pattern.
        set swap_ok 0
        if {[catch {set swap_ok [$inst swapMaster $new_master]} swap_err]} {
            set swap_ok 0
        }
        if {$swap_ok} {
            # Same-family swap succeeded — proceed to STA check below
        } else {
            # [FIX-B ] swapMaster failed = cross-family pin mismatch
            # (heterogeneous ASAP7<->NG45, ODB-0046 Z!=Y). The destroy+create
            # fallback below corrupts OpenSTA's incremental timing graph: the
            # destroyed instance leaves dangling vertices that threaded STA
            # (DispatchQueue -> setVertexArrivals) dereferences -> non-deterministic
            # SIGSEGV (observed swerv ng45 nid0_tarp0; 3/4 combos passed by luck).
            # These cross-family swaps carry delta~0 (no TNS benefit), so skip them
            # by default. Reversible: BUFSIZING_REMAP_CROSSFAMILY=1 restores the old
            # (unsafe) destroy+create remap path.
            if {![info exists ::env(BUFSIZING_REMAP_CROSSFAMILY)]
                || $::env(BUFSIZING_REMAP_CROSSFAMILY) eq "0"} {
                incr total_skipped_crossfamily
                continue
            }
            # Cross-family pin mismatch — manual destroy+create (pin-remap). [opt-in]
            # Build pin->net map from old instance (by IO type, not pin name)
            set input_net "NULL"
            set output_net "NULL"
            set power_nets [dict create]
            foreach iterm [$inst getITerms] {
                set mterm [$iterm getMTerm]
                set net [$iterm getNet]
                if {$net eq "NULL"} continue
                set io_type [$mterm getIoType]
                set sig_type [$mterm getSigType]
                if {$io_type eq "INPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                    set input_net $net
                } elseif {$io_type eq "OUTPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                    set output_net $net
                } else {
                    dict set power_nets $sig_type $net
                }
            }
            # Save placement
            set x [lindex [$inst getOrigin] 0]
            set y [lindex [$inst getOrigin] 1]
            set orient [$inst getOrient]
            set status [$inst getPlacementStatus]
            # Destroy old instance
            odb::dbInst_destroy $inst
            # Create new instance with same name but new master
            set new_inst [odb::dbInst_create $block $new_master $inst_name]
            if {$new_inst eq "NULL"} {
                puts "  ERROR: pin-remap failed to create replacement $inst_name"
                incr total_errors
                continue
            }
            $new_inst setOrigin $x $y
            $new_inst setOrient $orient
            $new_inst setPlacementStatus $status
            # Reconnect by IO type (handles Z->Y pin name change)
            foreach iterm [$new_inst getITerms] {
                set mterm [$iterm getMTerm]
                set io_type [$mterm getIoType]
                set sig_type [$mterm getSigType]
                if {$io_type eq "INPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                    if {$input_net ne "NULL"} {
                        odb::dbITerm_connect $iterm $input_net
                    }
                } elseif {$io_type eq "OUTPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                    if {$output_net ne "NULL"} {
                        odb::dbITerm_connect $iterm $output_net
                    }
                } else {
                    if {[dict exists $power_nets $sig_type]} {
                        odb::dbITerm_connect $iterm [dict get $power_nets $sig_type]
                    }
                }
            }
            set inst $new_inst
        }

        # STA update
        estimate_parasitics -placement

        # Check improvement
        set new_tns [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
        set new_hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]
        set setup_delta [expr {$prev_tns - $new_tns}]

        set accept 1
        set reason ""

        # Hold guards (skipped when SKIP_HOLD_GUARD=1, V24a)
        if {!$skip_hold_guard} {
            # Hold guard: reject if hold WNS worse than baseline (strict, no tolerance)
            if {$new_hold_wns < $baseline_hold_wns} {
                set accept 0
                set reason "hold (WNS=[format %.1f $new_hold_wns]ps < baseline=[format %.1f $baseline_hold_wns]ps)"
            }

            # Hold guard: reject if hold WNS worse than previous accepted iteration
            if {$accept && $new_hold_wns < $prev_hold_wns} {
                set accept 0
                set reason "hold jump (WNS=[format %.1f $new_hold_wns]ps < prev=[format %.1f $prev_hold_wns]ps)"
            }

            # V23: Hold TNS guard — reject if hold TNS worsens beyond tolerance
            if {$accept} {
                set new_hold_tns [expr {abs([sta::total_negative_slack_cmd "min"]) * 1e12}]
                if {$new_hold_tns > [expr {$baseline_hold_tns + $hold_tns_tolerance}]} {
                    set accept 0
                    set reason "hold TNS ([format %.1f $new_hold_tns]ps > baseline+tol=[format %.1f [expr {$baseline_hold_tns + $hold_tns_tolerance}]]ps)"
                }
            }
        }

        # Setup guard: reject if setup worsens beyond tolerance
        if {$accept && $setup_delta < -$setup_tol} {
            set accept 0
            set reason "setup worsened [format %.1f [expr {-$setup_delta}]]ps"
        }

        if {$accept} {
            set prev_tns $new_tns
            set prev_hold_wns $new_hold_wns
            incr total_accepted
            set consec_rejects 0
            puts "  [format %3d $iter] ACCEPT $inst_name ($direction) | TNS=[format %.1f $new_tns] delta=[format %+.1f [expr {-$setup_delta}]] hold=[format %.1f $new_hold_wns]ps"

            # Trigger rescore after refresh_interval accepted changes
            if {[expr {$total_accepted % $refresh_interval}] == 0} {
                puts "  >>> Refresh: $total_accepted changes accepted, re-scoring..."
                set needs_rescore 1
            }
        } else {
            # Rollback: restore to original cell.
            # Try swapMaster first; if pin mismatch, do manual replace back.
            set old_master_obj [$db findMaster $old_cell]
            set rollback_ok 0
            if {$old_master_obj ne "NULL" && $old_master_obj ne ""} {
                if {[catch {set rollback_ok [$inst swapMaster $old_master_obj]} rb_err]} {
                    set rollback_ok 0
                }
            }
            if {!$rollback_ok && $old_master_obj ne "NULL" && $old_master_obj ne ""} {
                # Manual rollback (pin name mismatch): same destroy+create pattern
                set rb_input_net "NULL"
                set rb_output_net "NULL"
                set rb_power_nets [dict create]
                foreach iterm [$inst getITerms] {
                    set mterm [$iterm getMTerm]
                    set net [$iterm getNet]
                    if {$net eq "NULL"} continue
                    set io_type [$mterm getIoType]
                    set sig_type [$mterm getSigType]
                    if {$io_type eq "INPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                        set rb_input_net $net
                    } elseif {$io_type eq "OUTPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                        set rb_output_net $net
                    } else {
                        dict set rb_power_nets $sig_type $net
                    }
                }
                set rb_x [lindex [$inst getOrigin] 0]
                set rb_y [lindex [$inst getOrigin] 1]
                set rb_orient [$inst getOrient]
                set rb_status [$inst getPlacementStatus]
                odb::dbInst_destroy $inst
                set inst [odb::dbInst_create $block $old_master_obj $inst_name]
                if {$inst ne "NULL"} {
                    $inst setOrigin $rb_x $rb_y
                    $inst setOrient $rb_orient
                    $inst setPlacementStatus $rb_status
                    foreach iterm [$inst getITerms] {
                        set mterm [$iterm getMTerm]
                        set io_type [$mterm getIoType]
                        set sig_type [$mterm getSigType]
                        if {$io_type eq "INPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                            if {$rb_input_net ne "NULL"} { odb::dbITerm_connect $iterm $rb_input_net }
                        } elseif {$io_type eq "OUTPUT" && ($sig_type eq "SIGNAL" || $sig_type eq "CLOCK")} {
                            if {$rb_output_net ne "NULL"} { odb::dbITerm_connect $iterm $rb_output_net }
                        } else {
                            if {[dict exists $rb_power_nets $sig_type]} {
                                odb::dbITerm_connect $iterm [dict get $rb_power_nets $sig_type]
                            }
                        }
                    }
                }
            }
            estimate_parasitics -placement
            incr total_rejected
            incr consec_rejects
            puts "  [format %3d $iter] REJECT $inst_name ($direction) | $reason"
        }

        # Convergence check
        if {$consec_rejects >= $max_consec_rejects} {
            puts "\n  CONVERGED: $max_consec_rejects consecutive rejections."
            break
        }
    }

    # Final summary
    set final_tns [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
    set final_hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]
    set total_improve [expr {$baseline_tns - $final_tns}]

    set final_hold_tns [expr {abs([sta::total_negative_slack_cmd "min"]) * 1e12}]

    puts "\n=========================================="
    puts "ITERATIVE BUFFER SIZING COMPLETE (LP Pareto sizing)"
    puts "=========================================="
    puts "  Total iterations: [expr {min($iter + 1, $max_iterations)}]"
    puts "  Accepted: $total_accepted"
    puts "  Rejected: $total_rejected"
    puts "  Errors:   $total_errors"
    puts "--- Setup Timing ---"
    puts "  Baseline TNS: [format %.2f $baseline_tns] ps"
    puts "  Final    TNS: [format %.2f $final_tns] ps"
    puts "  Improvement:  [format %.2f $total_improve] ps"
    set hold_delta [expr {$final_hold_wns - $baseline_hold_wns}]
    set hold_tns_delta [expr {$final_hold_tns - $baseline_hold_tns}]
    puts "--- Hold Timing ---"
    puts "  Baseline Hold WNS: [format %.2f $baseline_hold_wns] ps"
    puts "  Final    Hold WNS: [format %.2f $final_hold_wns] ps"
    puts "  Hold WNS delta: [format %+.2f $hold_delta] ps (positive=improved)"
    puts "  Baseline Hold TNS: [format %.2f $baseline_hold_tns] ps"
    puts "  Final    Hold TNS: [format %.2f $final_hold_tns] ps"
    puts "  Hold TNS delta: [format %+.2f $hold_tns_delta] ps (positive=worsened)"
    puts "=========================================="
}

# Main entry point (called from cts_3d.tcl)
proc run_buffer_sizing_iterative {tier_filter} {
    set max_iterations [expr {[info exists ::env(SIZING_MAX_ITERS)] ? $::env(SIZING_MAX_ITERS) : 100}]
    run_iterative_buffer_sizing $tier_filter $max_iterations
}
