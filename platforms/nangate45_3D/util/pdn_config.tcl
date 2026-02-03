#################################################################
# innovus_3d_pdn_simple.tcl
# Minimal 3D PDN (homogeneous / mirrored)
#
# Layer order (bottom -> top) is FIXED by user:
#   M1 -> M2 -> ... -> M10 -> M9_m -> M8_m -> ... -> M1_m
#
# PDN targets:
#   Bottom: rails M1, mesh M4 (V) + M7 (H)
#   Top:    rails M1_m, mesh M4_m (V) + M7_m (H)
#################################################################

puts "INFO: Start..."

# --------------------------
# Basic floorplan channels
# --------------------------
set minCh 5

# --------------------------
# Mesh geometry (edit if needed)
# --------------------------
# Bottom mesh
set W_M4   0.84
set P_M4   20.16
set S_M4   0.56
set O_M4   2.00

set W_M7   2.40
set P_M7   40.00
set S_M7   1.60
set O_M7   2.00

# Top mesh (mirrored)
set W_M4m  0.84
set P_M4m  20.16
set S_M4m  0.56
set O_M4m  2.00

set W_M7m  2.40
set P_M7m  40.00
set S_M7m  1.60
set O_M7m  2.00

# --------------------------
# Tier instance queries
# --------------------------
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

# --------------------------
# Build PDN for one tier (minimal)
# --------------------------
proc build_tier_pdn {tier_name inst_list vdd_net vss_net rail_layer mesh_v mesh_h \
                     wv pv sv ov wh ph sh oh} {

  puts "INFO: === rails=$rail_layer meshV=$mesh_v meshH=$mesh_h ==="

  if {[llength $inst_list] == 0} {
    puts "WARN: No instances found. Skip."
    return
  }

  # 1) Connect PG pins for tier instances
  foreach inst $inst_list {
    globalNetConnect $vdd_net -type pgpin -pin VDD -inst $inst -override
    globalNetConnect $vss_net -type pgpin -pin VSS -inst $inst -override
  }
  globalNetConnect $vdd_net -type tiehi -all -override
  globalNetConnect $vss_net -type tielo -all -override

  # 2) Follow-pin rails on rail_layer
  sroute -nets [list $vdd_net $vss_net] \
         -connect {corePin} \
         -corePinLayer [list $rail_layer] \
         -corePinTarget {firstAfterRowEnd}

  # 3) Mesh stripes
  #    NOTE: stacked-via constraints must obey your fixed layer order.
  #    Bottom tier:
  #      M4 is above M1  => top=M4,  bottom=M1
  #      M7 is above M4  => top=M7,  bottom=M4
  #    Top tier:
  #      M1_m is above M4_m => top=M1_m, bottom=M4_m   (IMPORTANT FIX)
  #      M4_m is above M7_m? No. In your order, M7_m is BELOW M4_m? Actually:
  #        ... M10 -> M9_m -> M8_m -> ... -> M1_m
  #      so M7_m is BELOW M4_m and BELOW M1_m.
  #      For connecting M7_m to M4_m: top=M4_m, bottom=M7_m
  #
  # Therefore we will set stacked-via range explicitly per tier by name.

  if {$tier_name eq "BOT"} {
    # mesh_v (M4) down to rails (M1)
    setAddStripeMode -stacked_via_top_layer    $mesh_v
    setAddStripeMode -stacked_via_bottom_layer $rail_layer

    addStripe -layer $mesh_v \
              -direction vertical \
              -nets [list $vdd_net $vss_net] \
              -width $wv -spacing $sv \
              -start_offset $ov \
              -set_to_set_distance $pv

    # mesh_h (M7) down to mesh_v (M4)
    setAddStripeMode -stacked_via_top_layer    $mesh_h
    setAddStripeMode -stacked_via_bottom_layer $mesh_v

    addStripe -layer $mesh_h \
              -direction horizontal \
              -nets [list $vdd_net $vss_net] \
              -width $wh -spacing $sh \
              -start_offset $oh \
              -set_to_set_distance $ph

  } else {
    # TOP tier (mirrored stack):
    # mesh_v (M4_m) connects UP to rails (M1_m), so top MUST be M1_m
    setAddStripeMode -stacked_via_top_layer    $rail_layer
    setAddStripeMode -stacked_via_bottom_layer $mesh_v

    addStripe -layer $mesh_v \
              -direction vertical \
              -nets [list $vdd_net $vss_net] \
              -width $wv -spacing $sv \
              -start_offset $ov \
              -set_to_set_distance $pv

    # mesh_h (M7_m) connects UP to mesh_v (M4_m), so top MUST be M4_m
    setAddStripeMode -stacked_via_top_layer    $mesh_v
    setAddStripeMode -stacked_via_bottom_layer $mesh_h

    addStripe -layer $mesh_h \
              -direction horizontal \
              -nets [list $vdd_net $vss_net] \
              -width $wh -spacing $sh \
              -start_offset $oh \
              -set_to_set_distance $ph
  }

  puts "INFO: Done."
}

# --------------------------
# Top-level PDN flow
# --------------------------

# Create channels between rows (kept minimal, as you had)
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

# Stripe common mode (minimal)
setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -extend_to_closest_target area_boundary

# Use this script's PG mapping
clearGlobalNets

# Tier instance lists
set bot_insts [get_bottom_tier_insts]
set top_insts [get_upper_tier_insts]

puts "INFO: BOT inst count = [llength $bot_insts]"
puts "INFO: TOP inst count = [llength $top_insts]"

# Bottom PDN
build_tier_pdn "BOT" $bot_insts BOT_VDD BOT_VSS \
  M1  M4  M7 \
  $W_M4 $P_M4 $S_M4 $O_M4 \
  $W_M7 $P_M7 $S_M7 $O_M7

# Top PDN
build_tier_pdn "TOP" $top_insts TOP_VDD TOP_VSS \
  M1_m M4_m M7_m \
  $W_M4m $P_M4m $S_M4m $O_M4m \
  $W_M7m $P_M7m $S_M7m $O_M7m

puts "INFO: Finished."
