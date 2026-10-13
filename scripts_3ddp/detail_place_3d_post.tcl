# Non-placement post-processing shared with the baseline DP flow.

# The generic Pin3D metric policy defaults to "off" because a full net list can
# be expensive.  A 3D-DP run needs the aggregate counts as a regression audit,
# so enable the lightweight summary mode unless the caller explicitly chose a
# mode (including "off").  This only controls report generation.
if {![info exists ::env(PIN3D_METRIC_REPORT_MODE)]
    || $::env(PIN3D_METRIC_REPORT_MODE) eq ""} {
  set ::env(PIN3D_METRIC_REPORT_MODE) "summary"
}

proc 3d_dp_capture_audit {log_dir} {
  set paths [dict create \
    cross_before [file join $log_dir "3d_dp.cross_tier.before.nets"] \
    cross_after [file join $log_dir "3d_dp.cross_tier.after.nets"] \
    cross_summary [file join $log_dir "3d_dp.cross_tier.summary.rpt"] \
    mixed_before [file join $log_dir "3d_dp.mixed_fanout.before.nets"] \
    mixed_after [file join $log_dir "3d_dp.mixed_fanout.after.nets"] \
    mixed_summary [file join $log_dir "3d_dp.mixed_fanout.summary.rpt"] \
    split_before [file join $log_dir "3d_dp.split.before.rpt"] \
    split_after [file join $log_dir "3d_dp.split.after.rpt"] \
    split_summary [file join $log_dir "3d_dp.split.summary.rpt"] \
    attribution [file join $log_dir "3d_dp.cross_tier.delta.rpt"]]

  report_cross_tier_snapshot [dict get $paths cross_before] -label "3d_dp before"
  report_mixed_fanout_snapshot [dict get $paths mixed_before] -label "3d_dp before"
  report_split_structure_snapshot [dict get $paths split_before] -label "3d_dp before"
  return $paths
}

proc 3d_dp_run_postprocess {paths} {
  # This updates parasitics and audit artifacts without invoking another
  # placement algorithm or moving the 3D DP result.
  estimate_parasitics -placement
  pin3d_metrics_invalidate_cache
  report_cross_tier_transition \
    [dict get $paths cross_summary] \
    [dict get $paths cross_before] \
    [dict get $paths cross_after] \
    -label "3d_dp"
  report_mixed_fanout_transition \
    [dict get $paths mixed_summary] \
    [dict get $paths mixed_before] \
    [dict get $paths mixed_after] \
    -label "3d_dp"
  report_split_structure_transition \
    [dict get $paths split_summary] \
    [dict get $paths split_before] \
    [dict get $paths split_after] \
    -label "3d_dp"
  report_cross_tier_delta_attribution \
    [dict get $paths attribution] \
    [dict get $paths cross_before] \
    [dict get $paths cross_after] \
    -label "3d_dp"
}
