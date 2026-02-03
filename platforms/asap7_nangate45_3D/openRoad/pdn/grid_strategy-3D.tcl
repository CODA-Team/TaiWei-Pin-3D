############################################################
# Part 1: rename + BOT global_connect + CoreBOT + BOT PDN
############################################################

# ==== 1. rename upper/bottom inst ====

proc is_upper_master {master_name} {
  expr {[string match "*_upper" $master_name] ? 1 : 0}
}

proc is_bottom_master {master_name} {
  expr {[string match "*_bottom" $master_name] ? 1 : 0}
}

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

  set cnt_upper   0
  set cnt_bottom  0
  set cnt_skipped 0

  foreach inst [$block getInsts] {
    set inst_name   [$inst getName]
    set master      [$inst getMaster]
    set master_name [$master getName]

    set is_upper  [is_upper_master  $master_name]
    set is_bottom [is_bottom_master $master_name]

    if {!$is_upper && !$is_bottom} {
      incr cnt_skipped
      continue
    }

    if {[string match "*_upper" $inst_name] || [string match "*_bottom" $inst_name]} {
      incr cnt_skipped
      continue
    }

    if {$is_upper} {
      set new_name "${inst_name}_upper"
    } else {
      set new_name "${inst_name}_bottom"
    }

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

# ==== 2. 只设置 BOT 的 global_connect ====

puts "INFO: Setting up global connections for BOT only..."

clear_global_connect

add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$}   -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$}   -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}

global_connect
puts "INFO: BOT global_connect done."

# ==== 3. 只为 BOT 建一个 voltage domain（无 secondary_power）====

puts "INFO: Defining PDN voltage domain 'CoreBOT'..."

####################################
# Dynamic Pitch Calculation
####################################

set core_area_bbox   [[odb::get_block] getCoreArea]

set core_llx [$core_area_bbox xMin]
set core_lly [$core_area_bbox yMin]
set core_urx [$core_area_bbox xMax]
set core_ury [$core_area_bbox yMax]

set core_width  [ord::dbu_to_microns [expr $core_urx - $core_llx]]
set core_height [ord::dbu_to_microns [expr $core_ury - $core_lly]]

puts "INFO: Core Area Width: $core_width, Height: $core_height"

set mfg_grid 0.005

set m4_pitch [expr {$core_width / 1.1}]
if {$m4_pitch > 20.16} {
    set m4_pitch 20.16
}
set m4_pitch [expr {round($m4_pitch / $mfg_grid) * $mfg_grid}]

set m7_pitch [expr {$core_height / 1.1}]
if {$m7_pitch > 40} {
    set m7_pitch 40
}
set m7_pitch [expr {round($m7_pitch / $mfg_grid) * $mfg_grid}]

puts "INFO: Dynamic PDN Pitch -> M4: $m4_pitch, M7: $m7_pitch"

set_voltage_domain -name {Core} \
                   -power  {BOT_VDD} \
                   -ground {BOT_VSS}

report_voltage_domains

# ==== 4. BOT PDN grid + 第一次 pdngen ====

puts "INFO: Defining 'BOT' PDN grid..."

define_pdn_grid -name {BOT} -voltage_domains {Core}

# std-cell rails on M1
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M1} \
  -width  {0.17} \
  -pitch  {2.8} \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

# mesh on M4
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M4} \
  -width  {0.84} \
  -pitch  $m4_pitch \
  -offset {0} \
  -nets   {BOT_VDD BOT_VSS}

# mesh on M7
add_pdn_stripe \
  -grid    {BOT} \
  -layer   {M7} \
  -width   {1.4} \
  -pitch   $m7_pitch \
  -offset  {2} \
  -nets    {BOT_VDD BOT_VSS}

add_pdn_connect -grid {BOT} -layers {M1 M4}
add_pdn_connect -grid {BOT} -layers {M4 M7}

puts "INFO: Running pdngen for BOT..."
pdngen
puts "INFO: pdngen(BOT) finished."

############################################################
# Part 2: rebuild upper rows + TOP global_connect + CoreTOP + TOP PDN
############################################################

# 1) 重建 upper tier 的 rows
if {![info exists ::env(UPPER_SITE)]} {
  puts "ERROR: UPPER_SITE env var not set. Please export UPPER_SITE."
  return
}

puts "INFO: Rebuilding rows for upper tier site = $::env(UPPER_SITE)"
or_rebuild_rows_for_site $::env(UPPER_SITE)

# 2) 再追加 TOP 的 global_connect（不 clear，让 BOT 的规则保留）

puts "INFO: Adding global connections for TOP only..."

# 注意：这里不要 clear_global_connect，否则会把 BOT 的规则清掉
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDD$}   -power
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDPE$}
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDCE$}
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSS$}   -ground
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSSE$}

global_connect
puts "INFO: TOP global_connect done."

# 3) 给 TOP 单独建一个 voltage domain（没有 secondary_power）

puts "INFO: Defining PDN voltage domain 'CoreTOP'..."

# ground 你有两种选择：
#   a) top/bottom 共用地：  -ground {BOT_VSS}
#   b) 分开的地网：        -ground {TOP_VSS}
# 下面示例用共用地（和你原来 TOP PDN nets {TOP_VDD BOT_VSS} 一致）：

set_voltage_domain -name {Core} \
                   -power  {TOP_VDD} \
                   -ground {BOT_VSS}

report_voltage_domains

# 4) TOP PDN grid + 第二次 pdngen

puts "INFO: Defining 'TOP' PDN grid..."

define_pdn_grid -name {TOP} -voltage_domains {Core}

# std-cell rails on mirrored metals M1_m / M2_m
add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M1_m} \
  -width  {0.018} \
  -pitch  {0.54} \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD BOT_VSS}

add_pdn_stripe \
  -grid   {TOP} \
  -layer  {M2_m} \
  -width  {0.018} \
  -pitch  {0.54} \
  -offset {0} \
  -followpins \
  -nets   {TOP_VDD BOT_VSS}

# mesh on M5_m / M6_m
add_pdn_stripe \
  -grid    {TOP} \
  -layer   {M5_m} \
  -width   {0.12} \
  -spacing {0.072} \
  -pitch   {5.4} \
  -offset  {0.300} \
  -nets    {TOP_VDD BOT_VSS}

add_pdn_stripe \
  -grid    {TOP} \
  -layer   {M6_m} \
  -width   {0.288} \
  -spacing {0.096} \
  -pitch   {5.4} \
  -offset  {0.513} \
  -nets    {TOP_VDD BOT_VSS}

add_pdn_connect -grid {TOP} -layers {M1_m M2_m}
add_pdn_connect -grid {TOP} -layers {M2_m M5_m}
add_pdn_connect -grid {TOP} -layers {M5_m M6_m}

puts "INFO: Running pdngen for TOP..."
pdngen
puts "INFO: pdngen(TOP) finished."
