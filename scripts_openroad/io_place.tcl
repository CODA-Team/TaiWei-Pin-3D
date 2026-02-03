source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

# IO layers must be provided by the flow (e.g., "metal2" for H, "metal3" for V).
if {![info exists ::env(IO_PLACER_H)] || ![info exists ::env(IO_PLACER_V)]} {
  error "IO_PLACER_H / IO_PLACER_V must be set (e.g., set ::env(IO_PLACER_H) metal2; set ::env(IO_PLACER_V) metal3)."
}
set LAYER_H $::env(IO_PLACER_H)
set LAYER_V $::env(IO_PLACER_V)

# =====================================
# 1) Utility: die bbox & DBU conversion
# =====================================
proc get_die_bbox {} {
    return [ord::get_die_area]
}

proc get_db_units_per_micron {} {
    return [[odb::get_block] getDbUnitsPerMicron]
}
# DBU per micron
set DBU_PER_UM [get_db_units_per_micron]

# Round um -> DBU safely
proc um_to_dbu_round {val_um dbu_per_um} {
  return [expr {round ($val_um * $dbu_per_um * 1000) / 1000.0 }]
}

# ==========================================
# 2) Collect & sanitize top-level IO port set
# ==========================================
proc has_bits {base all_list} {
  foreach q $all_list { if {[string match "${base}\[*]" $q]} { return 1 } }
  return 0
}
proc sanitize_ports {ports all_ports} {
  set keep {}; array set seen {}
  foreach p $ports {
    # Skip power/ground variants
    if {[regexp -nocase {^(VDD|VSS|VDDA|VSSA|VCCD|VSSD|PWR|GND)} $p]} { continue }
    # Keep unique vector bits; skip scalar base if it has bits
    if {[regexp {\[[0-9]+\]} $p]} {
      if {![info exists seen($p)]} { set seen($p) 1; lappend keep $p }
      continue
    }
    if {[has_bits $p $all_ports]} { continue }
    if {![info exists seen($p)]} { set seen($p) 1; lappend keep $p }
  }
  return [lsort -dictionary -unique $keep]
}

set ins_raw  [lsort -dictionary [all_inputs]]
set outs_raw [lsort -dictionary [all_outputs]]
set all_raw  [concat $ins_raw $outs_raw]
set pins_all [sanitize_ports $all_raw $all_raw]
set N [llength $pins_all]

puts [format "IO-INFO: total ports=%d, kept=%d" [llength $all_raw] $N]

# ===============================
# 3) Geometry & perimeter in um
#    NOTE: ord::get_die_area is already in MICRONS.
# ===============================
lassign [get_die_bbox] LX_um LY_um UX_um UY_um
set W_um     [expr {$UX_um - $LX_um}]
set H_um     [expr {$UY_um - $LY_um}]
if {$W_um <= 0 || $H_um <= 0} { error "Invalid die size: W=$W_um H=$H_um (um)" }
set PERIM_um [expr {2.0*($W_um + $H_um)}]

puts [format "IO-DIE(um): W=%.6f H=%.6f Perim=%.6f" $W_um $H_um $PERIM_um]

# =======================================================
# 4) place_pins feasibility-first strategy
#    If it fails even with (min_dist=0, ca=0), parameters cannot fix it.
# =======================================================

proc run_place_pins {LAYER_H LAYER_V min_dist_um ca_um} {
  clear_io_pin_constraints
  return [catch {
    log_cmd place_pins \
      -hor_layers $LAYER_H \
      -ver_layers $LAYER_V \
      -min_distance $min_dist_um \
      -corner_avoidance $ca_um \
      -annealing
  } err]
}

# --- 4.1 Try maximum packing first ---
set min_dist_um 0.0
set ca_um       0.0

puts [format "IO-TRY pack: N=%d min_distance=%.6f um corner_avoidance=%.6f um H=%s V=%s" \
      $N $min_dist_um $ca_um $LAYER_H $LAYER_V]

set rc [run_place_pins $LAYER_H $LAYER_V $min_dist_um $ca_um]
if {$rc != 0} {
  # Re-run without log_cmd just to capture the error string reliably
  set rc2 [catch {
    place_pins -hor_layers $LAYER_H -ver_layers $LAYER_V -min_distance $min_dist_um -corner_avoidance $ca_um -annealing
  } last_err]

  if {[regexp {PPL-0024} $last_err] && [regexp {available positions \(([0-9]+)\)} $last_err -> avail]} {
    set need_perim [expr {$PERIM_um * (double($N) / double($avail))}]
    puts [format "IO-FAIL: pins=%d > available=%d on layers H=%s V=%s" $N $avail $LAYER_H $LAYER_V]
    puts [format "IO-FAIL: With these layers, even min_distance=0 and corner_avoidance=0 cannot fit." ]
    puts [format "IO-FAIL: You must (a) increase die perimeter to >= %.2f um (current %.2f um), or (b) use tighter-pitch layers / multiple layers." \
                  $need_perim $PERIM_um]
    error $last_err
  } else {
    error $last_err
  }
}

# =======================================================
# 5) Optional: spread pins after feasibility is confirmed
#    Now that it fits, compute a reasonable spacing.
# =======================================================

# Keep ca modest; avoid eating too much perimeter.
set short_um [expr {min($W_um, $H_um)}]
set ca_um    [expr {0.02 * $short_um}]          ;# 2% of short side
if {$ca_um < 0} { set ca_um 0.0 }

proc eff_perim {perim ca} { return [expr {$perim - 8.0*$ca}] }
set L_eff [eff_perim $PERIM_um $ca_um]
if {$L_eff <= 0.0} { set ca_um 0.0; set L_eff [eff_perim $PERIM_um $ca_um] }

set pitch_um    [expr {$L_eff / double($N)}]
set min_dist_um [expr {0.70 * $pitch_um}]
if {$min_dist_um < 0.0} { set min_dist_um 0.0 }

puts [format "IO-SPREAD(um): N=%d Perim=%.6f L_eff=%.6f ca=%.6f pitch=%.6f min_dist=%.6f" \
      $N $PERIM_um $L_eff $ca_um $pitch_um $min_dist_um]

# Re-run place_pins with spreading; if it fails, fall back to pack.
set rc [run_place_pins $LAYER_H $LAYER_V $min_dist_um $ca_um]
if {$rc != 0} {
  puts "[WARN] Spread parameters not feasible; falling back to pack (min_dist=0, ca=0)."
  set rc [run_place_pins $LAYER_H $LAYER_V 0.0 0.0]
  if {$rc != 0} { error "place_pins failed even in pack mode unexpectedly." }
}

puts [format "FINAL(um): min_distance=%.6f corner_avoidance=%.6f" $min_dist_um $ca_um]
puts "FINAL: IO pins placed."
