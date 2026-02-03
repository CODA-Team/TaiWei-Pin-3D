# ============================================================
# 01_gen_patterns.tcl
# ------------------------------------------------------------
# Step 1: Generate OpenRCX bench patterns:
#   - patterns.def
#   - patterns.v
#
# Environment variables (set in env.sh):
#   TECH_LEF
#   PATTERN_DEF
#   PATTERN_V
# ============================================================

set tech_lef    $::env(TECH_LEF)
set pattern_def $::env(PATTERN_DEF)
set pattern_v   $::env(PATTERN_V)

puts "INFO: \[PATTERN\] TECH_LEF    = $tech_lef"
puts "INFO: \[PATTERN\] PATTERN_DEF = $pattern_def"
puts "INFO: \[PATTERN\] PATTERN_V   = $pattern_v"

# Ensure output directories exist
file mkdir [file dirname $pattern_def]
file mkdir [file dirname $pattern_v]

# Read 3D tech LEF for the full stack (bottom + top + bonding)
read_lef $tech_lef

# Wire geometry parameterization:
#   - LEN: wire length in microns
#   - W_LIST: multiples of min width
#   - S_LIST: multiples of min spacing
set LEN     100

puts "INFO: \[PATTERN\] Generating bench wires..."
bench_wires \
  -all \
  -len $LEN

puts "INFO: \[PATTERN\] Generating bench Verilog to $pattern_v"
bench_verilog $pattern_v

puts "INFO: \[PATTERN\] Writing DEF to $pattern_def"
write_def $pattern_def

puts "INFO: \[PATTERN\] Pattern generation completed."

exit
