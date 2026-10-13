# buffer_sizing.tcl
# Net-benefit buffer sizing with hold penalty + STA validation
#
# Strategy:
#   - Extract timing edges (launch FF -> capture FF) with BOTH setup and hold slack
#   - Extract clock buffers and their driven FFs
#   - Python computes per-buffer net-benefit (setup + hold combined)
#   - Apply sizing one at a time with STA re-validation (accept/rollback)

namespace eval buffer_sizing {
    variable script_dir [file dirname [info script]]
}

# =========================================
# Timing edge extraction (setup + hold)
# =========================================

# Extract BOTH setup and hold slack
# Two-pass approach: worst setup paths + worst hold paths, merged by edge key
proc extract_timing_edges_simple {output_csv {num_paths 5000}} {
    puts "Extracting timing edges (setup + hold) - ${num_paths} worst paths per type..."

    # Pass 1: Worst setup paths
    array set edge_setup {}
    array set edge_hold {}
    array set edge_launch {}
    array set edge_capture {}

    puts "  Pass 1: Analyzing worst $num_paths setup paths..."
    if {[catch {
        set path_ends [find_timing_paths -sort_by_slack -path_delay max \
                        -group_path_count $num_paths]

        foreach path_end $path_ends {
            set slack_ps [expr {[$path_end slack] * 1e12}]
            set end_pin_name [get_full_name [$path_end pin]]
            set all_pins [[$path_end path] pins]
            if {[llength $all_pins] == 0} continue
            set start_pin_name [get_full_name [lindex $all_pins end]]

            set launch_ff [regsub {/[^/]+$} $start_pin_name ""]
            set capture_ff [regsub {/[^/]+$} $end_pin_name ""]
            set edge_key "${launch_ff}__${capture_ff}"

            # Keep worst (most negative) setup slack per edge
            if {![info exists edge_setup($edge_key)] || $slack_ps < $edge_setup($edge_key)} {
                set edge_setup($edge_key) $slack_ps
                set edge_launch($edge_key) $launch_ff
                set edge_capture($edge_key) $capture_ff
            }
        }
    } err]} {
        puts "  Warning: Error in setup path extraction: $err"
    }
    puts "  Pass 1: [array size edge_setup] unique setup edges"

    # Pass 2: Worst hold paths
    puts "  Pass 2: Analyzing worst $num_paths hold paths..."
    if {[catch {
        set hold_path_ends [find_timing_paths -sort_by_slack -path_delay min \
                             -group_path_count $num_paths]

        foreach path_end $hold_path_ends {
            set slack_ps [expr {[$path_end slack] * 1e12}]
            set end_pin_name [get_full_name [$path_end pin]]
            set all_pins [[$path_end path] pins]
            if {[llength $all_pins] == 0} continue
            set start_pin_name [get_full_name [lindex $all_pins end]]

            set launch_ff [regsub {/[^/]+$} $start_pin_name ""]
            set capture_ff [regsub {/[^/]+$} $end_pin_name ""]
            set edge_key "${launch_ff}__${capture_ff}"

            # Keep worst (most negative) hold slack per edge
            if {![info exists edge_hold($edge_key)] || $slack_ps < $edge_hold($edge_key)} {
                set edge_hold($edge_key) $slack_ps
                # Also register edge if not seen in setup pass
                if {![info exists edge_launch($edge_key)]} {
                    set edge_launch($edge_key) $launch_ff
                    set edge_capture($edge_key) $capture_ff
                }
            }
        }
    } err]} {
        puts "  Warning: Error in hold path extraction: $err"
    }
    puts "  Pass 2: [array size edge_hold] unique hold edges"

    # Merge and write CSV
    set fp [open $output_csv w]
    puts $fp "launch_ff,capture_ff,slack_setup_ps,slack_hold_ps"

    set edge_count 0
    foreach edge_key [array names edge_launch] {
        set launch_ff $edge_launch($edge_key)
        set capture_ff $edge_capture($edge_key)
        set setup_slack [expr {[info exists edge_setup($edge_key)] ? $edge_setup($edge_key) : 0.0}]
        set hold_slack [expr {[info exists edge_hold($edge_key)] ? $edge_hold($edge_key) : 0.0}]

        puts $fp "$launch_ff,$capture_ff,$setup_slack,$hold_slack"
        incr edge_count
    }

    close $fp
    puts "  Total: $edge_count unique timing edges (with both setup + hold slack)"
    puts "  Written to $output_csv"
    return $edge_count
}

# =========================================
# Available buffer master query from ODB
# =========================================

# Query ODB for all BUF masters with tier suffix
# Replaces hardcoded SIZE_OPTIONS in Python
proc extract_available_buffers {output_csv} {
    puts "Querying available buffer masters from ODB..."
    set db [ord::get_db]

    set fp [open $output_csv w]
    puts $fp "master_name,tier,drive_strength"

    set count 0
    foreach lib [$db getLibs] {
    foreach master [$lib getMasters] {
        set name [$master getName]
        # Match BUF cells with tier suffix
        if {![string match "*BUF*" [string toupper $name]]} continue
        if {![string match "*_bottom" $name] && ![string match "*_upper" $name]} continue

        # Determine tier
        if {[string match "*_bottom" $name]} {
            set tier "bottom"
        } else {
            set tier "upper"
        }

        # Extract drive strength from name
        # ASAP7: BUFx8_ASAP7_75t_R_bottom -> 8
        # NanGate: BUF_X8_bottom -> 8
        set strength 0
        if {[regexp {BUFx(\d+)f?_} $name -> s]} {
            set strength $s
        } elseif {[regexp {BUF_X(\d+)_} $name -> s]} {
            set strength $s
        }

        puts $fp "$name,$tier,$strength"
        incr count
    }
    }

    close $fp
    puts "  Found $count buffer masters (bottom + upper)"
    puts "  Written to $output_csv"
    return $count
}

# =========================================
# Buffer info extraction
# =========================================

proc extract_buffer_info {output_csv} {
    puts "Extracting clock buffer info..."

    set db [ord::get_db]
    set block [[$db getChip] getBlock]

    set fp [open $output_csv w]
    puts $fp "buffer_inst,buffer_cell,driven_ffs"

    set buffer_count 0

    foreach inst [$block getInsts] {
        set inst_name [$inst getName]
        set master [$inst getMaster]
        set cell_name [$master getName]

        # Filter for clock buffers
        set is_clock_buf 0
        if {[string match "*clkbuf*" $inst_name] || \
            [string match "*skew_buf*" $inst_name] || \
            [string match "*cts*" [string tolower $inst_name]]} {
            set is_clock_buf 1
        }

        if {!$is_clock_buf} continue

        # Check if cell is a buffer
        if {![string match "*BUF*" [string toupper $cell_name]]} {
            continue
        }

        # Find driven FFs (fanout FFs via clock pins)
        set driven_ffs {}

        foreach iterm [$inst getITerms] {
            set mterm [$iterm getMTerm]
            if {[$mterm getIoType] ne "OUTPUT"} continue

            set out_net [$iterm getNet]
            if {$out_net eq "NULL"} continue

            foreach fanout_iterm [$out_net getITerms] {
                set fanout_inst [$fanout_iterm getInst]
                set fanout_master [$fanout_inst getMaster]

                if {[$fanout_master isSequential]} {
                    set fanout_mterm [$fanout_iterm getMTerm]
                    set pin_name [$fanout_mterm getName]

                    if {[string match "*CLK*" [string toupper $pin_name]] || \
                        [string match "*CK" [string toupper $pin_name]]} {
                        set ff_name [$fanout_inst getName]
                        lappend driven_ffs $ff_name
                    }
                }
            }
        }

        set driven_ffs_str [join $driven_ffs ";"]
        puts $fp "$inst_name,$cell_name,$driven_ffs_str"
        incr buffer_count
    }

    close $fp
    puts "  Extracted $buffer_count clock buffers"
    puts "  Written to $output_csv"
    return $buffer_count
}

# =========================================
# STA-validated apply (one at a time)
# =========================================

# Apply sizing changes one at a time with STA re-validation
# Accepts change if TNS improves or stays neutral; rollback otherwise
proc apply_buffer_sizing_validated {sizing_csv {setup_tol 2.0} {hold_degrade_limit 20.0}} {
    set db [ord::get_db]
    set block [[$db getChip] getBlock]

    set baseline_tns [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
    set baseline_hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]

    set fp [open $sizing_csv r]
    gets $fp header

    set accepted 0
    set rejected 0
    set errors 0
    set prev_tns $baseline_tns

    while {[gets $fp line] >= 0} {
        set fields [split $line ","]
        if {[llength $fields] < 3} continue

        set inst_name [lindex $fields 0]
        set old_cell [lindex $fields 1]
        set new_cell [lindex $fields 2]
        set direction [expr {[llength $fields] > 3 ? [lindex $fields 3] : "?"}]

        set inst [$block findInst $inst_name]
        if {$inst eq "NULL"} {
            incr errors
            continue
        }

        set new_master [$db findMaster $new_cell]
        if {$new_master eq "NULL" || $new_master eq ""} {
            incr errors
            continue
        }

        # Save old master for rollback
        set old_master [$inst getMaster]

        # Apply sizing change
        $inst swapMaster $new_master

        # STA update
        estimate_parasitics -placement

        # Check improvement
        set new_tns [expr {abs([sta::total_negative_slack_cmd "max"]) * 1e12}]
        set new_hold_wns [expr {[sta::worst_slack_cmd "min"] * 1e12}]
        set setup_delta [expr {$prev_tns - $new_tns}]
        set hold_degrade [expr {$baseline_hold_wns - $new_hold_wns}]

        set accept 1
        set reason ""

        if {$setup_delta < -$setup_tol} {
            set accept 0
            set reason "setup worsened [format %.1f [expr {-$setup_delta}]]ps"
        }

        if {$accept && $hold_degrade > $hold_degrade_limit} {
            set accept 0
            set reason "hold degraded [format %.1f $hold_degrade]ps"
        }

        if {$accept} {
            set prev_tns $new_tns
            incr accepted
            puts "    ACCEPT $inst_name ($direction) | TNS=[format %.1f $new_tns] delta=[format %+.1f [expr {-$setup_delta}]] hold=[format %.1f $new_hold_wns]ps"
        } else {
            $inst swapMaster $old_master
            estimate_parasitics -placement
            incr rejected
            puts "    REJECT $inst_name ($direction) | $reason"
        }
    }

    close $fp
    puts "  STA-validated apply: $accepted accepted, $rejected rejected, $errors errors"
    return $accepted
}

# Export procedures
namespace export extract_timing_edges_simple extract_buffer_info extract_available_buffers
namespace export apply_buffer_sizing_validated
