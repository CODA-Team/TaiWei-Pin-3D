# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
########################################################################
# place_pin.tcl
#   Uniform IO pin placement on perimeter with corner avoidance.
#   - Uses global Tcl variables: IO_PLACER_H (LEFT/RIGHT), IO_PLACER_V (BOTTOM/TOP)
#   - Distributes ALL signal IOs (excludes obvious P/G) along 4 sides
#   - Corner margin = 5% of short side
#   - Places pins one–by–one with -assign/-snap TRACK to avoid IMPPTN-970
########################################################################

# Flatten various dbGet box formats into {lx ly ux uy}
proc __box_flat4 {box} {
  # box can be "0 0 5.94 5.832", "{0 0 5.94 5.832}" or "{{0 0} {5.94 5.832}}"
  set nums {}
  set s "$box"
  foreach tok [split $s " \t\r\n{}"] {
    if {$tok eq ""} { continue }
    if {![string is double -strict $tok]} { continue }
    lappend nums $tok
  }
  if {[llength $nums] != 4} {
    error "Unsupported top.fPlan.box format: $box"
  }
  return $nums
}

# Map a scalar offset s (along usable perimeter) to (x, y, side, layer)
proc __map_perimeter {s lx ly ux uy cm usableB usableR layerH layerV} {
  set lenB $usableB
  set lenR $usableR
  set lenT $usableB
  set lenL $usableR

  # bottom usable segment: LEFT->RIGHT
  if {$s < $lenB} {
    set side  "BOTTOM"
    set layer $layerV
    set x     [expr {$lx + $cm + $s}]
    set y     $ly
  } else {
    set s [expr {$s - $lenB}]
    # right: BOTTOM->TOP
    if {$s < $lenR} {
      set side  "RIGHT"
      set layer $layerH
      set x     $ux
      set y     [expr {$ly + $cm + $s}]
    } else {
      set s [expr {$s - $lenR}]
      # top: RIGHT->LEFT
      if {$s < $lenT} {
        set side  "TOP"
        set layer $layerV
        set x     [expr {$ux - $cm - $s}]
        set y     $uy
      } else {
        # left: TOP->BOTTOM
        set s [expr {$s - $lenT}]
        set side  "LEFT"
        set layer $layerH
        set x     $lx
        set y     [expr {$uy - $cm - $s}]
      }
    }
  }
  return [list $x $y $side $layer]
}

proc place_all_ios {} {
  # --------------------------------------------------------------------
  # 0. IO layers from global vars
  # --------------------------------------------------------------------
  if {![info exists ::env(IO_PLACER_H)] || ![info exists ::env(IO_PLACER_V)]} {
    error "Environment variables IO_PLACER_H and IO_PLACER_V must be set before calling place_all_ios."
  }
  set layerH $::env(IO_PLACER_H)
  set layerV $::env(IO_PLACER_V)

  # --------------------------------------------------------------------
  # 1. Collect IO pins (exclude obvious power/ground)
  # --------------------------------------------------------------------
  set pins {}
  foreach t [dbGet top.terms] {
    set name [dbGet $t.name]
    # Skip obvious P/G style names
    if {[regexp -nocase {^(VDD|VSS|VDDA|VSSA|VCCD|VSSD|PWR|GND)} $name]} {
      continue
    }
    lappend pins $name
  }
  set pins [lsort -dictionary -unique $pins]
  set N [llength $pins]
  if {$N == 0} {
    puts "IO-INFO: No signal IO pins found. Nothing to place."
    return
  }

  # --------------------------------------------------------------------
  # 2. Get die box in microns (flat {lx ly ux uy})
  # --------------------------------------------------------------------
  set flat [__box_flat4 [dbGet top.fPlan.box]]
  lassign $flat lx ly ux uy

  set W [expr {$ux - $lx}]
  set H [expr {$uy - $ly}]
  set short [expr {$W < $H ? $W : $H}]
  set perim [expr {2.0*($W + $H)}]

  # --------------------------------------------------------------------
  # 3. Corner margin (5% of short side) and usable perimeter
  # --------------------------------------------------------------------
  set cm [expr {0.05 * $short}]
  set usableB [expr {$W - 2.0*$cm}]
  set usableR [expr {$H - 2.0*$cm}]

  if {$usableB <= 0.0 || $usableR <= 0.0} {
    # Die too small for 5% margin, fall back to no corner margin
    set cm 0.0
    set usableB $W
    set usableR $H
  }
  set usablePerim [expr {2.0 * ($usableB + $usableR)}]
  set pitch       [expr {$usablePerim / double($N)}]

  puts [format "IO-INFO: N=%d, W=%.4f, H=%.4f, short=%.4f, perim=%.4f" \
                $N $W $H $short $perim]
  puts [format "IO-INFO: corner_margin=%.4f, usablePerim=%.4f, pitch=%.4f" \
                $cm $usablePerim $pitch]
  puts [format "Layers: LEFT/RIGHT -> %s, BOTTOM/TOP -> %s" $layerH $layerV]

  # --------------------------------------------------------------------
  # 4. Place each pin individually along perimeter
  # --------------------------------------------------------------------
  # Small offset so we do not sit exactly at segment endpoints
  set fracOffset 0.5
  setPinAssignMode -pinEditInBatch true
  for {set i 0} {$i < $N} {incr i} {
    set pin [lindex $pins $i]
    set s   [expr {$pitch * ($fracOffset + $i)}]

    set map [__map_perimeter $s $lx $ly $ux $uy $cm $usableB $usableR $layerH $layerV]
    lassign $map x y side layer

    puts [format "Placing %-16s on %-6s @ (%.4f, %.4f) layer=%s" $pin $side $x $y $layer]

    editPin -pin $pin -layer $layer -side $side \
            -assign "$x $y" -snap TRACK -fixOverlap 1 \
            -skipWrappingPins -global_location
  }
  setPinAssignMode -pinEditInBatch false

  legalizePin -keepLayer -moveFixedPin

  puts "FINAL: IO pins placed on perimeter and legalized."
}

# Auto–execute when sourced
place_all_ios
