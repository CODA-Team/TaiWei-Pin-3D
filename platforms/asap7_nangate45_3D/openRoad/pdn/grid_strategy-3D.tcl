############################################################
# pdn_hetero_two_pass_bottom_nangate_top_asap7.tcl
#
# Heterogeneous 3D PDN in OpenROAD/pdngen (two-pass, with row rebuild):
#
# PASS-1 (BOTTOM die / Nangate45-style):
#   - Rebuild rows to BOTTOM_SITE
#   - BOT global_connect
#   - Core (forced name) = BOT_VDD/BOT_VSS
#   - BOT grid: M1 (followpins) + M4 (vertical) + M7 (horizontal)
#   - pdngen
#
# PASS-2 (TOP die / ASAP7-style):
#   - Rebuild rows to UPPER_SITE
#   - Append TOP global_connect (do NOT clear BOT rules)
#   - Core (forced name, replaces previous) = TOP_VDD/TOP_VSS
#   - TOP grid: M1_m/M2_m (followpins) + M3_m (vertical) + M6_m (horizontal)
#   - pdngen
#
# Notes:
# - Many OpenROAD builds force the core voltage domain name to "Core" (PDN-1042),
#   so we always use -name {Core}.
# - Between passes we try to reset pdngen "definitions" (NOT shapes). If your
#   build lacks reset support, PASS-2 may duplicate PASS-1 shapes; then do two
#   separate OpenROAD runs (write_def/restart).
############################################################

puts "INFO: Start..."

# ==========================================================
# Helpers
# ==========================================================

proc get_row_height_um {{fallback 0.27}} {
  # Return row height (um) based on the first row's site after row rebuild.
  if {[catch {set block [ord::get_db_block]}]} { return $fallback }
  set rows [$block getRows]
  if {[llength $rows] == 0} { return $fallback }

  set r [lindex $rows 0]
  if {[catch {set site [$r getSite]}]} { return $fallback }
  if {$site eq "" || $site eq "NULL"} { return $fallback }

  if {[catch {set h_dbu [$site getHeight]}]} { return $fallback }
  if {$h_dbu <= 0} { return $fallback }

  return [ord::dbu_to_microns $h_dbu]
}

proc pdngen_reset_config {} {
  # Reset/clear PDN definitions (NOT shapes) between passes (version-dependent).
  if {[llength [info commands pdngen]]} {
    if {![catch {pdngen -reset}]} { puts "INFO: pdngen_reset_config: used 'pdngen -reset'."; return 1 }
    if {![catch {pdngen -clear}]} { puts "INFO: pdngen_reset_config: used 'pdngen -clear'."; return 1 }
  }
  foreach cmd {reset_pdn clear_pdn pdn_reset pdn_clear} {
    if {[llength [info commands $cmd]]} {
      if {![catch {$cmd}]} { puts "INFO: pdngen_reset_config: used '$cmd'."; return 1 }
    }
  }
  puts "WARN: pdngen_reset_config: no reset/clear command available in this build."
  puts "WARN: If PASS-2 duplicates PASS-1 PDN, use two OpenROAD runs (write_def/restart)."
  return 0
}

# ==========================================================
# 1) Rename instances by master suffix (_upper/_bottom)
# ==========================================================

proc is_upper_master {master_name} { expr {[string match "*_upper"  $master_name] ? 1 : 0} }
proc is_bottom_master {master_name} { expr {[string match "*_bottom" $master_name] ? 1 : 0} }

proc rename_upper_bottom_insts {} {
  if {[catch {set block [ord::get_db_block]} err]} {
    puts "ERROR: Failed to get DB block: $err"
    return
  }
  if {$block eq "NULL"} {
    puts "ERROR: No block loaded. Make sure the design is linked."
    return
  }

  puts "INFO: Renaming instances based on upper/bottom masters..."

  set cnt_upper 0
  set cnt_bottom 0
  set cnt_skipped 0

  foreach inst [$block getInsts] {
    set inst_name   [$inst getName]
    set master      [$inst getMaster]
    set master_name [$master getName]

    set is_upper  [is_upper_master  $master_name]
    set is_bottom [is_bottom_master $master_name]

    if {!$is_upper && !$is_bottom} { incr cnt_skipped; continue }

    # Avoid double suffix if sourced multiple times
    if {[string match "*_upper" $inst_name] || [string match "*_bottom" $inst_name]} {
      incr cnt_skipped
      continue
    }

    set new_name [expr {$is_upper ? "${inst_name}_upper" : "${inst_name}_bottom"}]

    # Avoid name conflicts
    set exist_inst [$block findInst $new_name]
    if {$exist_inst ne "NULL" && $exist_inst ne ""} {
      puts "WARNING: Skip renaming $inst_name -> $new_name (name already exists)."
      incr cnt_skipped
      continue
    }

    $inst rename $new_name
    if {$is_upper} { incr cnt_upper } else { incr cnt_bottom }
  }

  puts "INFO: Done renaming upper/bottom instances."
  puts "INFO:  Upper  instances renamed : $cnt_upper"
  puts "INFO:  Bottom instances renamed : $cnt_bottom"
  puts "INFO:  Instances skipped        : $cnt_skipped"
}

rename_upper_bottom_insts

# ==========================================================
# 2) Dynamic pitch calculation (keep your original idea for M4/M7)
# ==========================================================

set core_area_bbox [[odb::get_block] getCoreArea]
set core_llx [$core_area_bbox xMin]
set core_lly [$core_area_bbox yMin]
set core_urx [$core_area_bbox xMax]
set core_ury [$core_area_bbox yMax]

set core_width  [ord::dbu_to_microns [expr {$core_urx - $core_llx}]]
set core_height [ord::dbu_to_microns [expr {$core_ury - $core_lly}]]

puts "INFO: Core Area Width: $core_width, Height: $core_height"

set mfg_grid 0.005

set m4_pitch [expr {$core_width / 1.1}]
if {$m4_pitch > 20.16} { set m4_pitch 20.16 }
set m4_pitch [expr {round($m4_pitch / $mfg_grid) * $mfg_grid}]

set m7_pitch [expr {$core_height / 1.1}]
if {$m7_pitch > 40} { set m7_pitch 40 }
set m7_pitch [expr {round($m7_pitch / $mfg_grid) * $mfg_grid}]

puts "INFO: Dynamic PDN Pitch -> M4: $m4_pitch, M7: $m7_pitch"

# ==========================================================
# PASS-1: BOTTOM die (Nangate45-style PDN)
# ==========================================================

or_rebuild_rows_for_site $::env(BOTTOM_SITE)

# IMPORTANT: followpins pitch should match the rebuilt row height
set bot_rail_pitch [get_row_height_um 1.4]
puts "INFO: PASS-1: Using bottom followpins pitch (row height) = $bot_rail_pitch um"

puts "INFO: PASS-1: Setting up global connections for BOT only..."
clear_global_connect

add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$}   -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$}   -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}

global_connect
puts "INFO: PASS-1: BOT global_connect done."

puts "INFO: PASS-1: Defining voltage domain Core for BOT..."
set_voltage_domain -name {Core} -power {BOT_VDD} -ground {BOT_VSS}
report_voltage_domains

puts "INFO: PASS-1: Defining BOT PDN grid..."
define_pdn_grid -name {BOT} -voltage_domains {Core}

# M1 rails (followpins) -- use row-height pitch to avoid channel-repair failures
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M1} \
  -width  {0.17} \
  -pitch  $bot_rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

# M4 straps (vertical)
add_pdn_stripe \
  -grid      {BOT} \
  -layer     {M4} \
  -width     {0.84} \
  -pitch     $m4_pitch \
  -offset    {0} \
  -nets      {BOT_VDD BOT_VSS}

# M7 straps (horizontal)
add_pdn_stripe \
  -grid      {BOT} \
  -layer     {M7} \
  -width     {1.4} \
  -pitch     $m7_pitch \
  -offset    {2} \
  -nets      {BOT_VDD BOT_VSS}

add_pdn_connect -grid {BOT} -layers {M1 M4}
add_pdn_connect -grid {BOT} -layers {M4 M7}

puts "INFO: PASS-1: Running pdngen for BOT..."
pdngen
puts "INFO: PASS-1: pdngen (BOT) finished."

# ==========================================================
# Reset pdngen definitions between passes (NOT shapes)
# ==========================================================
pdngen_reset_config

# ==========================================================
# PASS-2: TOP die (ASAP7-style PDN)
# ==========================================================

or_rebuild_rows_for_site $::env(UPPER_SITE)

# IMPORTANT: followpins pitch should match the rebuilt row height
set top_rail_pitch [get_row_height_um 0.27]
puts "INFO: PASS-2: Using top followpins pitch (row height) = $top_rail_pitch um"

puts "INFO: PASS-2: Adding global connections for TOP only..."
# Do NOT clear_global_connect here; keep BOT rules
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDD$}   -power
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDPE$}
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDCE$}
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSS$}   -ground
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSSE$}

global_connect
puts "INFO: PASS-2: TOP global_connect done."

puts "INFO: PASS-2: Defining voltage domain Core for TOP (replaces Core)..."
set_voltage_domain -name {Core} -power {TOP_VDD} -ground {TOP_VSS}
report_voltage_domains

puts "INFO: PASS-2: Defining TOP PDN grid..."
define_pdn_grid -name {TOP} -voltage_domains {Core}

# M1_m rails (followpins)
add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M1_m} \
  -width  {0.018} \
  -pitch  $top_rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD TOP_VSS}

# M2_m rails (followpins)
add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M2_m} \
  -width  {0.018} \
  -pitch  $top_rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD TOP_VSS}

# M3_m vertical stripes (align to ASAP7 wide-via rule width = 0.234)
add_pdn_stripe \
  -grid      {TOP} \
  -layer     {M3_m} \
  -width     {0.234} \
  -spacing   {0.072} \
  -pitch     {5.4} \
  -offset    {0.300} \
  -nets      {TOP_VDD TOP_VSS}

# M6_m horizontal straps
add_pdn_stripe \
  -grid      {TOP} \
  -layer     {M6_m} \
  -width     {0.288} \
  -spacing   {0.096} \
  -pitch     {5.4} \
  -offset    {0.513} \
  -nets      {TOP_VDD TOP_VSS}

add_pdn_connect -grid {TOP} -layers {M1_m M2_m}
add_pdn_connect -grid {TOP} -layers {M2_m M3_m}
add_pdn_connect -grid {TOP} -layers {M3_m M6_m}

puts "INFO: PASS-2: Running pdngen for TOP..."
pdngen
puts "INFO: PASS-2: pdngen (TOP) finished."

puts "INFO: Done."
