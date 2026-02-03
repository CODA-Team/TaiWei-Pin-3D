# ------------------------------------------------------------
# 1) helpers: dbu + instance area + tier classification
# ------------------------------------------------------------
proc _get_dbu {} {
  set db [ord::get_db]
  if {$db eq "NULL"} { utl::error FP 110 "No db." }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} { utl::error FP 111 "No tech." }
  return [odb::dbTech_getDbUnitsPerMicron $tech]
}

proc _inst_area_um2 {inst dbu} {
  set master [odb::dbInst_getMaster $inst]
  if {$master eq "NULL"} { return 0.0 }
  set w [odb::dbMaster_getWidth  $master]
  set h [odb::dbMaster_getHeight $master]
  return [expr {double($w) * double($h) / double($dbu*$dbu)}]
}

# tier 判定优先级：
#   1) inst 上有 partition_id（你 partition 脚本里就是这么写的）
#      - 约定 pid==0 => upper, pid==1 => bottom（与你 calc_upper_bottom_size 一致）
#   2) master name 后缀 *_upper / *_bottom
#   3) inst name 后缀 *_upper / *_bottom
proc _classify_tier {inst} {
  # (1) property partition_id
  set prop [odb::dbIntProperty_find $inst "partition_id"]
  if {$prop ne "NULL"} {
    set pid [odb::dbIntProperty_getValue $prop]
    if {$pid == 0} { return "upper" }
    if {$pid == 1} { return "bottom" }
  }

  # (2) master suffix
  set master [odb::dbInst_getMaster $inst]
  if {$master ne "NULL"} {
    set mname [odb::dbMaster_getName $master]
    if {[string match "*_upper"  $mname]}  { return "upper" }
    if {[string match "*_bottom" $mname]}  { return "bottom" }
  }

  # (3) inst suffix
  set iname [odb::dbInst_getName $inst]
  if {[string match "*_upper"  $iname]}  { return "upper" }
  if {[string match "*_bottom" $iname]}  { return "bottom" }

  return ""
}

# return: {A_upper A_bottom cnt_upper cnt_bottom method}
proc get_tier_areas_um2 {} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} { utl::error FP 120 "No db block." }

  set dbu [_get_dbu]

  set A_up  0.0
  set A_bot 0.0
  set C_up  0
  set C_bot 0

  set saw_prop 0
  foreach inst [odb::dbBlock_getInsts $block] {
    # 先探测有没有 partition_id（用于报告 method）
    if {!$saw_prop} {
      set p [odb::dbIntProperty_find $inst "partition_id"]
      if {$p ne "NULL"} { set saw_prop 1 }
    }

    set t [_classify_tier $inst]
    if {$t eq ""} { continue }

    set a [_inst_area_um2 $inst $dbu]
    if {$t eq "upper"} {
      set A_up [expr {$A_up + $a}]
      incr C_up
    } else {
      set A_bot [expr {$A_bot + $a}]
      incr C_bot
    }
  }

  set method "suffix"
  if {$saw_prop} { set method "partition_id" }

  return [list $A_up $A_bot $C_up $C_bot $method]
}