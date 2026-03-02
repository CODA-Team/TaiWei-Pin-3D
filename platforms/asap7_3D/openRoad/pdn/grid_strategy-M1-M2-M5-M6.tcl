############################################################
# pdn_asap7_3d_two_pass_m12_m3m6_openroad.tcl
#
# Homogeneous ASAP7 3D PDN in OpenROAD/pdngen (two-pass):
#   PASS-1: BOT global_connect + Core + BOT grid + pdngen
#   PASS-2: TOP global_connect + Core + TOP grid + pdngen
#
# Target topology (mirrors Innovus intent):
#   BOT: M1/M2 rails (followpins) + M3 vertical + M6 horizontal
#   TOP: M1_m/M2_m rails (followpins) + M3_m vertical + M6_m horizontal
#
# Notes:
# - This OpenROAD build forces the core voltage domain name to "Core" (PDN-1042).
# - Between passes, we try to reset pdngen config (NOT shapes). If your build
#   lacks reset, PASS-2 may duplicate BOT PDN; then use two separate OpenROAD runs.
############################################################

puts "INFO: Start..."

# ----------------------------------------------------------
# Helper: get row height (microns) for followpins pitch
# ----------------------------------------------------------
proc get_row_height_um {{fallback 0.27}} {
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

# ----------------------------------------------------------
# Helper: reset pdngen definitions between passes (version-dependent)
# ----------------------------------------------------------
proc pdngen_reset_config {} {
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
  puts "WARN: If PASS-2 duplicates BOT PDN, use two OpenROAD runs (write_def/restart)."
  return 0
}

############################################################
# 1) Rename instances by master suffix (_upper/_bottom)
############################################################
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

# ----------------------------------------------------------
# Compute a sane followpins pitch for ASAP7 (row height)
# ----------------------------------------------------------
set rail_pitch [get_row_height_um 0.27]
puts "INFO: Using followpins pitch (row height) = $rail_pitch um"

############################################################
# PASS-1: BOT global_connect + Core + BOT PDN + pdngen
############################################################

puts "INFO: PASS-1: Setting up global connections (BOT only)..."
clear_global_connect

add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$}   -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$}   -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}

global_connect
puts "INFO: PASS-1: BOT global_connect done."

# Core voltage domain (name forced to "Core" in this build)
puts "INFO: PASS-1: Defining voltage domain Core for BOT..."
set_voltage_domain -name {Core} -power {BOT_VDD} -ground {BOT_VSS}
report_voltage_domains

puts "INFO: PASS-1: Defining BOT PDN grid (M1/M2 rails + M3(V) + M6(H))..."
define_pdn_grid -name {BOT} -voltage_domains {Core}

# M1 rails (followpins) -- use ASAP7 rail width and row pitch
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M1} \
  -width  {0.018} \
  -pitch  $rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

# M2 rails (followpins) -- mirrors Innovus “duplicate rails to M2”
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M2} \
  -width  {0.018} \
  -pitch  $rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

# M3 vertical stripes (width aligned to your VIARULE: WIDTH 0.234 TO 0.234)
add_pdn_stripe \
  -grid      {BOT} \
  -layer     {M3} \
  -width     {0.234} \
  -spacing   {0.072} \
  -pitch     {5.4} \
  -offset    {0.300} \
  -nets      {BOT_VDD BOT_VSS}

# M6 horizontal straps
add_pdn_stripe \
  -grid      {BOT} \
  -layer     {M6} \
  -width     {0.288} \
  -spacing   {0.096} \
  -pitch     {5.4} \
  -offset    {0.513} \
  -nets      {BOT_VDD BOT_VSS}

# Connect stack: M1<->M2<->M3<->M6
add_pdn_connect -grid {BOT} -layers {M1 M2}
add_pdn_connect -grid {BOT} -layers {M2 M3}
add_pdn_connect -grid {BOT} -layers {M3 M6}

puts "INFO: PASS-1: Running pdngen (BOT)..."
pdngen
puts "INFO: PASS-1: pdngen (BOT) finished."

############################################################
# Reset pdngen definitions between passes (NOT shapes)
############################################################
pdngen_reset_config

############################################################
# PASS-2: TOP global_connect + Core + TOP PDN + pdngen
############################################################

puts "INFO: PASS-2: Appending global connections (TOP only)..."
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

puts "INFO: PASS-2: Defining TOP PDN grid (M1_m/M2_m rails + M3_m(V) + M6_m(H))..."
define_pdn_grid -name {TOP} -voltage_domains {Core}

add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M1_m} \
  -width  {0.018} \
  -pitch  $rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD TOP_VSS}

add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M2_m} \
  -width  {0.018} \
  -pitch  $rail_pitch \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD TOP_VSS}

add_pdn_stripe \
  -grid      {TOP} \
  -layer     {M3_m} \
  -width     {0.234} \
  -spacing   {0.072} \
  -pitch     {5.4} \
  -offset    {0.300} \
  -nets      {TOP_VDD TOP_VSS}

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

puts "INFO: PASS-2: Running pdngen (TOP)..."
pdngen
puts "INFO: PASS-2: pdngen (TOP) finished."

puts "INFO: Done."
