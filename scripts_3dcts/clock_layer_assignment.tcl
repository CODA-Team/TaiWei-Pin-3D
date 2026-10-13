# =========================================
# V43: LP-Based Bidirectional Clock Layer Assignment
# =========================================
#
# Two phases:
#   Phase A (CTS step): identify_lp_based_subnets
#     - Reads LP targets CSV (per-FF target_arrival_ns)
#     - Reads IO timing edges CSV (PI->FF hold slack)
#     - Classifies each clock subnet as "setup", "hold", or "default"
#     - Writes classification to file for routing step
#
#   Phase B (routing step): apply_lp_based_layers
#     - Reads the classification file
#     - Sets per-net layer ranges:
#       "hold"  -> M5-M7 (low R -> less delay -> protect hold)
#       "setup" -> M2-M3 (high R -> more delay -> deliver useful skew)
#     - Called via PRE_GLOBAL_ROUTE_TCL hook
#
# Rationale (V43):
#   only assigned hold-critical subnets to M5-M7, but detected 0 FFs
#   because it checked FF clock pin hold slack (all positive after CTS).
#   fixes this by reading pre-CTS PI->FF hold slacks from IO edges CSV
#   AND adds bidirectional assignment: high LP target subnets get M2-M3
#   (higher R -> more wire delay -> better useful skew delivery).

# Phase A: Classify clock subnets based on LP targets + PI->FF hold criticality
proc identify_lp_based_subnets {lp_csv io_csv output_file} {
  puts "\n========== V43: LP-Based Bidirectional Layer Assignment =========="

  # Get thresholds from env
  set setup_thresh 50.0  ;# LP target > this (ps) -> "setup" direction (M2-M3)
  set hold_thresh  10.0  ;# LP target < this (ps) + PI hold critical -> "hold" (M5-M7)
  set hold_slack_thresh 0.0  ;# PI->FF hold slack < this (ns) -> hold-critical

  if {[info exists ::env(CTS_LAYER_SETUP_TARGET_THRESH)]} {
    set setup_thresh $::env(CTS_LAYER_SETUP_TARGET_THRESH)
  }
  if {[info exists ::env(CTS_LAYER_HOLD_TARGET_THRESH)]} {
    set hold_thresh $::env(CTS_LAYER_HOLD_TARGET_THRESH)
  }
  if {[info exists ::env(CTS_HOLD_CRITICAL_THRESHOLD_NS)]} {
    set hold_slack_thresh $::env(CTS_HOLD_CRITICAL_THRESHOLD_NS)
  }

  # Step 1: Parse LP targets CSV -> per-FF target (ps)
  puts "  Reading LP targets: $lp_csv"
  array set ff_target {}
  set n_targets 0

  if {[file exists $lp_csv]} {
    set fp [open $lp_csv r]
    gets $fp header  ;# skip header: ff_name,target_arrival_ns,tier
    while {[gets $fp line] >= 0} {
      set fields [split $line ","]
      if {[llength $fields] < 2} continue
      set ff_name [lindex $fields 0]
      set target_ns [lindex $fields 1]
      if {[catch {set target_ps [expr {$target_ns * 1000.0}]}]} continue
      set ff_target($ff_name) $target_ps
      incr n_targets
    }
    close $fp
    puts "  LP targets loaded: $n_targets FFs"
  } else {
    puts "  WARNING: LP targets CSV not found: $lp_csv"
  }

  # Step 2: Parse IO timing edges CSV -> PI->FF hold-critical FFs
  # Uses pre-CTS IO edges (generated in Phase 0 of cts_3d.tcl).
  # Pre-CTS slacks are a reasonable proxy for hold criticality:
  # FFs with negative PI->FF hold slack pre-CTS will be even worse post-CTS
  # (CTS adds clock latency, worsening PI->FF hold for capture FFs).
  puts "  Reading IO timing edges: $io_csv"
  set hold_critical_ffs [dict create]
  set n_pi_hold_edges 0

  if {[file exists $io_csv]} {
    set fp [open $io_csv r]
    gets $fp header  ;# skip header
    while {[gets $fp line] >= 0} {
      set fields [split $line ","]
      if {[llength $fields] < 5} continue
      set edge_type [lindex $fields 0]
      set ff_name [lindex $fields 2]
      set slack_hold_ns [lindex $fields 4]

      if {$edge_type eq "PI_TO_FF" && $slack_hold_ns ne ""} {
        if {[catch {set hold_ns [expr {double($slack_hold_ns)}]}]} continue
        if {$hold_ns < $hold_slack_thresh} {
          # Track worst (most negative) hold slack per FF
          if {![dict exists $hold_critical_ffs $ff_name] ||
              $hold_ns < [dict get $hold_critical_ffs $ff_name]} {
            dict set hold_critical_ffs $ff_name $hold_ns
          }
          incr n_pi_hold_edges
        }
      }
    }
    close $fp
    puts "  PI->FF hold-critical FFs: [dict size $hold_critical_ffs] (slack < ${hold_slack_thresh}ns)"
  } else {
    puts "  WARNING: IO timing edges CSV not found: $io_csv"
  }

  # Step 3: Scan clock subnets and classify by direction
  set block [ord::get_db_block]
  set n_setup 0
  set n_hold 0
  set n_default 0
  set total_clock 0

  set fp [open $output_file w]
  puts $fp "# LP-based bidirectional layer assignment"
  puts $fp "# setup_thresh=${setup_thresh}ps hold_thresh=${hold_thresh}ps"
  puts $fp "# Format: net_name direction"

  foreach net [$block getNets] {
    set name [$net getName]
    # Only process CTS-generated clock nets
    if {![string match "clknet_*" $name] &&
        ![string match "clkbuf_*" $name] &&
        ![string match "sg_*" $name]} {
      continue
    }
    incr total_clock

    # Find driven FFs and their LP targets
    set max_target 0.0
    set has_hold_critical 0
    set n_driven_ffs 0

    foreach iterm [$net getITerms] {
      set inst [$iterm getInst]
      set inst_name [$inst getName]

      # Check if this instance is a FF with LP target
      if {[info exists ff_target($inst_name)]} {
        set t $ff_target($inst_name)
        if {$t > $max_target} {
          set max_target $t
        }
        incr n_driven_ffs
      }

      # Check if PI->FF hold-critical
      if {[dict exists $hold_critical_ffs $inst_name]} {
        set has_hold_critical 1
      }
    }

    # Classify: hold-critical + low target -> hold; high target -> setup
    if {$has_hold_critical && $max_target < $hold_thresh} {
      puts $fp "$name hold"
      incr n_hold
    } elseif {$max_target > $setup_thresh} {
      puts $fp "$name setup"
      incr n_setup
    } else {
      incr n_default
    }
  }

  close $fp
  puts "  Total clock subnets: $total_clock"
  puts "  Setup direction (high R, more delay): $n_setup (target > ${setup_thresh}ps)"
  puts "  Hold direction (low R, less delay): $n_hold (hold-critical + target < ${hold_thresh}ps)"
  puts "  Default (no override): $n_default"
  puts "  Written to: $output_file"
  puts "========== V43: Layer Classification Complete =========="

  return [expr {$n_setup + $n_hold}]
}

# Phase B: Apply per-net layer ranges during routing (via PRE_GLOBAL_ROUTE_TCL)
proc apply_lp_based_layers {subnet_file} {
  puts "\n========== V43: Applying Bidirectional Clock Layer Ranges =========="

  if {![file exists $subnet_file]} {
    puts "  WARNING: $subnet_file not found, skipping layer assignment"
    return
  }

  # Get layer ranges from env
  set setup_min "M2"; set setup_max "M3"
  set hold_min "M5";  set hold_max "M7"
  if {[info exists ::env(CTS_SETUP_MIN_LAYER)]} { set setup_min $::env(CTS_SETUP_MIN_LAYER) }
  if {[info exists ::env(CTS_SETUP_MAX_LAYER)]} { set setup_max $::env(CTS_SETUP_MAX_LAYER) }
  if {[info exists ::env(CTS_HOLD_MIN_LAYER)]}  { set hold_min $::env(CTS_HOLD_MIN_LAYER) }
  if {[info exists ::env(CTS_HOLD_MAX_LAYER)]}  { set hold_max $::env(CTS_HOLD_MAX_LAYER) }

  set fp [open $subnet_file r]
  set n_setup 0
  set n_hold 0
  set n_skipped 0

  while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue

    set parts [split $line]
    set net_name [lindex $parts 0]
    set direction [lindex $parts 1]

    if {[catch {
      if {$direction eq "hold"} {
        set_clock_subnet_layers -net $net_name \
          -min_layer $hold_min -max_layer $hold_max
        incr n_hold
      } elseif {$direction eq "setup"} {
        set_clock_subnet_layers -net $net_name \
          -min_layer $setup_min -max_layer $setup_max
        incr n_setup
      }
    } err]} {
      incr n_skipped
    }
  }
  close $fp

  puts "  Setup (${setup_min}-${setup_max}): $n_setup subnets"
  puts "  Hold (${hold_min}-${hold_max}): $n_hold subnets"
  if {$n_skipped > 0} { puts "  Skipped: $n_skipped (net not found)" }
  # Wrap in catch to avoid crash if SWIG function unavailable
  if {[catch {set cnt [grt::get_per_net_clock_layer_range_count]} err]} {
    set cnt [expr {$n_setup + $n_hold}]
  }
  puts "  Total overrides: $cnt"
  puts "========== V43: Layer Assignment Complete =========="
}
