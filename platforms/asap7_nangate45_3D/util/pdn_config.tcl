########################################################################
# pdn_3d_stacked.tcl  (HETERO, Innovus)
# 3D PDN for Innovus (aligned with OpenROAD 3D PDN logic, no renaming)
#
# - Part 0: helper procs (tier inst query)
# - Part 1: BOT PG connect + M1 rails + M4(V)/M7(H) mesh   (Nangate45-like)
# - Part 2: rebuild upper rows + TOP PG connect
#           + M1_m/M2_m rails + M3_m(V)/M6_m(H) mesh       (ASAP7-like)
#
# - PG nets:
#     Bottom : BOT_VDD / BOT_VSS
#     Top    : TOP_VDD / TOP_VSS
#
# Key fixes vs common pitfalls:
# - BOT mesh uses per-layer stacked-via limits to avoid unintended M7->M8 via attempts.
# - TOP mesh uses mirrored-stack stacked-via limits and M6_m horizontal straps.
########################################################################

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
puts "INFO: \[pdn_3d_stacked\] Start 3D PDN (BOT then TOP)..."

########################################################################
# Part 0. Tier instance query
########################################################################
proc get_bottom_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

proc get_upper_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

puts "INFO: \[pdn_3d_stacked\] Skip renaming instances; classify tiers by master suffix (*_upper/*_bottom)."

########################################################################
# Part 1. BOT tier: BOT_VDD / BOT_VSS
#   Nangate45-like: M1 rails + M4 vertical straps + M7 horizontal straps
########################################################################
puts "INFO: \[pdn_3d_stacked\] === Part 1: BOT tier PDN (BOT_VDD / BOT_VSS) ==="

set minCh 2

# 1) Unplace core cells and cut rows (kept from your original flow)
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

# Tie cells (bottom)
globalNetConnect BOT_VDD -type tiehi -all -override
globalNetConnect BOT_VSS -type tielo -all -override
puts "INFO: \[pdn_3d_stacked\] BOT globalNetConnect done."

# 3) Via generation housekeeping (kept)
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

# 5) BOT mesh on M4 (vertical) / M7 (horizontal)
setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

# IMPORTANT:
# Do NOT allow a broad M1->M7 stacked-via range when adding M4 stripes.
# Otherwise the power planner may attempt unintended connections up to M8.
# Use per-layer stacked-via limits.

# (a) M4 vertical stripes: allow vias ONLY between M1 and M4
setAddStripeMode -stacked_via_bottom_layer M1 -stacked_via_top_layer M4
addStripe -layer M4 \
          -direction vertical \
          -nets $nets_bot \
          -width 0.84 \
          -spacing 0.84 \
          -start_offset 0.0 \
          -set_to_set_distance 20.16

# (b) M7 horizontal straps: allow vias ONLY between M4 and M7
setAddStripeMode -stacked_via_bottom_layer M4 -stacked_via_top_layer M7
addStripe -layer M7 \
          -direction horizontal \
          -nets $nets_bot \
          -width 2.4 \
          -spacing 2.4 \
          -start_offset 2.0 \
          -set_to_set_distance 40.0

puts "INFO: \[pdn_3d_stacked\] BOT PDN (M1 rails + M4(V)/M7(H) mesh) completed."

########################################################################
# Part 2. TOP tier: TOP_VDD / TOP_VSS
#   ASAP7-like: M1_m/M2_m rails + M3_m vertical + M6_m horizontal
########################################################################
puts "INFO: \[pdn_3d_stacked\] === Part 2: TOP tier PDN (TOP_VDD / TOP_VSS) ==="

# 1) Rebuild rows for upper site (hetero requires this)
if {[info exists ::env(UPPER_SITE)]} {
  puts "INFO: \[pdn_3d_stacked\] Rebuilding rows for upper tier site = $::env(UPPER_SITE)"
  rebuild_rows_for_site $::env(UPPER_SITE)
} else {
  puts "WARN: \[pdn_3d_stacked\] UPPER_SITE is not set; skip upper row rebuild."
}

# 2) Global net connections for *_upper instances
set nets_top [list TOP_VDD TOP_VSS]

set top_insts [get_upper_tier_insts]
if {[llength $top_insts] == 0} {
  puts "WARN: \[pdn_3d_stacked\] No *_upper masters found. TOP PG connections will be empty."
} else {
  puts "INFO: \[pdn_3d_stacked\] TOP tier instance count [llength $top_insts]"
  foreach inst $top_insts {
    globalNetConnect TOP_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect TOP_VSS -type pgpin -pin VSS -inst $inst -override
  }
}

globalNetConnect TOP_VDD -type tiehi -all -override
globalNetConnect TOP_VSS -type tielo -all -override
puts "INFO: \[pdn_3d_stacked\] TOP globalNetConnect done."

# 3a) Follow-pin rails for TOP on M1_m
sroute -nets $nets_top \
       -connect {corePin} \
       -corePinLayer {M1_m} \
       -corePinTarget {firstAfterRowEnd}

# 3b) Duplicate M1_m rails to M2_m (horizontal)
deselectAll
editSelect -layer M1_m -net $nets_top
editDuplicate -layer_horizontal M2_m
deselectAll

# Resize M2_m rails
deselectAll
editSelect -layer M2_m -net $nets_top
editResize -to 0.018 -side high -direction y -keep_center_line 1
deselectAll

# 4) TOP mesh on M3_m (vertical) / M6_m (horizontal)
# IMPORTANT:
# - M6_m is a horizontal layer in ASAP7 (must be horizontal straps)
# - The *_m stack is mirrored: M2_m is ABOVE M3_m, and M3_m is ABOVE M6_m.
#   Therefore stacked_via_top_layer / bottom_layer must be set accordingly.

setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

# (a) M3_m vertical stripes: connect ONLY between M2_m and M3_m (mirrored stack)
setAddStripeMode -stacked_via_top_layer M2_m -stacked_via_bottom_layer M3_m
addStripe -layer M3_m \
          -direction vertical \
          -nets $nets_top \
          -width 0.234 \
          -spacing 0.072 \
          -start_offset 0.300 \
          -set_to_set_distance 5.4

# (b) M6_m horizontal straps: connect ONLY between M3_m and M6_m (mirrored stack)
setAddStripeMode -stacked_via_top_layer M3_m -stacked_via_bottom_layer M6_m
addStripe -layer M6_m \
          -direction horizontal \
          -nets $nets_top \
          -width 0.288 \
          -spacing 0.096 \
          -start_offset 0.513 \
          -set_to_set_distance 5.4

puts "INFO: \[pdn_3d_stacked\] 3D PDN generation (BOT + TOP) finished."
