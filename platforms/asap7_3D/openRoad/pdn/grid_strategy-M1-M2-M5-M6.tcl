############################################################
# 0. Preconditions
# ----------------------------------------------------------
# - Tech LEF / Cell LEF / Liberty / Verilog 已读入
# - Design 已经 link 且 floorplan 已经初始化
# - Standard cells:
#     * bottom-die masters: name contains "_bottom"
#     * upper-die  masters: name contains "_upper"
############################################################

############################################################
# 1. Rename instances for upper / bottom tiers
############################################################

# Helper proc: check if a master name should be treated as "upper"
proc is_upper_master {master_name} {
  # Rule: master name contains "_upper" suffix
  if {[string match "*_upper" $master_name]} {
    return 1
  }
  return 0
}

# Helper proc: check if a master name should be treated as "bottom"
proc is_bottom_master {master_name} {
  # Rule: master name contains "_bottom" suffix
  if {[string match "*_bottom" $master_name]} {
    return 1
  }
  return 0
}

proc rename_upper_bottom_insts {} {
  # Get current db block
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

    # Avoid double suffix if script is sourced multiple times
    if {[string match "*_upper" $inst_name] || [string match "*_bottom" $inst_name]} {
      incr cnt_skipped
      continue
    }

    if {$is_upper} {
      set new_name "${inst_name}_upper"
    } else {
      set new_name "${inst_name}_bottom"
    }

    # Avoid name conflicts
    set exist_inst [$block findInst $new_name]
    if {$exist_inst ne "NULL" && $exist_inst ne ""} {
      puts "WARNING: Skip renaming $inst_name -> $new_name (name already exists)."
      incr cnt_skipped
      continue
    }

    $inst rename $new_name

    if {$is_upper} {
      incr cnt_upper
    } else {
      incr cnt_bottom
    }
  }

  puts "INFO: Done renaming upper/bottom instances."
  puts "INFO:  Upper  instances renamed : $cnt_upper"
  puts "INFO:  Bottom instances renamed : $cnt_bottom"
  puts "INFO:  Instances skipped        : $cnt_skipped"
}

# Run rename
rename_upper_bottom_insts

############################################################
# 2. Global power/ground connections
############################################################
puts "INFO: Setting up global connections..."

clear_global_connect

# TOP tier: match instances with name "*_upper"
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDD$}   -power
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDPE$}
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDCE$}
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSS$}   -ground
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSSE$}

# BOT tier: match instances with name "*_bottom"
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$}   -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$}   -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}

puts "INFO: Running global_connect..."
global_connect
puts "INFO: Global connections done."

############################################################
# 3. Define a single PDN voltage domain: 'Core'
############################################################

puts "INFO: Defining PDN voltage domain 'Core'..."

# Primary rails: bottom die
# - power  : BOT_VDD
# - ground : BOT_VSS
# Secondary power: TOP_VDD for upper die (same domain)
set_voltage_domain -name {Core} \
                   -power {BOT_VDD} \
                   -ground {BOT_VSS} \
                   -secondary_power {TOP_VDD}

report_voltage_domains
puts "INFO: Voltage domain 'Core' defined."

############################################################
# 4. Define PDN grids for BOT / TOP rails
#    - BOT grid: BOT_VDD / BOT_VSS on M1 / M2 / M5 / M6
#    - TOP grid: TOP_VDD / BOT_VSS on M1_m / M2_m / M5_m / M6_m
############################################################

puts "INFO: Defining PDN grids..."

# -------------------------
# 4.1 Bottom tier grid
# -------------------------
puts "INFO: Defining 'BOT' grid..."
define_pdn_grid -name {BOT} -voltage_domains {Core}

# Follow std-cell rails on bottom-die metals (M1 / M2)
add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M1} \
  -width  {0.018} \
  -pitch  {0.54} \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

add_pdn_stripe \
  -grid   {BOT} \
  -layer  {M2} \
  -width  {0.018} \
  -pitch  {0.54} \
  -offset {0} \
  -followpins \
  -nets   {BOT_VDD BOT_VSS}

# Mesh straps on M5 / M6 for bottom die
add_pdn_stripe \
  -grid    {BOT} \
  -layer   {M5} \
  -width   {0.12} \
  -spacing {0.072} \
  -pitch   {5.4} \
  -offset  {0.300} \
  -nets    {BOT_VDD BOT_VSS}

add_pdn_stripe \
  -grid    {BOT} \
  -layer   {M6} \
  -width   {0.288} \
  -spacing {0.096} \
  -pitch   {5.4} \
  -offset  {0.513} \
  -nets    {BOT_VDD BOT_VSS}

# Vertical connections for bottom tier PDN
add_pdn_connect -grid {BOT} -layers {M1 M2}
add_pdn_connect -grid {BOT} -layers {M2 M5}
add_pdn_connect -grid {BOT} -layers {M5 M6}

puts "INFO: 'BOT' grid defined."

# -------------------------
# 4.2 Top tier grid
# -------------------------
puts "INFO: Defining 'TOP' grid..."
define_pdn_grid -name {TOP} -voltage_domains {Core}

# Follow std-cell rails on mirrored metals for upper die (M1_m / M2_m)
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

# Mesh straps on M5_m / M6_m for top die
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

# Vertical connections for top tier PDN
add_pdn_connect -grid {TOP} -layers {M1_m M2_m}
add_pdn_connect -grid {TOP} -layers {M2_m M5_m}
add_pdn_connect -grid {TOP} -layers {M5_m M6_m}

puts "INFO: 'TOP' grid defined."
puts "INFO: PDN grid definition complete."
