# ============================================================
# 03_gen_rules.tcl
# ------------------------------------------------------------
# Step 3: OpenROAD / OpenRCX generates RCX rules:
#   1) Read 3D tech LEF + pattern DEF
#   2) Build bench DB
#   3) Read golden SPEF from commercial extractor
#   4) Write RCX rules file
#
# Environment variables (set in env.sh):
#   TECH_LEF
#   PATTERN_DEF
#   PATTERN_SPEF
#   RCX_RULES
# ============================================================

set tech_lef     $::env(TECH_LEF)
set pattern_def  $::env(PATTERN_DEF)
set pattern_spef $::env(PATTERN_SPEF)
set handoff_dir    $::env(ORD_OUT_DIR)

puts "INFO: \[RCX\] TECH_LEF     = $tech_lef"
puts "INFO: \[RCX\] PATTERN_DEF  = $pattern_def"
puts "INFO: \[RCX\] PATTERN_SPEF = $pattern_spef"
puts "INFO: \[RCX\] EXTRACT_DIR    = $handoff_dir"

file mkdir $handoff_dir

# ----------------- Step 1: read LEF / DEF -------------------
read_lef $tech_lef
read_def $pattern_def

# ----------------- Step 2: build bench DB -------------------
# Rebuild bench pattern database (no new patterns are created).
bench_wires -db_only

# ----------------- Step 3: read golden SPEF -----------------
bench_read_spef $pattern_spef

# ----------------- Step 4: write RCX rules ------------------

puts "INFO: \[RCX\] Writing RCX rules..."
puts "INFO: \[RCX\]   dir  = $handoff_dir"

write_rules -dir $handoff_dir

puts "INFO: \[RCX\] RCX rules generation completed."

# ----------------- Optional: self-check via diff_spef -------
# You can optionally re-extract patterns using the generated
# RCX rules and compare with the golden SPEF, e.g.:
#
#   set ord_out_dir ""
#   if {[info exists ::env(ORD_OUT_DIR)]} {
#     set ord_out_dir $::env(ORD_OUT_DIR)
#   } else {
#     set ord_out_dir "."
#   }
#
#   set rcx_spef [file join $ord_out_dir "rcx_patterns.spef"]
#
#   extract_parasitics \
#       -ext_model_file $rcx_rules \
#       -corner_cnt 1 -corner 0 \
#       -cc_model 10 -context_depth 5
#
#   write_spef $rcx_spef
#
#   diff_spef -file $pattern_spef \
#             -ext_corner 0 -spef_corner 0 \
#             -r_res -r_cap -r_cc_cap
#
# This mirrors the official calibration Step (D).
# ------------------------------------------------------------
exit
