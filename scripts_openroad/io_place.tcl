source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl


if {![llength [info commands sanitize_ports]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/io_place_helpers.tcl
}

set ins_raw  [io_port_names [all_inputs]]
set outs_raw [io_port_names [all_outputs]]
set all_raw  [concat $ins_raw $outs_raw]
set pins_all [sanitize_ports $all_raw $all_raw]
set N [llength $pins_all]
set tiered_io [expr {[info exists ::PIN3D_TIERED_IO] && $::PIN3D_TIERED_IO}]

puts [format "IO-INFO: total ports=%d kept=%d" [llength $all_raw] $N]
if {$N == 0} {
  puts "IO-INFO: no signal pins to place."
  return
}

lassign [get_die_bbox] LX_um LY_um UX_um UY_um
set W_um [expr {$UX_um - $LX_um}]
set H_um [expr {$UY_um - $LY_um}]
if {$W_um <= 0 || $H_um <= 0} {
  error "Invalid die size: W=$W_um H=$H_um"
}

set placement_specs {}
set partition_info ""
if {$tiered_io} {
  foreach env_name {
    IO_PLACER_H_UPPER IO_PLACER_V_UPPER
    IO_PLACER_H_BOTTOM IO_PLACER_V_BOTTOM
  } {
    if {![info exists ::env($env_name)] || $::env($env_name) eq ""} {
      error "$env_name must be set for partition-aware 3D IO placement."
    }
  }

  set partition_path [file join $::env(RESULTS_DIR) partition.txt]
  set partition_info [::pin3d_io::partition_ports $partition_path $pins_all]
  lappend placement_specs [dict create \
    label upper \
    pins [dict get $partition_info upper_pins] \
    hor_layer $::env(IO_PLACER_H_UPPER) \
    ver_layer $::env(IO_PLACER_V_UPPER)]
  lappend placement_specs [dict create \
    label bottom \
    pins [dict get $partition_info bottom_pins] \
    hor_layer $::env(IO_PLACER_H_BOTTOM) \
    ver_layer $::env(IO_PLACER_V_BOTTOM)]
} else {
  lappend placement_specs [dict create \
    label all \
    pins $pins_all \
    hor_layer $LAYER_H \
    ver_layer $LAYER_V]
}

# In OpenROAD edge placement, the effective legal pin-to-pin pitch on our
# boundary layers is two routing tracks. This matches the generated
# io_pin_placement.txt files and the official pin-placer definition where the
# default min distance is two routing tracks. Keep the script aligned to that
# model instead of using a die-percentage heuristic.
set min_tracks 2
set corner_margin_um 0.0
set enriched_specs {}
foreach spec $placement_specs {
  set layer_h [dict get $spec hor_layer]
  set layer_v [dict get $spec ver_layer]
  set pitch_h_um [_io_layer_pitch_um $layer_h]
  set pitch_v_um [_io_layer_pitch_um $layer_v]
  set width_h_um [_io_layer_width_um $layer_h]
  set width_v_um [_io_layer_width_um $layer_v]
  set base_step_h_um [expr {2.0 * $pitch_h_um}]
  set base_step_v_um [expr {2.0 * $pitch_v_um}]
  set tier_margin_um [expr {max($base_step_h_um, $base_step_v_um)}]
  if {$tier_margin_um > $corner_margin_um} {
    set corner_margin_um $tier_margin_um
  }
  dict set spec pitch_h_um $pitch_h_um
  dict set spec pitch_v_um $pitch_v_um
  dict set spec width_h_um $width_h_um
  dict set spec width_v_um $width_v_um
  dict set spec base_step_h_um $base_step_h_um
  dict set spec base_step_v_um $base_step_v_um
  lappend enriched_specs $spec
}
set placement_specs $enriched_specs

# Keep the corner margin tied to the physical pin shape size, not a percentage
# of the die. This avoids over-pruning small designs while still reserving one
# legal pin footprint from each corner.
set edge_h_interval [list [list $corner_margin_um [expr {$W_um - $corner_margin_um}]]]
set edge_v_interval [list [list $corner_margin_um [expr {$H_um - $corner_margin_um}]]]

clear_io_pin_constraints

puts [format "IO-DIE(um): W=%.6f H=%.6f corner_margin=%.6f" \
  $W_um $H_um $corner_margin_um]
foreach spec $placement_specs {
  set label [dict get $spec label]
  set layer_h [dict get $spec hor_layer]
  set layer_v [dict get $spec ver_layer]
  set pitch_h_um [dict get $spec pitch_h_um]
  set pitch_v_um [dict get $spec pitch_v_um]
  set width_h_um [dict get $spec width_h_um]
  set width_v_um [dict get $spec width_v_um]
  set base_step_h_um [dict get $spec base_step_h_um]
  set base_step_v_um [dict get $spec base_step_v_um]
  set pin_count [llength [dict get $spec pins]]

  set gross_slots_bottom [_edge_capacity_from_intervals_um $edge_h_interval $base_step_h_um]
  set gross_slots_top $gross_slots_bottom
  set gross_slots_left [_edge_capacity_from_intervals_um $edge_v_interval $base_step_v_um]
  set gross_slots_right $gross_slots_left
  set gross_total_slots [expr {$gross_slots_bottom + $gross_slots_top + $gross_slots_left + $gross_slots_right}]

  set min_dist_h_um [expr {$min_tracks * $pitch_h_um}]
  set min_dist_v_um [expr {$min_tracks * $pitch_v_um}]
  set chosen_capacity_bottom [_edge_capacity_from_intervals_um $edge_h_interval $min_dist_h_um]
  set chosen_capacity_top $chosen_capacity_bottom
  set chosen_capacity_left [_edge_capacity_from_intervals_um $edge_v_interval $min_dist_v_um]
  set chosen_capacity_right $chosen_capacity_left
  set chosen_capacity [expr {
    $chosen_capacity_bottom +
    $chosen_capacity_top +
    $chosen_capacity_left +
    $chosen_capacity_right
  }]

  puts [format {IO-LAYERS[%s]: top_bottom=%s pitch=%.6f width=%.6f | left_right=%s pitch=%.6f width=%.6f} \
    $label $layer_h $pitch_h_um $width_h_um $layer_v $pitch_v_um $width_v_um]
  puts [format {IO-CAPACITY[%s](gross_slots): top=%d bottom=%d left=%d right=%d total=%d pins=%d} \
    $label $gross_slots_top $gross_slots_bottom $gross_slots_left $gross_slots_right $gross_total_slots $pin_count]
  puts [format {IO-SPACING[%s]: base_step_h=%.6f base_step_v=%.6f min_dist_tracks=%d min_dist_h=%.6f min_dist_v=%.6f chosen_capacity=%d} \
    $label $base_step_h_um $base_step_v_um $min_tracks $min_dist_h_um $min_dist_v_um $chosen_capacity]

  if {$chosen_capacity < $pin_count} {
    error [format {IO capacity is insufficient for %s tier: capacity=%d pins=%d} \
      $label $chosen_capacity $pin_count]
  }
}

set pin_dump [file join $::env(LOG_DIR) "io_pin_placement.txt"]
if {$tiered_io} {
  # Bottom first preserves the legacy priority while each tier is optimized
  # independently on its own mirrored routing stack.
  ::pin3d_io::place_subset bottom \
    [dict get $partition_info bottom_pins] \
    $::env(IO_PLACER_H_BOTTOM) $::env(IO_PLACER_V_BOTTOM) \
    $corner_margin_um $min_tracks
  ::pin3d_io::place_subset upper \
    [dict get $partition_info upper_pins] \
    $::env(IO_PLACER_H_UPPER) $::env(IO_PLACER_V_UPPER) \
    $corner_margin_um $min_tracks

  ::pin3d_io::set_pin_status $pins_all PLACED
  write_pin_placement $pin_dump
  set tier_report [file join $::env(LOG_DIR) "io_pin_tiers.rpt"]
  ::pin3d_io::verify_and_report $partition_info \
    [list $::env(IO_PLACER_H_UPPER) $::env(IO_PLACER_V_UPPER)] \
    [list $::env(IO_PLACER_H_BOTTOM) $::env(IO_PLACER_V_BOTTOM)] \
    $tier_report
  puts "FINAL: deterministic 3D IO pins placed on TritonPart-assigned tiers."
} else {
  log_cmd place_pins \
    -hor_layers $LAYER_H \
    -ver_layers $LAYER_V \
    -corner_avoidance $corner_margin_um \
    -min_distance $min_tracks \
    -min_distance_in_tracks \
    -write_pin_placement $pin_dump

  puts "FINAL: deterministic IO pins placed without side-order constraints."
}
