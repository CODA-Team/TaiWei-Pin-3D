# cts_debug_extract.tcl
# CTS Debug Extraction Utility (V3: unified)
#
# Extracts 5 CSV files for CTS analysis:
#   1. cts_debug_per_ff.csv       - per-FF clock latency, slack, position, LP target
#   2. cts_debug_clock_paths.csv  - per-FF clock path buf/wire decomposition (hop-by-hop)
#   3. cts_debug_per_edge.csv     - per-edge LP skew vs actual skew comparison
#   4. cts_debug_buffers.csv      - clock buffer inventory (fanout, position, avg LP target)
#   5. cts_debug_summary.csv      - aggregate metrics
#
# Works for H-tree (V40/V41, Pin3D) and SGCTS (V42/V42a) modes.
# Compatible with: cts_debug_report.py, cts_debug_analyze.py, cts_debug_compare.py
# Usage: source cts_debug_extract.tcl ; run_cts_debug_extract [lp_csv] [graph_csv]

# =========================================
# Helper: Read LP targets CSV -> dict
# =========================================
proc cts_debug_read_lp_targets {csv_path} {
    set result [dict create]
    if {![file exists $csv_path]} {
        puts "  NOTE: LP targets not found: $csv_path (Pin3D mode: all targets = 0)"
        return $result
    }
    set fp [open $csv_path r]
    gets $fp ;# skip header
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} continue
        set fields [split $line ","]
        if {[llength $fields] >= 2} {
            dict set result [lindex $fields 0] [lindex $fields 1]
        }
    }
    close $fp
    return $result
}

# =========================================
# Proc 1: Per-FF Clock Latency + LP Target
# =========================================
# Two passes: setup (capture clock latency) + hold (hold slack)
# Includes LP target and ODB position for spatial analysis
proc extract_ff_clock_latency {output_csv lp_targets {num_paths 5000}} {
    puts "\n========== CTS Debug: Per-FF Clock Latency =========="

    set db [ord::get_db]
    set block [[$db getChip] getBlock]

    array set ff_clk_latency {}
    array set ff_setup_slack {}
    array set ff_hold_slack {}
    array set ff_seen {}

    # Pass 1: Setup paths
    puts "  Pass 1: $num_paths worst setup paths..."
    if {[catch {
        set path_ends [find_timing_paths -sort_by_slack -path_delay max \
                        -group_path_count $num_paths]
        foreach path_end $path_ends {
            set slack_ps [expr {[$path_end slack] * 1e12}]
            set end_pin_name [get_full_name [$path_end pin]]
            set capture_ff [regsub {/[^/]+$} $end_pin_name ""]
            set clk_latency_ps [expr {[$path_end target_clk_delay] * 1e12}]

            set ff_seen($capture_ff) 1
            if {![info exists ff_setup_slack($capture_ff)] || $slack_ps < $ff_setup_slack($capture_ff)} {
                set ff_setup_slack($capture_ff) $slack_ps
            }
            if {![info exists ff_clk_latency($capture_ff)]} {
                set ff_clk_latency($capture_ff) $clk_latency_ps
            }

            # Also record launch FF
            set all_pins [[$path_end path] pins]
            if {[llength $all_pins] > 0} {
                set start_pin_name [get_full_name [lindex $all_pins end]]
                set launch_ff [regsub {/[^/]+$} $start_pin_name ""]
                set launch_clk_ps [expr {[$path_end source_clk_latency] * 1e12}]
                set ff_seen($launch_ff) 1
                if {![info exists ff_clk_latency($launch_ff)]} {
                    set ff_clk_latency($launch_ff) $launch_clk_ps
                }
            }
        }
    } err]} {
        puts "  WARNING: Setup extraction error: $err"
    }
    puts "  Pass 1: [array size ff_seen] FFs"

    # Pass 2: Hold paths
    puts "  Pass 2: $num_paths worst hold paths..."
    if {[catch {
        set hold_path_ends [find_timing_paths -sort_by_slack -path_delay min \
                             -group_path_count $num_paths]
        foreach path_end $hold_path_ends {
            set slack_ps [expr {[$path_end slack] * 1e12}]
            set end_pin_name [get_full_name [$path_end pin]]
            set capture_ff [regsub {/[^/]+$} $end_pin_name ""]
            set ff_seen($capture_ff) 1
            if {![info exists ff_hold_slack($capture_ff)] || $slack_ps < $ff_hold_slack($capture_ff)} {
                set ff_hold_slack($capture_ff) $slack_ps
            }
            if {![info exists ff_clk_latency($capture_ff)]} {
                set ff_clk_latency($capture_ff) [expr {[$path_end target_clk_delay] * 1e12}]
            }
        }
    } err]} {
        puts "  WARNING: Hold extraction error: $err"
    }
    puts "  Pass 2: [array size ff_seen] FFs total"

    # Compute mean clock latency for delta calculation
    set sum 0.0
    set cnt 0
    foreach ff [array names ff_clk_latency] {
        set sum [expr {$sum + $ff_clk_latency($ff)}]
        incr cnt
    }
    set mean_clk [expr {$cnt > 0 ? $sum / $cnt : 0.0}]
    puts "  Mean clock latency: [format %.2f $mean_clk] ps"

    # Write CSV
    set fp [open $output_csv w]
    puts $fp "ff_name,tier,lp_target_ps,clk_latency_ps,clk_delta_ps,setup_slack_ps,hold_slack_ps,x_um,y_um,cell_master"

    set ff_count 0
    foreach ff_name [lsort [array names ff_seen]] {
        set clk_lat [expr {[info exists ff_clk_latency($ff_name)] ? $ff_clk_latency($ff_name) : 0.0}]
        set delta [expr {$clk_lat - $mean_clk}]
        set setup_s [expr {[info exists ff_setup_slack($ff_name)] ? $ff_setup_slack($ff_name) : 999.0}]
        set hold_s [expr {[info exists ff_hold_slack($ff_name)] ? $ff_hold_slack($ff_name) : 999.0}]

        # LP target (0.0 if not in LP targets, e.g., Pin3D)
        set lp_ps 0.0
        if {[dict exists $lp_targets $ff_name]} {
            set lp_ps [expr {[dict get $lp_targets $ff_name] * 1000.0}]
        }

        # ODB position and tier
        set inst [$block findInst $ff_name]
        set x_um 0.0
        set y_um 0.0
        set tier "unknown"
        set cell_master "unknown"

        if {$inst ne "NULL" && $inst ne ""} {
            set loc [$inst getLocation]
            set dbu_per_um [$block getDbUnitsPerMicron]
            set x_um [expr {[lindex $loc 0] / double($dbu_per_um)}]
            set y_um [expr {[lindex $loc 1] / double($dbu_per_um)}]
            set master [$inst getMaster]
            set cell_master [$master getName]
            if {[string match "*_upper" $cell_master]} {
                set tier "upper"
            } elseif {[string match "*_bottom" $cell_master]} {
                set tier "bottom"
            }
        }

        puts $fp "$ff_name,$tier,[format %.3f $lp_ps],[format %.3f $clk_lat],[format %.3f $delta],[format %.3f $setup_s],[format %.3f $hold_s],[format %.3f $x_um],[format %.3f $y_um],$cell_master"
        incr ff_count
    }

    close $fp
    puts "  Written $ff_count FFs to $output_csv"
    return $ff_count
}

# =========================================
# Proc 2: Clock Path Decomposition (ODB + STA)
# =========================================
# Traces clock path backward from FF CLK pin via ODB, queries STA arrival per hop.
# Output: hop-by-hop arrival time + incremental delay (buf intrinsic + wire).
proc extract_clock_path_via_sta {output_csv {num_paths 5000}} {
    puts "\n========== CTS Debug: Clock Path Decomposition =========="

    set db [ord::get_db]
    set block [[$db getChip] getBlock]
    array set ff_done {}

    set fp [open $output_csv w]
    puts $fp "ff_name,hop_idx,pin_name,arrival_ps,incr_delay_ps,cell_or_net,pin_type"

    set ff_count 0
    set total_hops 0

    puts "  Tracing clock paths from $num_paths worst setup paths..."
    if {[catch {
        set path_ends [find_timing_paths -sort_by_slack -path_delay max \
                        -group_path_count $num_paths]

        foreach path_end $path_ends {
            set end_pin_name [get_full_name [$path_end pin]]
            set capture_ff [regsub {/[^/]+$} $end_pin_name ""]
            if {[info exists ff_done($capture_ff)]} continue

            set inst [$block findInst $capture_ff]
            if {$inst eq "NULL" || $inst eq ""} continue

            # Find CLK pin
            set clk_iterm ""
            foreach iterm [$inst getITerms] {
                set mterm [$iterm getMTerm]
                set pname [$mterm getName]
                if {$pname eq "CLK" || $pname eq "CK" || [string match "*CLK*" $pname]} {
                    set clk_iterm $iterm
                    break
                }
            }
            if {$clk_iterm eq ""} continue

            # Trace backward through clock network
            set path_pins {}
            set current_iterm $clk_iterm
            set depth 0

            while {$depth < 20} {
                set net [$current_iterm getNet]
                if {$net eq "NULL" || $net eq ""} break

                # Find driver
                set driver_iterm ""
                foreach candidate [$net getITerms] {
                    set mt [$candidate getMTerm]
                    if {[$mt getIoType] eq "OUTPUT"} {
                        set driver_iterm $candidate
                        break
                    }
                }

                if {$driver_iterm eq ""} {
                    # Reached clock port
                    lappend path_pins [list "CLK_PORT" [$net getName] "port" ""]
                    break
                }

                set driver_inst [$driver_iterm getInst]
                set driver_name [$driver_inst getName]
                set driver_master [[$driver_inst getMaster] getName]
                lappend path_pins [list $driver_name [$net getName] "buf" $driver_master]

                # Find input pin to continue
                set found_input 0
                foreach inp_iterm [$driver_inst getITerms] {
                    set inp_mt [$inp_iterm getMTerm]
                    if {[$inp_mt getIoType] eq "INPUT"} {
                        set current_iterm $inp_iterm
                        set found_input 1
                        break
                    }
                }
                if {!$found_input} break
                incr depth
            }

            # Reverse: root to FF order
            set path_pins [lreverse $path_pins]

            # Query STA arrival times at each hop
            set hop_idx 0
            set prev_arrival 0.0

            foreach pin_info $path_pins {
                set inst_name [lindex $pin_info 0]
                set net_name [lindex $pin_info 1]
                set ptype [lindex $pin_info 2]
                set master_name [lindex $pin_info 3]

                set arrival_ps 0.0
                if {$ptype eq "port"} {
                    set arrival_ps 0.0
                    set cell_or_net "port:$net_name"
                } else {
                    # Get arrival at buffer output pin
                    set sta_inst [$block findInst $inst_name]
                    if {$sta_inst ne "NULL" && $sta_inst ne ""} {
                        foreach ot [$sta_inst getITerms] {
                            set ot_mt [$ot getMTerm]
                            if {[$ot_mt getIoType] eq "OUTPUT"} {
                                set ot_pin_name "${inst_name}/[$ot_mt getName]"
                                if {[catch {
                                    set sta_pin [get_pins $ot_pin_name]
                                    if {$sta_pin ne ""} {
                                        set arr_val [get_property $sta_pin max_rise_arrival]
                                        if {$arr_val ne "" && $arr_val ne "NONE"} {
                                            set arrival_ps [expr {$arr_val * 1e12}]
                                        }
                                    }
                                } sta_err]} {
                                    set arrival_ps [expr {$hop_idx * 15.0}]
                                }
                                break
                            }
                        }
                    }
                    set cell_or_net "$master_name"
                }

                set incr_delay [expr {$arrival_ps - $prev_arrival}]
                puts $fp "$capture_ff,$hop_idx,$inst_name,[format %.3f $arrival_ps],[format %.3f $incr_delay],$cell_or_net,$ptype"
                incr total_hops
                set prev_arrival $arrival_ps
                incr hop_idx
            }

            # Final hop: last buffer → FF CLK pin
            set ff_clk_arrival 0.0
            if {[catch {
                set ff_pin_name "${capture_ff}/CLK"
                set sta_pin [get_pins $ff_pin_name]
                if {$sta_pin eq "" || $sta_pin eq "NONE"} {
                    set ff_pin_name "${capture_ff}/CK"
                    set sta_pin [get_pins $ff_pin_name]
                }
                if {$sta_pin ne "" && $sta_pin ne "NONE"} {
                    set arr_val [get_property $sta_pin max_rise_arrival]
                    if {$arr_val ne "" && $arr_val ne "NONE"} {
                        set ff_clk_arrival [expr {$arr_val * 1e12}]
                    }
                }
            } sta_err]} {}

            set final_incr [expr {$ff_clk_arrival - $prev_arrival}]
            puts $fp "$capture_ff,$hop_idx,${capture_ff}/CLK,[format %.3f $ff_clk_arrival],[format %.3f $final_incr],wire_to_ff,sink"
            incr total_hops

            set ff_done($capture_ff) 1
            incr ff_count
        }
    } err]} {
        puts "  WARNING: Clock path extraction error: $err"
    }

    close $fp
    puts "  Extracted $ff_count FFs ($total_hops hops) -> $output_csv"
    return $ff_count
}

# =========================================
# Proc 3: Per-Edge LP Skew vs Actual Skew
# =========================================
# Reads FF→FF timing graph, computes LP target skew vs actual clock skew per edge.
# Key output: gap = LP_skew - actual_skew (positive = LP over-estimates useful skew)
proc extract_per_edge {ff_latency_csv graph_csv lp_targets output_csv} {
    puts "\n========== CTS Debug: Per-Edge Skew Analysis =========="

    if {![file exists $graph_csv]} {
        puts "  WARNING: Timing graph not found: $graph_csv (skipping per-edge)"
        return 0
    }

    # Build clock latency lookup from per_ff CSV
    # Column order: ff_name(0),tier(1),lp_target_ps(2),clk_latency_ps(3),
    #               clk_delta_ps(4),setup_slack_ps(5),hold_slack_ps(6),...
    array set clk_map {}
    array set setup_map {}
    set fp_lat [open $ff_latency_csv r]
    gets $fp_lat ;# header
    while {[gets $fp_lat line] >= 0} {
        set f [split $line ","]
        if {[llength $f] < 7} continue
        set ff [lindex $f 0]
        set clk_map($ff) [lindex $f 3]
        set setup_map($ff) [lindex $f 5]
    }
    close $fp_lat
    puts "  Loaded [array size clk_map] FFs from latency CSV"

    # Read timing graph and compute per-edge skew comparison
    set fp_in [open $graph_csv r]
    gets $fp_in ;# header
    set fp_out [open $output_csv w]
    puts $fp_out "from_ff,to_ff,lp_skew_ps,actual_skew_ps,gap_ps,pre_setup_slack_ps,post_setup_slack_ps,improvement_ps"

    set count 0
    while {[gets $fp_in line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} continue
        set fields [split $line ","]
        if {[llength $fields] < 3} continue

        set from_ff [lindex $fields 0]
        set to_ff [lindex $fields 1]
        set pre_setup_ns [lindex $fields 2]

        # LP targets (ns -> ps)
        set a_from 0.0
        set a_to 0.0
        if {[dict exists $lp_targets $from_ff]} {
            set a_from [expr {[dict get $lp_targets $from_ff] * 1000.0}]
        }
        if {[dict exists $lp_targets $to_ff]} {
            set a_to [expr {[dict get $lp_targets $to_ff] * 1000.0}]
        }
        set lp_skew [expr {$a_to - $a_from}]

        # Actual clock latency
        if {![info exists clk_map($from_ff)] || ![info exists clk_map($to_ff)]} continue
        set actual_skew [expr {$clk_map($to_ff) - $clk_map($from_ff)}]
        set gap [expr {$lp_skew - $actual_skew}]

        # Pre-CTS setup slack (ns -> ps)
        set pre_setup_ps [expr {$pre_setup_ns * 1000.0}]

        # Post-CTS setup slack (from latency data)
        set post_setup "N/A"
        set improvement "N/A"
        if {[info exists setup_map($to_ff)]} {
            set post_setup $setup_map($to_ff)
            if {$post_setup ne "999.000"} {
                set improvement [format "%.2f" [expr {$post_setup - $pre_setup_ps}]]
            }
        }

        puts $fp_out [format "%s,%s,%.2f,%.2f,%.2f,%.2f,%s,%s" \
            $from_ff $to_ff $lp_skew $actual_skew $gap $pre_setup_ps $post_setup $improvement]
        incr count
    }

    close $fp_in
    close $fp_out
    puts "  Analyzed $count edges -> $output_csv"
    return $count
}

# =========================================
# Proc 4: Clock Buffer Inventory
# =========================================
# Scans all clock buffers: position, tier, fanout, driven FF avg LP target.
# Matches both H-tree (clkbuf_*) and SGCTS (sg_*) naming patterns.
proc extract_buffer_inventory {lp_targets output_csv} {
    puts "\n========== CTS Debug: Buffer Inventory =========="

    set db [ord::get_db]
    set block [[$db getChip] getBlock]
    set dbu_per_um [$block getDbUnitsPerMicron]

    set fp [open $output_csv w]
    puts $fp "buf_name,cell_name,x_um,y_um,tier,fanout,output_net,avg_driven_lp_target_ps"

    set count 0
    foreach inst [$block getInsts] {
        set inst_name [$inst getName]

        # Match clock buffer naming patterns (H-tree + SGCTS)
        set is_clk_buf 0
        if {[string match "clkbuf_*" $inst_name] ||
            [string match "sg_leaf_*" $inst_name] ||
            [string match "sg_trunk_*" $inst_name] ||
            [string match "sg_root*" $inst_name] ||
            [string match "sg_dly_*" $inst_name] ||
            [string match "*skew_buf*" $inst_name] ||
            [string match "*cts*" [string tolower $inst_name]]} {
            set is_clk_buf 1
        }
        if {!$is_clk_buf} continue

        set master [$inst getMaster]
        set cell_name [$master getName]

        # Position
        set loc [$inst getLocation]
        set x_um [format "%.3f" [expr {[lindex $loc 0] / double($dbu_per_um)}]]
        set y_um [format "%.3f" [expr {[lindex $loc 1] / double($dbu_per_um)}]]

        # Tier
        set tier "unknown"
        if {[string match "*_bottom*" $cell_name] || [string match "*_bottom" $inst_name]} {
            set tier "bottom"
        }
        if {[string match "*_upper*" $cell_name] || [string match "*_upper" $inst_name]} {
            set tier "upper"
        }

        # Output net, fanout, avg LP target of driven FFs
        set output_net ""
        set fanout 0
        set target_sum 0.0
        set target_count 0

        foreach iterm [$inst getITerms] {
            if {[$iterm getIoType] eq "OUTPUT"} {
                set onet [$iterm getNet]
                if {$onet ne "NULL" && $onet ne ""} {
                    set output_net [$onet getName]
                    foreach sink_iterm [$onet getITerms] {
                        if {[$sink_iterm getIoType] eq "INPUT"} {
                            incr fanout
                            set sink_name [[$sink_iterm getInst] getName]
                            if {[dict exists $lp_targets $sink_name]} {
                                set target_sum [expr {$target_sum + [dict get $lp_targets $sink_name] * 1000.0}]
                                incr target_count
                            }
                        }
                    }
                }
                break
            }
        }

        set avg_target "N/A"
        if {$target_count > 0} {
            set avg_target [format "%.2f" [expr {$target_sum / $target_count}]]
        }

        puts $fp "$inst_name,$cell_name,$x_um,$y_um,$tier,$fanout,$output_net,$avg_target"
        incr count
    }

    close $fp
    puts "  Found $count clock buffers -> $output_csv"
    return $count
}

# =========================================
# Proc 5: Summary Statistics
# =========================================
proc extract_debug_summary {output_csv} {
    puts "\n========== CTS Debug: Summary =========="

    set fp [open $output_csv w]
    puts $fp "metric,value"

    set setup_tns [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]
    set setup_wns [expr {[sta::worst_slack_cmd "max"] * 1e12}]
    set hold_tns [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]
    set hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]

    puts $fp "setup_tns_ps,[format %.3f $setup_tns]"
    puts $fp "setup_wns_ps,[format %.3f $setup_wns]"
    puts $fp "hold_tns_ps,[format %.3f $hold_tns]"
    puts $fp "hold_wns_ps,[format %.3f $hold_wns]"

    if {[info exists ::env(CTS_MODE)]} {
        puts $fp "cts_mode,$::env(CTS_MODE)"
    } else {
        puts $fp "cts_mode,htree"
    }

    # Count clock buffers
    set db [ord::get_db]
    set block [[$db getChip] getBlock]
    set clk_buf_count 0
    foreach inst [$block getInsts] {
        set iname [$inst getName]
        if {[string match "clkbuf_*" $iname] || [string match "sg_*" $iname] || \
            [string match "*skew_buf*" $iname]} {
            incr clk_buf_count
        }
    }
    puts $fp "clock_buffer_count,$clk_buf_count"

    close $fp
    puts "  Summary -> $output_csv"
}

# =========================================
# Main entry point
# =========================================
# Args: lp_csv and graph_csv are optional (Pin3D has neither)
proc run_cts_debug_extract {{lp_csv ""} {graph_csv ""}} {
    set results_dir $::env(CTS3D_WORK_DIR)

    puts "\n######################################################"
    puts "# CTS Debug Extraction (5 CSV files)"
    puts "######################################################"

    estimate_parasitics -placement

    # Load LP targets (empty dict for Pin3D)
    if {$lp_csv eq ""} {
        set lp_csv "$results_dir/pre_cts_skew_targets.csv"
    }
    set lp_targets [cts_debug_read_lp_targets $lp_csv]
    puts "  LP targets: [dict size $lp_targets] FFs"

    # 1. Per-FF latency
    set ff_csv "$results_dir/cts_debug_per_ff.csv"
    extract_ff_clock_latency $ff_csv $lp_targets

    # 2. Clock path decomposition
    extract_clock_path_via_sta "$results_dir/cts_debug_clock_paths.csv"

    # 3. Per-edge skew analysis (requires timing graph CSV)
    if {$graph_csv eq ""} {
        set graph_csv "$results_dir/pre_cts_ff_timing_graph.csv"
    }
    extract_per_edge $ff_csv $graph_csv $lp_targets "$results_dir/cts_debug_per_edge.csv"

    # 4. Buffer inventory
    extract_buffer_inventory $lp_targets "$results_dir/cts_debug_buffers.csv"

    # 5. Summary
    extract_debug_summary "$results_dir/cts_debug_summary.csv"

    # 6. Clock tree topology edges (for htree visualization)
    # Merged from extract_clock_tree_topology.tcl
    # Extracts buf→buf and buf→FF edges from ODB (already in memory)
    set topo_csv "$results_dir/clock_tree_edges.csv"
    extract_clock_tree_topology $topo_csv

    puts "\n>>> CTS Debug: 6 CSV files written to $results_dir/"
    puts "    Per-FF:    cts_debug_per_ff.csv"
    puts "    Paths:     cts_debug_clock_paths.csv"
    puts "    Per-Edge:  cts_debug_per_edge.csv"
    puts "    Buffers:   cts_debug_buffers.csv"
    puts "    Summary:   cts_debug_summary.csv"
    puts "    Topology:  clock_tree_edges.csv"
}

# =========================================
# Clock tree topology extraction (buf→buf, buf→FF edges)
# Merged from standalone extract_clock_tree_topology.tcl
# Uses ODB already loaded in memory — no read_db needed
# =========================================
proc extract_clock_tree_topology {output_csv} {
    set block [ord::get_db_block]
    set tech [ord::get_db_tech]
    set dbu [expr {double([$tech getDbUnitsPerMicron])}]

    # Collect clock buffer instances
    set clock_inst_names [list]
    set inst_info [dict create]
    foreach inst [$block getInsts] {
        set iname [$inst getName]
        if {![regexp {^clkbuf_|^clkload|^sg_|_relay_|_grp_} $iname]} continue
        lappend clock_inst_names $iname
        set master [$inst getMaster]
        set mname [$master getName]
        set bbox [$inst getBBox]
        set x [expr {([$bbox xMin] + [$bbox xMax]) / 2.0 / $dbu}]
        set y [expr {([$bbox yMin] + [$bbox yMax]) / 2.0 / $dbu}]
        if {[string match "*upper*" $mname]} {
            set tier "upper"
        } elseif {[string match "*bottom*" $mname]} {
            set tier "bottom"
        } else {
            set tier "unknown"
        }
        dict set inst_info $iname [list $x $y $tier $mname]
    }

    # Collect FF instances
    set ff_info [dict create]
    foreach inst [$block getInsts] {
        set iname [$inst getName]
        set master [$inst getMaster]
        set mname [$master getName]
        if {![regexp {DFF|DFFH|SDFF} $mname]} continue
        set bbox [$inst getBBox]
        set x [expr {([$bbox xMin] + [$bbox xMax]) / 2.0 / $dbu}]
        set y [expr {([$bbox yMin] + [$bbox yMax]) / 2.0 / $dbu}]
        if {[string match "*upper*" $mname]} {
            set tier "upper"
        } elseif {[string match "*bottom*" $mname]} {
            set tier "bottom"
        } else {
            set tier "unknown"
        }
        dict set ff_info $iname [list $x $y $tier $mname]
    }

    # Write edges CSV
    set fp [open $output_csv w]
    puts $fp "parent_inst,child_inst,net_name,parent_x,parent_y,parent_tier,child_x,child_y,child_tier,child_type"
    set edge_count 0

    foreach net [$block getNets] {
        set nname [$net getName]
        if {![regexp {^clk$|^clknet_|^clkbuf_|^clkload} $nname]} continue

        # Find driver instance (output pin)
        set driver_inst ""
        set driver_is_port 0
        foreach iterm [$net getITerms] {
            set io_type [$iterm getIoType]
            if {$io_type == "OUTPUT"} {
                set driver_inst [[$iterm getInst] getName]
                break
            }
        }
        if {$driver_inst == ""} {
            foreach bterm [$net getBTerms] {
                set driver_inst "CLK_PORT"
                set driver_is_port 1
                break
            }
        }
        if {$driver_inst == ""} continue

        # Get driver position
        if {$driver_is_port} {
            set dx 0; set dy 0; set dtier "port"
        } elseif {[dict exists $inst_info $driver_inst]} {
            set dinfo [dict get $inst_info $driver_inst]
            set dx [lindex $dinfo 0]; set dy [lindex $dinfo 1]; set dtier [lindex $dinfo 2]
        } else {
            continue
        }

        # Find all sink instances
        foreach iterm [$net getITerms] {
            set io_type [$iterm getIoType]
            if {$io_type == "INPUT"} {
                set sink_name [[$iterm getInst] getName]
                if {[dict exists $inst_info $sink_name]} {
                    set sinfo [dict get $inst_info $sink_name]
                    # FIX: use driver (parent) position for parent columns.
                    puts $fp "$driver_inst,$sink_name,$nname,$dx,$dy,$dtier,[lindex $sinfo 0],[lindex $sinfo 1],[lindex $sinfo 2],buf"
                    incr edge_count
                } elseif {[dict exists $ff_info $sink_name]} {
                    set sinfo [dict get $ff_info $sink_name]
                    puts $fp "$driver_inst,$sink_name,$nname,$dx,$dy,$dtier,[lindex $sinfo 0],[lindex $sinfo 1],[lindex $sinfo 2],ff"
                    incr edge_count
                }
            }
        }
    }

    close $fp
    puts "  Topology: $edge_count edges -> $output_csv"
}
