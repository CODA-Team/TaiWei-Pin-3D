########################################################################
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
#
# pdn_3d_sym_m12_m3m6.tcl
# 3D PDN (homogeneous PDK) for Innovus
# - Symmetric BOT / TOP power delivery network
# - No site/row rebuild (same site used for both tiers)
# - BOT : M1 / M2 rails + M3(vertical) + M6(horizontal) mesh
# - TOP : M1_m / M2_m rails + M3_m(vertical) + M6_m(horizontal) mesh
# - PG nets:
#     Bottom : BOT_VDD / BOT_VSS
#     Top    : TOP_VDD / TOP_VSS   (independent; no cross-die PG connect)
########################################################################

puts "INFO: \[pdn_3d_sym_m12_m3m6\] Start symmetric 3D PDN (BOT and TOP)..."

########################################################################
# Utility: query bottom / upper tier instances by master name
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

########################################################################
# Helper: build symmetric PDN for one tier
#   - tier_name : "BOT" / "TOP"
#   - inst_list : list of instances in this tier
#   - vdd_net   : VDD net (BOT_VDD / TOP_VDD)
#   - vss_net   : VSS net (BOT_VSS / TOP_VSS)
#   - m1_layer  : follow-pin rail layer (M1 / M1_m)
#   - m2_layer  : duplicated rail layer (M2 / M2_m)
#   - m3_layer  : vertical PG stripes  (M3 / M3_m)
#   - m6_layer  : horizontal PG straps (M6 / M6_m)
########################################################################
proc build_symmetric_pdn_for_tier {tier_name inst_list vdd_net vss_net \
                                   m1_layer m2_layer m3_layer m6_layer} {

  puts "INFO: \[pdn_3d_sym_m12_m3m6\] === \[$tier_name\] PDN on $m1_layer/$m2_layer + ${m3_layer}(V) + ${m6_layer}(H) ==="

  if {[llength $inst_list] == 0} {
    puts "WARN: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] No instances found. Skip PG connections and PDN."
    return
  }
  puts "INFO: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] instance count [llength $inst_list]"

  # --------------------------------------------------------------------
  # (1) Global net connect
  # --------------------------------------------------------------------
  foreach inst $inst_list {
    globalNetConnect $vdd_net -type pgpin -pin VDD -inst $inst -override
    globalNetConnect $vss_net -type pgpin -pin VSS -inst $inst -override
  }

  # Tie cells (best-effort)
  globalNetConnect $vdd_net -type tiehi -all -override
  globalNetConnect $vss_net -type tielo -all -override

  puts "INFO: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] globalNetConnect done for $vdd_net / $vss_net."

  # --------------------------------------------------------------------
  # (2) Follow-pin rails on M1 (corePin)
  # --------------------------------------------------------------------
  sroute -nets [list $vdd_net $vss_net] \
         -connect {corePin} \
         -corePinLayer [list $m1_layer] \
         -corePinTarget {firstAfterRowEnd}

  puts "INFO: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] follow-pin rails created on $m1_layer."

  # --------------------------------------------------------------------
  # (3) Duplicate rails to M2 and resize
  # NOTE: We keep your original behavior: duplicate as horizontal rails.
  # --------------------------------------------------------------------
  deselectAll
  editSelect -layer $m1_layer -net [list $vdd_net $vss_net]
  editDuplicate -layer_horizontal $m2_layer
  deselectAll

  deselectAll
  editSelect -layer $m2_layer -net [list $vdd_net $vss_net]
  editResize -to 0.018 -side high -direction y -keep_center_line 1
  deselectAll

  puts "INFO: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] rails duplicated to $m2_layer and resized."

  # --------------------------------------------------------------------
  # (4) PG mesh / straps:
  #     - M3 : vertical stripes, connect to M2 rails
  #     - M6 : horizontal straps, connect ONLY to M3
  #
  # NOTE:
  #   In this PDK, the TOP-tier metal stack (*_m) is mirrored in layer order.
  #   Example: M2_m is ABOVE M3_m, and M3_m is ABOVE M6_m.
  #   Therefore, stacked_via_top_layer / bottom_layer must be swapped for *_m.
  # --------------------------------------------------------------------

  set is_mirror 0
  if {[string match "*_m" $m1_layer]} { set is_mirror 1 }

  # --- M3 vertical stripes: connect between M2 and M3 (adjacent only) ---
  if {!$is_mirror} {
    # BOT: M3 above M2
    catch {setAddStripeMode -stacked_via_top_layer    $m3_layer}
    catch {setAddStripeMode -stacked_via_bottom_layer $m2_layer}
  } else {
    # TOP: M2_m above M3_m (mirrored)
    catch {setAddStripeMode -stacked_via_top_layer    $m2_layer}
    catch {setAddStripeMode -stacked_via_bottom_layer $m3_layer}
  }

  addStripe -layer $m3_layer \
            -direction vertical \
            -nets [list $vdd_net $vss_net] \
            -width 0.234 \
            -spacing 0.072 \
            -start_offset 0.300 \
            -set_to_set_distance 5.4

  # --- M6 horizontal straps: connect ONLY between M3 and M6 (adjacent only) ---
  if {!$is_mirror} {
    # BOT: M6 above M3
    catch {setAddStripeMode -stacked_via_top_layer    $m6_layer}
    catch {setAddStripeMode -stacked_via_bottom_layer $m3_layer}
  } else {
    # TOP: M3_m above M6_m (mirrored)
    catch {setAddStripeMode -stacked_via_top_layer    $m3_layer}
    catch {setAddStripeMode -stacked_via_bottom_layer $m6_layer}
  }

  addStripe -layer $m6_layer \
            -direction horizontal \
            -nets [list $vdd_net $vss_net] \
            -width 0.288 \
            -spacing 0.096 \
            -start_offset 0.513 \
            -set_to_set_distance 5.4

  puts "INFO: \[pdn_3d_sym_m12_m3m6\] \[$tier_name\] stripes added on ${m3_layer}(vertical) / ${m6_layer}(horizontal)."
}

########################################################################
# Top-level flow
########################################################################

set bot_insts [get_bottom_tier_insts]
set top_insts [get_upper_tier_insts]

puts "INFO: \[pdn_3d_sym_m12_m3m6\] BOT tier inst count = [llength $bot_insts]"
puts "INFO: \[pdn_3d_sym_m12_m3m6\] TOP tier inst count = [llength $top_insts]"

# Common stripe mode (for both tiers)
setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

# Own global nets in this script
clearGlobalNets

# Part 1: Bottom tier (M1/M2 rails + M3 vertical + M6 horizontal)
build_symmetric_pdn_for_tier "BOT" $bot_insts \
                             BOT_VDD BOT_VSS \
                             M1 M2 M3 M6

# Part 2: Top tier (M1_m/M2_m rails + M3_m vertical + M6_m horizontal)
build_symmetric_pdn_for_tier "TOP" $top_insts \
                             TOP_VDD TOP_VSS \
                             M1_m M2_m M3_m M6_m

puts "INFO: \[pdn_3d_sym_m12_m3m6\] Symmetric 3D PDN (BOT + TOP, independent PG) finished."