############################################################
# PDN script (modified to follow given upper/bottom pattern)
# File: platforms/nangate45_3D/grid_strategy-M1-M4-M7.tcl
############################################################

############################################################
# 0. Preconditions
############################################################
# - Tech LEF / Cell LEF / Liberty / Verilog already loaded
# - Design linked and floorplan initialized
# - Standard cells:
#     * bottom-die masters: name contains "_bottom"
#     * upper-die  masters: name contains "_upper"

############################################################
# 1. Rename instances for upper / bottom tiers
############################################################

proc is_upper_master {master_name} {
    if {[string match "*_upper" $master_name]} { return 1 }
    return 0
}

proc is_bottom_master {master_name} {
    if {[string match "*_bottom" $master_name]} { return 1 }
    return 0
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

        # Avoid double suffix if sourced multiple times
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

        if {$is_upper} { incr cnt_upper } else { incr cnt_bottom }
    }

    puts "INFO: Done renaming upper/bottom instances."
    puts "INFO:  Upper  instances renamed : $cnt_upper"
    puts "INFO:  Bottom instances renamed : $cnt_bottom"
    puts "INFO:  Instances skipped        : $cnt_skipped"
}

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

set_voltage_domain -name {Core} \
                                     -power {BOT_VDD} \
                                     -ground {BOT_VSS} \
                                     -secondary_power {TOP_VDD}

report_voltage_domains
puts "INFO: Voltage domain 'Core' defined."

############################################################
# 4. Dynamic Pitch Calculation (keep your original idea)
############################################################
set core_area_bbox   [[odb::get_block] getCoreArea]

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

############################################################
# 5. Define PDN grids for BOT / TOP (adapted to your M1/M4/M7 scheme)
#    - BOT grid: BOT_VDD/BOT_VSS on M1, M4, M7
#    - TOP grid: TOP_VDD/BOT_VSS on M1_m, M4_m, M7_m
############################################################

puts "INFO: Defining PDN grids..."

# -------------------------
# 5.1 Bottom tier grid
# -------------------------
puts "INFO: Defining 'BOT' grid..."
define_pdn_grid -name {BOT} -voltage_domains {Core}

# Std-cell rails (bottom)
add_pdn_stripe -grid {BOT} -layer {M1}   -width {0.17} -pitch {2.8}      -offset {0} -followpins -nets {BOT_VDD BOT_VSS}

# Straps (bottom)
add_pdn_stripe -grid {BOT} -layer {M4}   -width {0.84} -pitch $m4_pitch  -offset {2} -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M7}   -width {2.4}  -pitch $m7_pitch  -offset {2} -nets {BOT_VDD BOT_VSS}

# Optional top metal (shared domain): keep original behavior but tie to bottom rails
add_pdn_stripe -grid {BOT} -layer {M10}  -width {3.2}  -pitch {32.0}     -offset {2} -nets {BOT_VDD BOT_VSS}

# Connections (bottom)
add_pdn_connect -grid {BOT} -layers {M1 M4}
add_pdn_connect -grid {BOT} -layers {M4 M7}

puts "INFO: 'BOT' grid defined."

# -------------------------
# 5.2 Top tier grid
# -------------------------
puts "INFO: Defining 'TOP' grid..."
define_pdn_grid -name {TOP} -voltage_domains {Core}

# Std-cell rails (upper mirrored metal). Ground references BOT_VSS (as requested pattern).
add_pdn_stripe -grid {TOP} -layer {M1_m} -width {0.17} -pitch {2.8}      -offset {0} -followpins -nets {TOP_VDD BOT_VSS}

# Straps (upper mirrored metal)
add_pdn_stripe -grid {TOP} -layer {M4_m} -width {0.84} -pitch $m4_pitch  -offset {2} -nets {TOP_VDD BOT_VSS}
add_pdn_stripe -grid {TOP} -layer {M7_m} -width {2.4}  -pitch $m7_pitch  -offset {2} -nets {TOP_VDD BOT_VSS}

# Connections (top)
add_pdn_connect -grid {TOP} -layers {M1_m M4_m}
add_pdn_connect -grid {TOP} -layers {M4_m M7_m}

puts "INFO: 'TOP' grid defined."
puts "INFO: PDN grid definition complete."
