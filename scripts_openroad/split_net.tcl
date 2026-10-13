# ============================================================
# OpenROAD Tcl
# File: split_net.tcl
# Dual-boundary-buffer split pass for mixed-fanout cross-tier signal nets.
#
# Each crossing net is normalized into three independent segments:
#   driver -> original_net -> same-tier sinks + source buffer input
#   source buffer -> bridge_net -> destination buffer
#   destination buffer -> branch_net -> opposite-tier sinks
#
# Pure crossing nets, whose sinks are all on the opposite die, are left
# untouched by default to avoid adding two buffer stages without isolating any
# same-tier load.  The middle bridge net is the only cross-tier segment for
# nets selected by this pass.  Both boundary cells use ordinary 1-input/1-output
# buffers and are protected from later topology rewriting; ordinary upper/bottom
# repair passes remain free to build their own local buffer trees on original_net
# and branch_net.
# ============================================================

if {![llength [info commands _or_bterm_tier]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
}

namespace eval ::tier_split_or2 {
  variable CFG
  variable NAME_SET
  variable MASTER_LOOKUP
  variable BUFFER_MASTER_CHOICES
  variable INST_TIER_CACHE
  variable ITERM_TIER_CACHE
  variable BTERM_TIER_CACHE
  variable TIER_UTILIZATION
  array set CFG {
    split_y_um               0.0
    use_bbox_split           1
    dry_run                  1
    report_file              tier_split_buffer_openroad.rpt
    manifest_file            {}
    dump_cell_tier           0
    dump_pin_tier            0
    log_skip_details         0

    upper_inst_re            {}
    lower_inst_re            {}
    upper_pin_re             {}
    lower_pin_re             {}

    upper_master_re          {_upper$}
    lower_master_re          {_bottom$|_lower$}

    buffer_master_upper_re   {}
    buffer_master_lower_re   {}

    buffer_inst_suffix       __SPLITBUF__
    source_buffer_suffix     __SPLITBUF__SRC
    destination_buffer_suffix __SPLITBUF__DST
    bridge_net_suffix        __BRIDGE
    branch_net_suffix        __BRANCH

    require_both_sink_tiers  1
    skip_port_driven_nets    1
    skip_clock_nets          1
    util_safe                0.60
    util_alpha               12.0
    util_weight              1.0
    hbt_weight               2.5
    area_weight              400.0
    high_util_forbid         0.8
    near_tie_ratio           0.05
  }
  array set NAME_SET {}
  array set MASTER_LOOKUP {}
  array set BUFFER_MASTER_CHOICES {}
  array set INST_TIER_CACHE {}
  array set ITERM_TIER_CACHE {}
  array set BTERM_TIER_CACHE {}
  set TIER_UTILIZATION {}
}


if {![llength [info commands ::tier_split_or2::run]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/split_net_impl.tcl
}
