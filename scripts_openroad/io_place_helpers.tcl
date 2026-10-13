# ============================================================
# io_place_helpers.tcl
# Shared IO placement setup/helpers split out from io_place.tcl.
# ============================================================
if {![info exists ::env(IO_PLACER_H)] || ![info exists ::env(IO_PLACER_V)]} {
  error "IO_PLACER_H / IO_PLACER_V must be set."
}
set LAYER_H $::env(IO_PLACER_H)
set LAYER_V $::env(IO_PLACER_V)

proc io_port_names {port_objects} {
  set names {}
  foreach port $port_objects {
    lappend names [get_full_name $port]
  }
  return [lsort -dictionary $names]
}

proc get_die_bbox {} {
  return [ord::get_die_area]
}

proc _io_dbu {} {
  set db [ord::get_db]
  if {$db eq "NULL"} {
    error "OpenDB is not initialized."
  }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} {
    error "OpenDB tech is not available."
  }
  return [odb::dbTech_getDbUnitsPerMicron $tech]
}

proc _io_layer {layer_name} {
  set db [ord::get_db]
  if {$db eq "NULL"} {
    error "OpenDB is not initialized."
  }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} {
    error "OpenDB tech is not available."
  }
  set layer [odb::dbTech_findLayer $tech $layer_name]
  if {$layer eq "NULL"} {
    error "Routing layer '$layer_name' was not found."
  }
  return $layer
}

proc _io_layer_pitch_um {layer_name} {
  set layer [_io_layer $layer_name]
  set dbu [_io_dbu]
  set candidates {}
  foreach pitch [list [odb::dbTechLayer_getPitchX $layer] [odb::dbTechLayer_getPitchY $layer]] {
    if {$pitch > 0} {
      lappend candidates $pitch
    }
  }
  if {[llength $candidates] == 0} {
    error "Routing layer '$layer_name' does not report a legal pitch."
  }
  return [expr {double([lindex [lsort -integer $candidates] 0]) / double($dbu)}]
}

proc _io_layer_width_um {layer_name} {
  set layer [_io_layer $layer_name]
  set dbu [_io_dbu]
  set width [odb::dbTechLayer_getWidth $layer]
  if {$width <= 0} {
    return [_io_layer_pitch_um $layer_name]
  }
  return [expr {double($width) / double($dbu)}]
}

proc _edge_capacity_from_intervals_um {intervals effective_step_um} {
  if {$effective_step_um <= 0.0} {
    error "effective_step_um must be positive."
  }
  set cap 0
  foreach iv $intervals {
    lassign $iv lo hi
    set seg_len [expr {$hi - $lo}]
    if {$seg_len <= 0.0} {
      continue
    }
    incr cap [expr {int(floor($seg_len / $effective_step_um))}]
  }
  return $cap
}

proc has_bits {base all_list} {
  foreach q $all_list {
    if {[string match "${base}\[*]" $q]} {
      return 1
    }
  }
  return 0
}

proc sanitize_ports {ports all_ports} {
  set keep {}
  array set seen {}
  foreach p $ports {
    if {[regexp -nocase {^(VDD|VSS|VDDA|VSSA|VCCD|VSSD|PWR|GND)} $p]} {
      continue
    }
    if {[regexp {\[[0-9]+\]} $p]} {
      if {![info exists seen($p)]} {
        set seen($p) 1
        lappend keep $p
      }
      continue
    }
    if {[has_bits $p $all_ports]} {
      continue
    }
    if {![info exists seen($p)]} {
      set seen($p) 1
      lappend keep $p
    }
  }
  return [lsort -dictionary -unique $keep]
}
