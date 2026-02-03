# ============================================================
# 02_cds_extract.tcl
# ------------------------------------------------------------
# Step 2: Run Innovus RC extraction on the pattern benches.
#
# Environment variables (set in env.sh):
#   TECH_LEF          - tech + cell LEF list (space-separated)
#   PATTERN_DEF       - pattern DEF with routed wires
#   PATTERN_V         - optional pattern netlist (can be empty)
#   PATTERN_SPEF      - output SPEF path
#   CDS_RC_SETUP_TCL  - optional PDK/MMMC/QRC setup script
#   CDS_RC_CORNER     - optional rc_corner name (default: default_emulate_rc_corner)
#
# Current assumption:
#   - No QRC/ICT is available yet.
#   - Innovus will run with its default/LEF-based RC (non-signoff).
#   - Later you can update CDS_RC_SETUP_TCL to read QRC tech, MMMC, etc.
#
# Usage example:
#   innovus -no_gui -init 02_cds_extract.tcl -log <logfile>
#
# ============================================================

# ------------------------------
# 0. Read environment variables
# ------------------------------
if {![info exists ::env(TECH_LEF)]} {
  puts "ERROR: \[CDS\] env(TECH_LEF) is not set."
  exit 1
}
if {![info exists ::env(PATTERN_DEF)]} {
  puts "ERROR: \[CDS\] env(PATTERN_DEF) is not set."
  exit 1
}
if {![info exists ::env(PATTERN_SPEF)]} {
  puts "ERROR: \[CDS\] env(PATTERN_SPEF) is not set."
  exit 1
}

set tech_lef     $::env(TECH_LEF)
set pattern_def  $::env(PATTERN_DEF)
set out_spef     $::env(PATTERN_SPEF)

set pattern_v    ""
if {[info exists ::env(PATTERN_V)]} {
  set pattern_v $::env(PATTERN_V)
}

set rc_setup_tcl ""
if {[info exists ::env(CDS_RC_SETUP_TCL)]} {
  set rc_setup_tcl $::env(CDS_RC_SETUP_TCL)
}

# rc_corner name: allow override from env, otherwise use emulate default
set rc_corner_name "default_emulate_rc_corner"
if {[info exists ::env(CDS_RC_CORNER)]} {
  set rc_corner_name $::env(CDS_RC_CORNER)
}

puts "INFO: \[CDS\] TECH_LEF         = $tech_lef"
puts "INFO: \[CDS\] PATTERN_DEF      = $pattern_def"
puts "INFO: \[CDS\] PATTERN_V        = $pattern_v"
puts "INFO: \[CDS\] PATTERN_SPEF     = $out_spef"
puts "INFO: \[CDS\] RC_SETUP_TCL     = $rc_setup_tcl"
puts "INFO: \[CDS\] RC_CORNER_NAME   = $rc_corner_name"

# Ensure output directory exists
file mkdir [file dirname $out_spef]

setMultiCpuUsage -localCpu $::env(NUM_CORES)

# ------------------------------------------------------------
# 1. Optional: source PDK RC/MMMC setup (for future QRC integration)
# ------------------------------------------------------------
if {$rc_setup_tcl ne ""} {
  if {[file exists $rc_setup_tcl]} {
    puts "INFO: \[CDS\] Sourcing RC setup script: $rc_setup_tcl"
    source $rc_setup_tcl
  } else {
    puts "WARN: \[CDS\] RC setup script not found: $rc_setup_tcl"
  }
}

# ------------------------------------------------------------
# 2. Import LEF / DEF / (optional) netlist into Innovus
#    For pattern benches, we mainly care about geometry in DEF.
# ------------------------------------------------------------

# TECH_LEF can be a space-separated list; pass as a Tcl list
set lef_list [split $tech_lef " "]

puts "INFO: \[CDS\] Reading LEF via read_physical -lef ..."
read_physical -lef $lef_list

# Optional netlist: for simple RC patterns this is usually not required.
if {$pattern_v ne "" && [file exists $pattern_v]} {
  puts "INFO: \[CDS\] Reading netlist: $pattern_v"
  read_netlist $pattern_v
} elseif {$pattern_v ne ""} {
  puts "WARN: \[CDS\] PATTERN_V specified but file not found: $pattern_v"
} else {
  puts "INFO: \[CDS\] No PATTERN_V specified, skipping read_netlist."
}

if {![file exists $pattern_def]} {
  puts "ERROR: \[CDS\] PATTERN_DEF does not exist: $pattern_def"
  exit 1
}
puts "INFO: \[CDS\] Reading DEF: $pattern_def"
defIn $pattern_def

# 注：你当前 log 里 init_design 报 IMPSYT-7329，说明设计已经在内存里。
#     对这个纯 RC bench，我们可以不强制再调用 init_design，避免噪音。
# 如果后面你接 MMMC / 时序分析，再在 RC_SETUP_TCL 里做正式 init_design 即可。

# ------------------------------------------------------------
# 3. Configure RC extraction mode（post-route, low effort, coupled）
# ------------------------------------------------------------

set_db extract_rc_engine        post_route
set_db extract_rc_effort_level  low
set_db extract_rc_coupled       true

puts "INFO: \[CDS\] extract_rc_engine       = [get_db extract_rc_engine]"
puts "INFO: \[CDS\] extract_rc_effort_level = [get_db extract_rc_effort_level]"
puts "INFO: \[CDS\] extract_rc_coupled      = [get_db extract_rc_coupled]"

# ------------------------------------------------------------
# 4. Ensure an RC corner exists (LEF/emulate if no QRC tech)
# ------------------------------------------------------------

set rc_corner_exists 0
foreach c [get_db rc_corners] {
  if {[get_db $c .name] eq $rc_corner_name} {
    set rc_corner_exists 1
    break
  }
}

if {!$rc_corner_exists} {
  puts "WARN: \[CDS\] rc_corner '$rc_corner_name' not found."
  puts "WARN: \[CDS\] Creating rc_corner '$rc_corner_name' without QRC tech (LEF/emulate RC only)."
  # Minimal create_rc_corner; no -qrc_tech/-cap_table yet.
  create_rc_corner -name $rc_corner_name
} else {
  puts "INFO: \[CDS\] Using existing rc_corner '$rc_corner_name'."
}

# ------------------------------------------------------------
# 5. Run RC extraction and dump SPEF
# ------------------------------------------------------------

puts "INFO: \[CDS\] Running extractRC (post-route engine)."
extractRC

puts "INFO: \[CDS\] Writing SPEF to: $out_spef"
rcOut -spef $out_spef

puts "INFO: \[CDS\] RC extraction finished. SPEF written to $out_spef"

exit
