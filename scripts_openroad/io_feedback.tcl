# Optional 2D-placement-informed IO handoff. Read records as Tcl lists, never
# source/eval them. Preserve boundary side and order across different die sizes.
namespace eval ::pin3d_io_feedback {}

# Deterministic monotone assignment to equally spaced boundary slots. Reserve
# sufficient slots for the remaining pins, even when many targets coincide.
proc ::pin3d_io_feedback::assign_slots {targets length margin step} {
  if {$step <= 0 || $length <= 2*$margin || $margin < 0} {
    error "Invalid IO boundary dimensions or pitch"
  }
  set capacity [expr {int(floor(($length-2*$margin)/$step))+1}]
  set sorted [lsort -real -index 1 $targets]
  set count [llength $sorted]
  if {$count > $capacity} {error "IO feedback edge capacity=$capacity pins=$count"}
  set result {}
  set previous -1
  set index 0
  foreach item $sorted {
    lassign $item name fraction
    if {![string is double -strict $fraction] || !($fraction >= 0 && $fraction <= 1)} {
      error "Invalid IO boundary fraction for $name"
    }
    set desired [expr {int(round(($fraction*$length-$margin)/$step))}]
    set slot [expr {max($previous+1,min($capacity-($count-$index),$desired))}]
    lappend result [list $name [expr {$margin+$slot*$step}]]
    set previous $slot
    incr index
  }
  return $result
}

proc ::pin3d_io_feedback::pin_center {bterm} {
  foreach bpin [$bterm getBPins] {
    foreach box [$bpin getBoxes] {
      return [list [expr {0.5*([$box xMin]+[$box xMax])}] \
                   [expr {0.5*([$box yMin]+[$box yMax])}]]
    }
  }
  error "Missing physical IO shape: [$bterm getName]"
}

proc ::pin3d_io_feedback::write_assignment {path} {
  set ports [lsort -dictionary -unique [concat \
      [io_port_names [all_inputs]] [io_port_names [all_outputs]]]]
  lassign [ord::get_die_area] lx ly ux uy
  set dbu [_io_dbu]
  set fh [open $path w]
  puts $fh [list schema pin3d_io_feedback_v1]
  puts $fh [list bbox $lx $ly $ux $uy]
  foreach name $ports {
    set bterm [[ord::get_db_block] findBTerm $name]
    lassign [pin_center $bterm] x y
    set x [expr {$x/$dbu}]; set y [expr {$y/$dbu}]
    set distances [list [list left [expr {abs($x-$lx)}]] \
      [list right [expr {abs($x-$ux)}]] [list bottom [expr {abs($y-$ly)}]] \
      [list top [expr {abs($y-$uy)}]]]
    set side [lindex [lindex [lsort -real -index 1 $distances] 0] 0]
    if {$side in {left right}} {
      set fraction [expr {($y-$ly)/($uy-$ly)}]
    } else {
      set fraction [expr {($x-$lx)/($ux-$lx)}]
    }
    puts $fh [list pin $name $side $fraction]
  }
  close $fh
  puts "IO-FEEDBACK: exported [llength $ports] ports to $path"
}

proc ::pin3d_io_feedback::read_assignment {path ports} {
  if {![file isfile $path]} {error "Missing 2D IO feedback handoff: $path"}
  set records [dict create]
  set schema 0
  set fh [open $path r]
  while {[gets $fh line] >= 0} {
    if {[string trim $line] eq ""} {continue}
    switch -- [lindex $line 0] {
      schema {
        if {$line ne [list schema pin3d_io_feedback_v1]} {error "Invalid IO handoff schema"}
        set schema 1
      }
      bbox {if {[llength $line] != 5} {error "Invalid IO handoff bbox"}}
      pin {
        if {[llength $line] != 4} {error "Invalid IO handoff pin record"}
        lassign $line kind name side fraction
        if {$side ni {left right bottom top} ||
            ![string is double -strict $fraction] || !($fraction >= 0 && $fraction <= 1)} {
          error "Invalid IO handoff location for $name"
        }
        if {[dict exists $records $name]} {error "Duplicate IO handoff pin $name"}
        dict set records $name [list $side $fraction]
      }
      default {error "Unknown IO handoff record"}
    }
  }
  close $fh
  if {!$schema || [lsort -dictionary [dict keys $records]] ne [lsort -dictionary $ports]} {
    error "IO handoff schema/port set does not match the 3D design"
  }
  return $records
}

proc ::pin3d_io_feedback::place_in_3d {path} {
  set ports [lsort -dictionary -unique [concat \
      [io_port_names [all_inputs]] [io_port_names [all_outputs]]]]
  set records [read_assignment $path $ports]
  set info [::pin3d_io::partition_ports [file join $::env(RESULTS_DIR) partition.txt] $ports]
  lassign [ord::get_die_area] lx ly ux uy
  clear_io_pin_constraints
  set audit [open [file join $::env(LOG_DIR) io_feedback_mapping.rpt] w]
  puts $audit "# pin tier side source_fraction assigned_um actual_x_um actual_y_um layer"
  foreach tier {bottom upper} {
    set h $::env(IO_PLACER_H_BOTTOM); set v $::env(IO_PLACER_V_BOTTOM)
    if {$tier eq "upper"} {
      set h $::env(IO_PLACER_H_UPPER); set v $::env(IO_PLACER_V_UPPER)
    }
    set margin [expr {2*max([_io_layer_pitch_um $h],[_io_layer_pitch_um $v])}]
    foreach side {left right bottom top} {
      set targets {}
      foreach name [dict get $info ${tier}_pins] {
        lassign [dict get $records $name] old_side fraction
        if {$side eq $old_side} {lappend targets [list $name $fraction]}
      }
      # Horizontal wires meet the left/right boundaries, vertical wires the
      # bottom/top boundaries (hor_layers does not mean top/bottom edges).
      if {$side in {left right}} {
        set layer $h; set length [expr {$uy-$ly}]
      } else {
        set layer $v; set length [expr {$ux-$lx}]
      }
      set step [expr {2*[_io_layer_pitch_um $layer]}]
      set previous ""
      foreach item [assign_slots $targets $length $margin $step] {
        lassign $item name offset
        switch $side {
          left {set x $lx; set y [expr {$ly+$offset}]}
          right {set x $ux; set y [expr {$ly+$offset}]}
          bottom {set x [expr {$lx+$offset}]; set y $ly}
          top {set x [expr {$lx+$offset}]; set y $uy}
        }
        place_pin -pin_name $name -layer $layer -location [list $x $y] \
            -force_to_die_boundary -placed_status
        set bterm [[ord::get_db_block] findBTerm $name]
        lassign [pin_center $bterm] actual_x actual_y
        set actual_x [expr {$actual_x/[_io_dbu]}]
        set actual_y [expr {$actual_y/[_io_dbu]}]
        set along [expr {$side in {left right} ? $actual_y : $actual_x}]
        if {$previous ne "" && $along-$previous < $step-1.0/[_io_dbu]} {
          error "IO feedback track snapping violates spacing at $name"
        }
        set previous $along
        puts $audit [list $name $tier $side [lindex [dict get $records $name] 1] \
            $offset $actual_x $actual_y $layer]
      }
    }
  }
  close $audit
  ::pin3d_io::verify_and_report $info \
      [list $::env(IO_PLACER_H_UPPER) $::env(IO_PLACER_V_UPPER)] \
      [list $::env(IO_PLACER_H_BOTTOM) $::env(IO_PLACER_V_BOTTOM)] \
      [file join $::env(LOG_DIR) io_pin_tiers.rpt]
  puts "IO-FEEDBACK: inherited side/order from 2D, scaled and track-snapped [llength $ports] ports"
}
