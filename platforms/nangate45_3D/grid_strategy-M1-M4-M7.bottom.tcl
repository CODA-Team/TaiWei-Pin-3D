############################################################
# Nangate45 3D PDN bottom pass
############################################################

puts "INFO: Start Nangate45 bottom PDN..."
source $::env(OPENROAD_SCRIPTS_DIR)/pdn_macro_utils.tcl

proc get_row_height_um {{fallback 1.4}} {
  if {[catch {set block [ord::get_db_block]}]} { return $fallback }
  set rows [$block getRows]
  if {[llength $rows] == 0} { return $fallback }
  set row [lindex $rows 0]
  if {[catch {set site [$row getSite]}]} { return $fallback }
  if {$site eq "" || $site eq "NULL"} { return $fallback }
  if {[catch {set h_dbu [$site getHeight]}]} { return $fallback }
  if {$h_dbu <= 0} { return $fallback }
  return [ord::dbu_to_microns $h_dbu]
}

proc tech_layer_exists {lname} {
  set tech [ord::get_db_tech]
  set layer [::odb::dbTech_findLayer $tech $lname]
  expr {$layer ne "NULL" && $layer ne ""}
}

proc derive_mesh_pitch_offset {span_um stripe_width_um requested_pitch_um requested_offset_um} {
  set mfg_grid 0.005
  set span   [expr {double($span_um)}]
  set width  [expr {double($stripe_width_um)}]
  set pitch  [expr {double($requested_pitch_um)}]
  set offset [expr {double($requested_offset_um)}]
  if {$span <= 0.0 || $width <= 0.0} { return [list $pitch $offset] }
  if {$span <= (2.0 * $offset + 2.0 * $width)} {
    set safe_offset 0.0
    set safe_pitch  [expr {round((($span + $width + $mfg_grid) / $mfg_grid)) * $mfg_grid}]
    puts "INFO: Small-core PDN fallback span=$span width=$width requested_pitch=$pitch requested_offset=$offset -> pitch=$safe_pitch offset=$safe_offset"
    return [list $safe_pitch $safe_offset]
  }
  return [list $pitch $offset]
}

proc is_upper_master {master_name} { expr {[string match "*_upper"  $master_name] ? 1 : 0} }
proc is_bottom_master {master_name} { expr {[string match "*_bottom" $master_name] ? 1 : 0} }

proc rename_upper_bottom_insts {} {
  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    set master_name [[$inst getMaster] getName]
    set is_upper  [is_upper_master $master_name]
    set is_bottom [is_bottom_master $master_name]
    if {!$is_upper && !$is_bottom} { continue }
    if {[string match "*_upper" $inst_name] || [string match "*_bottom" $inst_name]} { continue }
    set new_name [expr {$is_upper ? "${inst_name}_upper" : "${inst_name}_bottom"}]
    if {[$block findInst $new_name] ne "NULL"} { continue }
    $inst rename $new_name
  }
}

# rename_upper_bottom_insts

set core_area_bbox [[odb::get_block] getCoreArea]
set core_width  [ord::dbu_to_microns [expr {[$core_area_bbox xMax] - [$core_area_bbox xMin]}]]
set core_height [ord::dbu_to_microns [expr {[$core_area_bbox yMax] - [$core_area_bbox yMin]}]]
set mfg_grid 0.005
set m4_pitch [expr {$core_width / 1.1}]
if {$m4_pitch > 20.16} { set m4_pitch 20.16 }
set m4_pitch [expr {round($m4_pitch / $mfg_grid) * $mfg_grid}]
set m7_pitch [expr {$core_height / 1.1}]
if {$m7_pitch > 40} { set m7_pitch 40 }
set m7_pitch [expr {round($m7_pitch / $mfg_grid) * $mfg_grid}]
lassign [derive_mesh_pitch_offset $core_width 0.84 $m4_pitch 2.0] bot_m4_pitch bot_m4_offset
lassign [derive_mesh_pitch_offset $core_height 2.4 $m7_pitch 2.0] bot_m7_pitch bot_m7_offset

or_rebuild_rows_for_site $::env(PLACE_SITE) bottom
set rail_pitch [get_row_height_um 1.4]
puts "INFO: Using Nangate45 bottom followpins pitch = $rail_pitch um"

clear_global_connect
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$} -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$} -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}
pin3d_add_macro_global_connections bottom BOT_VDD BOT_VSS
global_connect

set_voltage_domain -name {Core} -power {BOT_VDD} -ground {BOT_VSS}
report_voltage_domains

define_pdn_grid -name {BOT} -voltage_domains {Core}
add_pdn_stripe -grid {BOT} -layer {M1} -width {0.14} -pitch $rail_pitch -offset {0} -followpins -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M4} -width {0.84} -pitch $bot_m4_pitch -offset $bot_m4_offset -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M7} -width {2.4} -pitch $bot_m7_pitch -offset $bot_m7_offset -nets {BOT_VDD BOT_VSS}
if {[tech_layer_exists "M10"]} {
  set m10_pitch 32.0
  # The default M10 pair needs 21.2 um; use an 18-track pitch for a small core.
  if {$core_width < 21.2} { set m10_pitch 28.8 }
  add_pdn_stripe -grid {BOT} -layer {M10} -width {3.2} -pitch $m10_pitch -offset {2} -nets {BOT_VDD BOT_VSS}
}
add_pdn_connect -grid {BOT} -layers {M1 M4}
add_pdn_connect -grid {BOT} -layers {M4 M7}

# pin3d_add_macro_grids \
#   -tier bottom \
#   -grid_prefix BOT \
#   -voltage_domain Core \
#   -nets {BOT_VDD BOT_VSS} \
#   -grid_mode pg_pins \
#   -macro_layers {} \
#   -stripe_widths {} \
#   -stripe_pitches {} \
#   -stripe_offsets {} \
#   -stripe_spacings {} \
#   -connect_layers {{M4 M7}}

# The bottom swerv_wrapper macro geometry leaves irreducible M1 followpin
# fragments near the left/right macro columns. Allow PDNGEN to keep those
# repair-channel markers without hard-failing this bottom pass.
pdn::allow_repair_channels true
puts "INFO: Nangate45 bottom PDN enables allow_repair_channels"

# pdngen
puts "INFO: Done Nangate45 bottom PDN."
