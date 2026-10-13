# start opt_lg_design.tcl
puts "Starting opt_lg_design.tcl..."

proc _opt_lg_env_flag {name default_value} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    return $default_value
  }
  set key [string tolower [string trim $::env($name)]]
  switch -- $key {
    "1" - "on" - "true" - "yes" - "enabled" { return 1 }
    "0" - "off" - "false" - "no" - "disabled" { return 0 }
    default { return $default_value }
  }
}

estimate_parasitics -placement

set enable_repair_design [_opt_lg_env_flag OPENROAD_OPT_LG_ENABLE_REPAIR_DESIGN 1]
set enable_tie_fanout [_opt_lg_env_flag OPENROAD_OPT_LG_ENABLE_TIE_FANOUT 1]

puts "Perform buffer insertion..."

if {$enable_repair_design} {
  pin3d_repair_timing_helper
} else {
  puts "Skip repair_design because OPENROAD_OPT_LG_ENABLE_REPAIR_DESIGN=off"
}

set tie_separation 5

if {$enable_tie_fanout} {
  # Repair tie lo fanout
  puts "Repair tie lo fanout..."
  set tielo_cell_name [lindex $env(TIELO_CELL_AND_PORT) 0]
  set tielo_lib_name [get_name [get_property [lindex [get_lib_cell $tielo_cell_name] 0] library]]
  set tielo_pin $tielo_lib_name/$tielo_cell_name/[lindex $env(TIELO_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tielo_pin

  # Repair tie hi fanout
  puts "Repair tie hi fanout..."
  set tiehi_cell_name [lindex $env(TIEHI_CELL_AND_PORT) 0]
  set tiehi_lib_name [get_name [get_property [lindex [get_lib_cell $tiehi_cell_name] 0] library]]
  set tiehi_pin $tiehi_lib_name/$tiehi_cell_name/[lindex $env(TIEHI_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tiehi_pin
} else {
  puts "Skip repair_tie_fanout because OPENROAD_OPT_LG_ENABLE_TIE_FANOUT=off"
}

set_placement_padding -global \
    -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
    -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

puts "detailed_placement"
[catch { detailed_placement } ]

puts "improve_placement"
[catch { improve_placement } ]

puts "optimize_mirroring"
[catch {optimize_mirroring} ]

[catch { detailed_placement } ]

estimate_parasitics -placement

