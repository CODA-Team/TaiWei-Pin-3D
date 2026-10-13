proc 3d_dp_env_or_default {name default_value} {
  if {[info exists ::env($name)] && $::env($name) ne ""} {
    return $::env($name)
  }
  return $default_value
}

# Keep the 3D-DP handoff private to this plugin.  The shared handoff registry
# remains unchanged, while the standard 3_place.* output contract is preserved.
proc detail_place_3d_stage_paths {results_dir objects_dir log_dir} {
  return [_handoff_stage_dict detail-place-3d "ord-detail-place-3d" \
    $results_dir $objects_dir $log_dir [dict create \
      def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
      v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
      sdc_in [file join $results_dir "2_floorplan.sdc"] \
      def_out [file join $results_dir "3_place.def"] \
      v_out [file join $results_dir "3_place.v"] \
      sdc_out [file join $results_dir "3_place.sdc"] \
      image_out [file join $log_dir "3_detail_place_3d.webp"]]]
}

proc 3d_dp_resolve_config {} {
  set tech [3d_dp_env_or_default PLATFORM ""]
  set supported_techs {
    asap7_3D
    nangate45_3D
    asap7_nangate45_3D
    nangate45_asap7_3D
  }
  if {[lsearch -exact $supported_techs $tech] < 0} {
    error "3d_dp: unsupported PLATFORM '$tech'"
  }

  set max_displacement [3d_dp_env_or_default DP_3D_MAX_DISPLACEMENT {5 1}]
  if {[llength $max_displacement] != 2} {
    error "3d_dp: DP_3D_MAX_DISPLACEMENT must contain two micron values"
  }

  set margin [3d_dp_env_or_default DP_3D_MARGIN \
    [3d_dp_env_or_default CORE_MARGIN 0.2]]
  set hbt_max_core_utilization [3d_dp_env_or_default HBT_MAX_CORE_UTILIZATION 0.8]
  set hbt_source_lef [3d_dp_env_or_default TECH_LEF ""]
  if {$hbt_source_lef eq ""} {
    error "3d_dp: TECH_LEF is required to read hb_layer rules"
  }
  return [dict create \
    tech $tech \
    max_displacement $max_displacement \
    margin $margin \
    hbt_max_core_utilization $hbt_max_core_utilization \
    hbt_source_lef $hbt_source_lef]
}
