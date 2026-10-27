# True-3D CTS dirty-only tier legalization.
#
# Run once with the owner CORE view and once with the receive CORE view.  All
# clean instances and the inactive tier are FIRM; only the active tier's CTS
# geometry mutations are released to OpenDP.  The receive pass publishes the
# canonical 4_cts handoff.

utl::set_metrics_stage "cts_3d_finalize__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

foreach required_env {
  RESULTS_DIR REPORTS_DIR CTS3D_WORK_DIR
  CTS3D_LEGALIZE_INPUT_DEF CTS3D_LEGALIZE_OUTPUT_DEF
  CTS3D_LEGALIZE_DIRTY_FILE CTS3D_ACTIVE_TIER CTS3D_WRITE_CANONICAL
} {
  if {![info exists ::env($required_env)] || $::env($required_env) eq ""} {
    error "3DCTS tier finalizer requires environment variable $required_env"
  }
}

set active_tier $::env(CTS3D_ACTIVE_TIER)
if {$active_tier ne "bottom" && $active_tier ne "upper"} {
  error "3DCTS tier finalizer received unsupported ACTIVE_TIER '$active_tier'"
}
if {$::env(CTS3D_WRITE_CANONICAL) ne "0" && $::env(CTS3D_WRITE_CANONICAL) ne "1"} {
  error "CTS3D_WRITE_CANONICAL must be 0 or 1"
}

set input_def $::env(CTS3D_LEGALIZE_INPUT_DEF)
set output_def $::env(CTS3D_LEGALIZE_OUTPUT_DEF)
set dirty_file $::env(CTS3D_LEGALIZE_DIRTY_FILE)
set raw_sdc [file join $::env(RESULTS_DIR) 4_cts_3d_raw.sdc]
foreach input [list $input_def $raw_sdc $dirty_file] {
  if {![file isfile $input] || [file size $input] == 0} {
    error "3DCTS tier finalizer input is missing or empty: $input"
  }
}
if {[file normalize $input_def] eq [file normalize $output_def]} {
  error "3DCTS tier finalizer input and output DEF must differ: $input_def"
}

load_design $input_def $raw_sdc "True-3D CTS $active_tier-tier legalization"
set block [ord::get_db_block]
if {$block eq "" || $block eq "NULL"} {
  error "3DCTS tier finalizer loaded no design block"
}

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set site_env [expr {$active_tier eq "upper" ? "UPPER_SITE" : "BOTTOM_SITE"}]
if {![info exists ::env($site_env)] || $::env($site_env) eq ""} {
  error "3DCTS tier finalizer requires $site_env for $active_tier-tier legalization"
}
set active_site $::env($site_env)
or_rebuild_rows_for_site $active_site $active_tier
puts "CTS3D_ROW_REBUILD tier=$active_tier site=$active_site"

unset -nocomplain ::cts3d_dirty_tier ::cts3d_dirty_count ::cts3d_dirty_cells
source $dirty_file
foreach variable {cts3d_dirty_tier cts3d_dirty_count cts3d_dirty_cells} {
  if {![info exists ::$variable]} {
    error "3DCTS dirty-list file did not define ::$variable: $dirty_file"
  }
}
if {$::cts3d_dirty_tier ne $active_tier} {
  error "3DCTS dirty-list tier '$::cts3d_dirty_tier' does not match active tier '$active_tier'"
}
if {$::cts3d_dirty_count != [llength $::cts3d_dirty_cells]} {
  error "3DCTS dirty-list count mismatch for $active_tier"
}
if {[llength [lsort -unique $::cts3d_dirty_cells]] != [llength $::cts3d_dirty_cells]} {
  error "3DCTS dirty-list contains duplicate instance names for $active_tier"
}

set prior_status [dict create]
foreach inst [$block getInsts] {
  dict set prior_status [$inst getName] [$inst getPlacementStatus]
  $inst setPlacementStatus FIRM
}

set released 0
foreach name $::cts3d_dirty_cells {
  set inst [$block findInst $name]
  if {$inst eq "" || $inst eq "NULL"} {
    error "3DCTS dirty instance is absent from current DEF: $name"
  }
  set master [$inst getMaster]
  set master_name [$master getName]
  if {![string match "*_${active_tier}" $master_name]} {
    error "3DCTS dirty instance $name uses master $master_name, not tier $active_tier"
  }
  if {[$master getType] ne "CORE"} {
    error "3DCTS dirty instance $name is not CORE in the $active_tier view: $master_name type=[$master getType]"
  }
  $inst setPlacementStatus PLACED
  incr released
}
if {$released != $::cts3d_dirty_count} {
  error "3DCTS released $released cells but expected $::cts3d_dirty_count for $active_tier"
}

puts "CTS3D_LEGALIZE_BEGIN tier=$active_tier requested=$::cts3d_dirty_count released=$released"
if {$released > 0} {
  if {[catch {detailed_placement} placement_error]} {
    error "3DCTS detailed placement failed for $active_tier: $placement_error"
  }
}

foreach inst [$block getInsts] {
  set name [$inst getName]
  if {![dict exists $prior_status $name]} {
    error "3DCTS tier finalizer observed unexpected new instance: $name"
  }
  $inst setPlacementStatus [dict get $prior_status $name]
}

file mkdir [file dirname $output_def]
write_def $output_def
if {![file isfile $output_def] || [file size $output_def] == 0} {
  error "3DCTS tier finalizer failed to write output DEF: $output_def"
}

if {$::env(CTS3D_WRITE_CANONICAL)} {
  set canonical_def [file join $::env(RESULTS_DIR) 4_cts.def]
  if {[file normalize $output_def] ne [file normalize $canonical_def]} {
    error "3DCTS canonical receive pass must write $canonical_def, got $output_def"
  }

  write_db [file join $::env(RESULTS_DIR) 4_cts.odb]
  write_verilog [file join $::env(RESULTS_DIR) 4_cts.v]
  write_sdc [file join $::env(RESULTS_DIR) 4_cts.sdc]
  foreach canonical_name {4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc} {
    set canonical_path [file join $::env(RESULTS_DIR) $canonical_name]
    if {![file isfile $canonical_path] || [file size $canonical_path] == 0} {
      error "3DCTS failed to write non-empty canonical handoff: $canonical_path"
    }
  }

  estimate_parasitics -placement
  set_propagated_clock [all_clocks]
  set timing_report [file join $::env(REPORTS_DIR) 4_cts_timing.rpt]
  report_checks -path_delay max -slack_max 0 -group_count 10 > $timing_report
  report_checks -path_delay min -slack_max 0 -group_count 10 >> $timing_report
  set stream [open $timing_report a]
  puts $stream "\n========== Summary =========="
  puts $stream [format "setup_tns %.2f ps" [expr {[sta::total_negative_slack_cmd "max"] * 1e12}]]
  puts $stream [format "setup_wns %.2f ps" [expr {[sta::worst_slack_cmd "max"] * 1e12}]]
  puts $stream [format "hold_tns  %.2f ps" [expr {[sta::total_negative_slack_cmd "min"] * 1e12}]]
  puts $stream [format "hold_wns  %.2f ps" [expr {[sta::worst_slack_cmd "min"] * 1e12}]]
  close $stream
}

puts "CTS3D_LEGALIZE_PASS tier=$active_tier released=$released canonical=$::env(CTS3D_WRITE_CANONICAL) output=$output_def"
exit
