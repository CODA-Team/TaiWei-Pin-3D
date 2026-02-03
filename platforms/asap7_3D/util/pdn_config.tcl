########################################################################
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# pdn_3d_sym_m12_m56.tcl
# 3D PDN (homogeneous PDK) for Innovus
# - Symmetric BOT / TOP power delivery network
# - No site/row rebuild (same site used for both tiers)
# - BOT : M1 / M2 rails + M5 / M6 mesh
# - TOP : M1_m / M2_m rails + M5_m / M6_m mesh
# - PG nets:
#     Bottom : BOT_VDD / BOT_VSS
#     Top    : TOP_VDD / TOP_VSS   (independent; no cross-die PG connect)
########################################################################

puts "INFO: \[pdn_3d_sym_m12_m56\] Start symmetric 3D PDN (BOT and TOP)..."

########################################################################
# Utility: query bottom / upper tier instances by master name
########################################################################
proc get_bottom_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} {
    return ""
  }
  return [dbGet $inst_ptrs.name]
}

proc get_upper_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} {
    return ""
  }
  return [dbGet $inst_ptrs.name]
}

########################################################################
# Helper: build symmetric PDN for one tier
#   - tier_name : "BOT" / "TOP"
#   - inst_list : list of instances in this tier
#   - vdd_net   : VDD net (BOT_VDD / TOP_VDD)
#   - vss_net   : VSS net (BOT_VSS / TOP_VSS)
#   - m1_layer  : lower rail layer    (M1 / M1_m)
#   - m2_layer  : upper rail layer    (M2 / M2_m)
#   - m5_layer  : first mesh layer    (M5 / M5_m)
#   - m6_layer  : second mesh layer   (M6 / M6_m)
########################################################################
proc build_symmetric_pdn_for_tier {tier_name inst_list vdd_net vss_net \
                                   m1_layer m2_layer m5_layer m6_layer} {

  puts "INFO: \[pdn_3d_sym_m12_m56\] === \[$tier_name\] PDN on $m1_layer/$m2_layer/$m5_layer/$m6_layer ==="

  if {[llength $inst_list] == 0} {
    puts "WARN: \[pdn_3d_sym_m12_m56\] \[$tier_name\] No instances found. Skip PG connections and PDN."
    return
  }

  puts "INFO: \[pdn_3d_sym_m12_m56\] \[$tier_name\] instance count [llength $inst_list]"

  # 1) Global net connect
  foreach inst $inst_list {
    globalNetConnect $vdd_net -type pgpin -pin VDD -inst $inst -override
    globalNetConnect $vss_net -type pgpin -pin VSS -inst $inst -override
  }

  # Tie cells
  globalNetConnect $vdd_net -type tiehi -all -override
  globalNetConnect $vss_net -type tielo -all -override

  puts "INFO: \[pdn_3d_sym_m12_m56\] \[$tier_name\] globalNetConnect done for $vdd_net / $vss_net."

  # 2) Follow-pin rails on m1_layer
  sroute -nets [list $vdd_net $vss_net] \
         -connect {corePin} \
         -corePinLayer [list $m1_layer] \
         -corePinTarget {firstAfterRowEnd}

  puts "INFO: \[pdn_3d_sym_m12_m56\] \[$tier_name\] follow-pin rails created on $m1_layer."

  # 3) Duplicate rails to m2_layer and resize
  deselectAll
  editSelect -layer $m1_layer -net [list $vdd_net $vss_net]
  editDuplicate -layer_horizontal $m2_layer
  deselectAll

  deselectAll
  editSelect -layer $m2_layer -net [list $vdd_net $vss_net]
  editResize -to 0.018 -side high -direction y -keep_center_line 1
  deselectAll

  puts "INFO: \[pdn_3d_sym_m12_m56\] \[$tier_name\] rails duplicated to $m2_layer and resized."

  # 4) Mesh stripes on m5_layer / m6_layer (vertical)
  addStripe -layer $m5_layer \
            -direction vertical \
            -nets [list $vdd_net $vss_net] \
            -width 0.12 \
            -spacing 0.072 \
            -start_offset 0.300 \
            -set_to_set_distance 5.4

  addStripe -layer $m6_layer \
            -direction vertical \
            -nets [list $vdd_net $vss_net] \
            -width 0.288 \
            -spacing 0.096 \
            -start_offset 0.513 \
            -set_to_set_distance 5.4

  puts "INFO: \[pdn_3d_sym_m12_m56\] \[$tier_name\] mesh stripes added on $m5_layer / $m6_layer."
}

########################################################################
# Top-level flow
########################################################################

set bot_insts [get_bottom_tier_insts]
set top_insts [get_upper_tier_insts]

puts "INFO: \[pdn_3d_sym_m12_m56\] BOT tier inst count = [llength $bot_insts]"
puts "INFO: \[pdn_3d_sym_m12_m56\] TOP tier inst count = [llength $top_insts]"

# Common stripe mode (for both tiers)
setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

# Own global nets in this script
clearGlobalNets

# Part 1: Bottom tier (M1/M2 rails, M5/M6 mesh)
build_symmetric_pdn_for_tier "BOT" $bot_insts \
                             BOT_VDD BOT_VSS \
                             M1 M2 M5 M6

# Part 2: Top tier (M1_m/M2_m rails, M5_m/M6_m mesh)
build_symmetric_pdn_for_tier "TOP" $top_insts \
                             TOP_VDD TOP_VSS \
                             M1_m M2_m M5_m M6_m

puts "INFO: \[pdn_3d_sym_m12_m56\] Symmetric 3D PDN (BOT + TOP, independent PG) finished."
