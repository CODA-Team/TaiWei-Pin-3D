########################################################################
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# pdn_3d_stacked.tcl
# 3D PDN for Innovus (aligning with OpenROAD 3D PDN logic, no renaming)
# - Part 0: helper procs (box flatten / row rebuild / tier inst query)
# - Part 1: BOT PG connect + M1 rails + M4/M7 mesh
# - Part 2: (optional) rebuild upper rows + TOP PG connect
#           + M1_m/M2_m rails + M5_m/M6_m mesh
# - PG nets:
#     Bottom : BOT_VDD / BOT_VSS
#     Top    : TOP_VDD / BOT_VSS  (shared ground; change if needed)
########################################################################
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
puts "INFO: \[pdn_3d_stacked\] Start 3D PDN (BOT then TOP)..."

proc get_bottom_tier_insts {} {
  # pointers to insts whose cell.name matches "*_bottom"
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} {
    return ""
  }
  # return instance names
  return [dbGet $inst_ptrs.name]
}

proc get_upper_tier_insts {} {
  # pointers to insts whose cell.name matches "*_upper"
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} {
    return ""
  }
  return [dbGet $inst_ptrs.name]
}

########################################################################
# Part 0. NOTE: No rename — we keep original instance names
########################################################################

puts "INFO: \[pdn_3d_stacked\] Skip renaming instances; use master name (*_upper/*_bottom) to classify tiers."

########################################################################
# Part 1. BOT tier: BOT_VDD / BOT_VSS
########################################################################

puts "INFO: \[pdn_3d_stacked\] === Part 1: BOT tier PDN (BOT_VDD / BOT_VSS) ==="

set minCh 2

# 1) Unplace core cells and cut rows
dbset [dbget top.insts.cell.subClass core -p2].pStatus unplaced
finishFloorplan -fillPlaceBlockage hard $minCh
cutRow
finishFloorplan -fillPlaceBlockage hard $minCh

# Remove temporary place blockages
set fp_blk [dbGet top.fPlan.pBlkgs.name finishfp_place_blkg_* -p1]
if {[llength $fp_blk] > 0} {
  deselectAll
  select_obj $fp_blk
  deleteSelectedFromFPlan
  deselectAll
}

# 2) Global net connections for bottom tier only
set nets_bot [list BOT_VDD BOT_VSS]
clearGlobalNets

set bot_insts [get_bottom_tier_insts]
if {[llength $bot_insts] == 0} {
  puts "WARN: \[pdn_3d_stacked\] No *_bottom masters found. BOT PG connections will be empty."
} else {
  puts "INFO: \[pdn_3d_stacked\] BOT tier instance count [llength $bot_insts]"
  foreach inst $bot_insts {
    globalNetConnect BOT_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect BOT_VSS -type pgpin -pin VSS -inst $inst -override
  }
}

# Tie cells behavior (only to BOT_VDD / BOT_VSS)
globalNetConnect BOT_VDD -type tiehi -all -override
globalNetConnect BOT_VSS -type tielo -all -override

puts "INFO: \[pdn_3d_stacked\] BOT globalNetConnect done."

# 3) Via generation
setGenerateViaMode -auto true
generateVias
editDelete -type Special -net $nets_bot
setViaGenMode -ignore_DRC false
setViaGenMode -optimize_cross_via true
setViaGenMode -allow_wire_shape_change false
setViaGenMode -extend_out_wire_end false
setViaGenMode -viarule_preference generated

# 4) Follow-pin rails for BOT on M1
sroute -nets {BOT_VDD BOT_VSS} \
       -connect {corePin} \
       -corePinLayer {M1} \
       -corePinTarget {firstAfterRowEnd}

# 5) BOT mesh on M4/M7
setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false
setAddStripeMode -stacked_via_bottom_layer M1 -stacked_via_top_layer M7

addStripe -layer M4 \
          -direction vertical \
          -nets $nets_bot \
          -width 0.84 \
          -spacing 0.84 \
          -start_offset 0.0 \
          -set_to_set_distance 20.16

addStripe -layer M7 \
          -direction horizontal \
          -nets $nets_bot \
          -width 2.4 \
          -spacing 2.4 \
          -start_offset 2.0 \
          -set_to_set_distance 40.0

puts "INFO: \[pdn_3d_stacked\] BOT PDN (M1 rails + M4/M7 mesh) completed."

########################################################################
# Part 2. TOP tier: TOP_VDD / BOT_VSS  (shared ground)
########################################################################

puts "INFO: \[pdn_3d_stacked\] === Part 2: TOP tier PDN (TOP_VDD / BOT_VSS) ==="

# 1) Rebuild rows for upper site (optional)
if {[info exists ::env(UPPER_SITE)]} {
  puts "INFO: \[pdn_3d_stacked\] Rebuilding rows for upper tier site = $::env(UPPER_SITE)"
  rebuild_rows_for_site $::env(UPPER_SITE)
} else {
  puts "WARN: \[pdn_3d_stacked\] UPPER_SITE is not set; skip upper row rebuild."
}

# 2) Global net connections for *_upper instances
set nets_top [list TOP_VDD BOT_VSS]

set top_insts [get_upper_tier_insts]
if {[llength $top_insts] == 0} {
  puts "WARN: \[pdn_3d_stacked\] No *_upper masters found. TOP PG connections will be empty."
} else {
  puts "INFO: \[pdn_3d_stacked\] TOP tier instance count [llength $top_insts]"
  foreach inst $top_insts {
    globalNetConnect TOP_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect BOT_VSS -type pgpin -pin VSS -inst $inst -override
  }
}

globalNetConnect TOP_VDD -type tiehi -all -override
# If you want explicit tielo for BOT_VSS on upper tier:
globalNetConnect BOT_VSS -type tielo -all -override

puts "INFO: \[pdn_3d_stacked\] TOP globalNetConnect done."

# 3a) Follow-pin rails for TOP on M1_m
sroute -nets {TOP_VDD BOT_VSS} \
       -connect {corePin} \
       -corePinLayer {M1_m} \
       -corePinTarget {firstAfterRowEnd}

# 3b) Duplicate M1_m rails to M2_m
deselectAll
editSelect -layer M1_m -net $nets_top
editDuplicate -layer_horizontal M2_m
deselectAll

# Resize M2_m rails
deselectAll
editSelect -layer M2_m -net $nets_top
editResize -to 0.018 -side high -direction y -keep_center_line 1
deselectAll

# 4) TOP mesh on M5_m / M6_m
setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

addStripe -layer M5_m \
          -direction vertical \
          -nets $nets_top \
          -width 0.12 \
          -spacing 0.072 \
          -start_offset 0.300 \
          -set_to_set_distance 5.4

addStripe -layer M6_m \
          -direction vertical \
          -nets $nets_top \
          -width 0.288 \
          -spacing 0.096 \
          -start_offset 0.513 \
          -set_to_set_distance 5.4

puts "INFO: \[pdn_3d_stacked\] 3D PDN generation (BOT + TOP) finished."
