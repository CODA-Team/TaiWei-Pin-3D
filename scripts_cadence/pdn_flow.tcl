# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
#################################################################
# pdn_flow.tcl — Build lower half → Mirror to upper half → Segmented connection → Bridge only M10↔M11
# Usage:
#   source pdn_config.tcl
#   source pdn_flow.tcl
#################################################################

# ====== Helper Procs (Note: Using global array access instead of namespace upvar) ======

# Check for required keys (scalar)
proc _need {v} {
  if {![info exists ::PDN($v)]} {
    error "Missing PDN($v). Please: source pdn_config.tcl first."
  }
}

# Get element from a global array: _aget <global_array_name> <layer>
proc _aget {arrName layer} {
  upvar #0 $arrName A
  if {![info exists A($layer)]} {
    error "Missing $arrName($layer) — check pdn_config.tcl"
  }
  return $A($layer)
}

# Direction to string
proc _dirStr {d} { expr {$d ? "vertical" : "horizontal"} }

# Safe GNC (minimum coverage)
proc _safeGNC_from_map {} {
  foreach entry $::PDN(gnc_map) {
    set net  [lindex $entry 0]
    set pins [lindex $entry 1]
    foreach p $pins {
      catch { globalNetConnect $net -type pgpin -pin $p -inst * -override }
    }
  }
  catch { globalNetConnect VDD -type tiehi -all -override }
  catch { globalNetConnect VSS -type tielo -all -override }
}

# Draw stripes on a specified layer (wires only, vias will be added later by segmented sroute)
proc _stripe_on {L nets} {
  addStripe -layer $L \
    -direction [_dirStr [_aget PDN_ldir $L]] \
    -nets $nets \
    -width   [_aget PDN_width   $L] \
    -spacing [_aget PDN_spacing $L] \
    -start_offset 5 \
    -set_to_set_distance [_aget PDN_pitch $L] \
    -extend_to design_boundary \
    -narrow_channel 1 \
    -snap_wire_center_to_grid Grid
}


# Copy only "wires" to the target layer (no vias), and optionally resize to the target layer's width
proc _dup_layer_wires {src dst {dst_width ""}} {
  # catch { deselectAll; editDelete -type Special -layer $dst -net $::PDN(nets) }

  deselectAll
  editSelect -type Special -layer $src -net $::PDN(nets)
  catch { editDeselect -object_type Via }

  set d [_aget PDN_ldir $dst]
  if {$d} {
    catch { editDuplicate -layer_vertical   $dst }
  } else {
    catch { editDuplicate -layer_horizontal $dst }
  }

  if {$dst_width ne ""} {
    deselectAll
    editSelect -type Special -layer $dst -net $::PDN(nets)
    catch { editResize -to $dst_width -side high -direction y -keep_center_line 1 }
    deselectAll
  }
}

# Clear all PG vias (keeping only "wires") to prevent addStripe from auto-connecting through them
proc _zap_pg_vias {} {
  deselectAll
  editSelect -type Special -object_type Via -net $::PDN(nets)
  catch { editDelete }
  deselectAll
}

# Perform sroute within given layer windows (vias are only allowed within the windows)
proc _sroute_windows {win_list connect_kinds} {
  foreach rng $win_list {
    if {[llength $rng] != 2} { continue }
    set L0 [lindex $rng 0]
    set L1 [lindex $rng 1]
    sroute -connect $connect_kinds \
      -layerChangeRange         [list $L0 $L1] \
      -targetViaLayerRange      [list $L0 $L1] \
      -crossoverViaLayerRange   [list $L0 $L1] \
      -allowJogging 1 -allowLayerChange 1 \
      -nets $::PDN(nets)
  }
}

# ====== Pre-checks ======
_need nets; _need top_routing_layer; _need isFP; _need fp_layer
_need stripe_layers_lower; _need mirror_pairs
_need windows_lower; _need windows_upper; _need window_bridge
_need minCh

# ====== Basic Setup (once is enough) ======
finishFloorplan -fillPlaceBlockage hard $PDN(minCh)
cutRow
finishFloorplan -fillPlaceBlockage hard $PDN(minCh)

catch { setDesignMode -topRoutingLayer $PDN(top_routing_layer) }

clearGlobalNets
_safeGNC_from_map

# Clear old special routes
deselectAll
catch { editDelete -type Special -net $PDN(nets) }

# Disable auto via generation: vias are only allowed to be created by sroute within our specified windows
catch { setGenerateViaMode -auto false }

# ====== 1) Follow-pin (typically fixed on M1) ======
if {$PDN(isFP)} {
  set fpL $PDN(fp_layer)
  set fpC [expr {[info exists PDN(fp_connect)] ? $PDN(fp_connect) : {corePin}}]
  sroute -connect $fpC \
    -layerChangeRange       [list $fpL $fpL] \
    -targetViaLayerRange    [list $fpL $fpL] \
    -crossoverViaLayerRange [list $fpL $fpL] \
    -allowJogging 1 -allowLayerChange 0 \
    -nets $PDN(nets)
}

# ====== 2) Lower half: addStripe (create "wires" only) ======
foreach L $PDN(stripe_layers_lower) { _stripe_on $L $PDN(nets) }
# Clear auto-generated vias from addStripe
_zap_pg_vias

# ====== 3) Lower half segmented connection (up to M10) ======
set _lower_connect  {corePin floatingStripe}
if {[info exists PDN(connect_block_pins)] && $PDN(connect_block_pins)} { lappend _lower_connect blockPin }
if {[info exists PDN(connect_pad_pins)]   && $PDN(connect_pad_pins)}   { lappend _lower_connect padPin padRing }
_sroute_windows $PDN(windows_lower) $_lower_connect

# ====== 4) Mirror: Copy "wires" to the upper half (no vias) ======
foreach pair $PDN(mirror_pairs) {
  set SRC [lindex $pair 0]
  set DST [lindex $pair 1]
  set W ""
  if {[info exists ::PDN_width($DST)]} { set W $::PDN_width($DST) }
  _dup_layer_wires $SRC $DST $W
}

# ====== 5) Upper half segmented connection (up to M11) ======
set _upper_connect {floatingStripe}
if {[info exists PDN(connect_block_pins)] && $PDN(connect_block_pins)} { lappend _upper_connect blockPin }
if {[info exists PDN(connect_pad_pins)]   && $PDN(connect_pad_pins)}   { lappend _upper_connect padPin padRing }
_sroute_windows $PDN(windows_upper) $_upper_connect

# ====== 6) The only bridge: M10 ↔ M11 (connect stripe to stripe only) ======
_sroute_windows [list $PDN(window_bridge)] {floatingStripe}

# ====== 7) Same-layer merge (optional, to clean up stripes) ======
set _merge_layers {}
foreach L $PDN(stripe_layers_lower) { lappend _merge_layers $L }
foreach pair $PDN(mirror_pairs)     { lappend _merge_layers [lindex $pair 1] }
set _merge_layers [lsort -unique $_merge_layers]
foreach L $_merge_layers {
  deselectAll
  editSelect -layer $L -net $PDN(nets)
  catch { editMerge }
}
deselectAll

puts "INFO: PDN OK — lower(M1..M10) built → mirrored to (M20..M11) → segmented sroute → single bridge M10↔M11."
