puts "--- Starting synth.tcl ---"
source $::env(OPENROAD_SCRIPTS_DIR)/synth_preamble.tcl
puts "--- Reading design sources... ---"
read_design_sources
puts "--- Finished reading design sources. ---"

dict for {key value} [env_var_or_empty VERILOG_TOP_PARAMS] {
  # Apply toplevel parameters
  puts "--- Applying toplevel parameter: $key = $value ---"
  chparam -set $key $value $::env(DESIGN_NAME)
}

puts "--- Checking hierarchy for top module: $::env(DESIGN_NAME) ---"
hierarchy -check -top $::env(DESIGN_NAME)

puts "--- Sourcing SYNTH_CANONICALIZE_TCL if it exists... ---"
source_env_var_if_exists SYNTH_CANONICALIZE_TCL

# Get rid of unused modules
puts "--- Running opt_clean -purge ---"
opt_clean -purge

if { [env_var_equals SYNTH_GUT 1] } {
  puts "--- SYNTH_GUT is 1, deleting top level cells. ---"
  # /deletes all cells at the top level, which will quickly optimize away
  # everything else, including macros.
  delete $::env(DESIGN_NAME)/c:*
}

if { [env_var_exists_and_non_empty SYNTH_KEEP_MODULES] } {
  puts "--- Keeping hierarchy for modules: $::env(SYNTH_KEEP_MODULES) ---"
  foreach module $::env(SYNTH_KEEP_MODULES) {
    select -module $module
    setattr -mod -set keep_hierarchy 1
    select -clear
  }
}

if { [env_var_exists_and_non_empty SYNTH_HIER_SEPARATOR] } {
  puts "--- Setting hierarchy separator to: $::env(SYNTH_HIER_SEPARATOR) ---"
  scratchpad -set flatten.separator $::env(SYNTH_HIER_SEPARATOR)
}

set synth_full_args [env_var_or_empty SYNTH_ARGS]
if { [env_var_exists_and_non_empty SYNTH_OPERATIONS_ARGS] } {
  set synth_full_args [concat $synth_full_args $::env(SYNTH_OPERATIONS_ARGS)]
} else {
  set synth_full_args [concat $synth_full_args \
    "-extra-map $::env(FLOW_HOME)/platforms/common/lcu_kogge_stone.v"]
}
if { [env_var_exists_and_non_empty SYNTH_OPT_HIER] } {
  set synth_full_args [concat $synth_full_args -hieropt]
}
puts "--- synth_full_args: $synth_full_args ---"

if { ![env_var_equals SYNTH_HIERARCHICAL 1] } {
  puts "--- Performing non-hierarchical synthesis. ---"
  # Perform standard coarse-level synthesis script, flatten right away
  synth -flatten -run :fine {*}$synth_full_args
} else {
  puts "--- Performing hierarchical synthesis. ---"
  # Perform standard coarse-level synthesis script,
  # defer flattening until we have decided what hierarchy to keep
  synth -run :fine

  if { [env_var_exists_and_non_empty SYNTH_MINIMUM_KEEP_SIZE] } {
    set ungroup_threshold $::env(SYNTH_MINIMUM_KEEP_SIZE)
    puts "Keep modules above estimated size of
      $ungroup_threshold gate equivalents"

    convert_liberty_areas
    keep_hierarchy -min_cost $ungroup_threshold
  } else {
    keep_hierarchy
  }

  # Re-run coarse-level script, this time do pass -flatten
  puts "--- Re-running synthesis with flattening. ---"
  synth -flatten -run coarse:fine {*}$synth_full_args
}

puts "--- Generating memory JSON report. ---"
json -o $::env(RESULTS_DIR)/mem.json
# Run report and check here so as to fail early if this synthesis run is doomed
exec -- $::env(PYTHON_EXE) $::env(OPENROAD_SCRIPTS_DIR)/mem_dump.py \
  --max-bits 4096 $::env(RESULTS_DIR)/mem.json

opt -fast -full
memory_map
opt -full
techmap
abc -dff -script $::env(OPENROAD_SCRIPTS_DIR)/abc_retime.script
select -clear

# Get rid of indigestibles
puts "--- Removing formal constructs and prints. ---"
chformal -remove
delete t:\$print

# rename registers to have the verilog register name in its name
# of the form \regName$_DFF_P_. We should fix yosys to make it the reg name.
# At least this is predictable.
puts "--- Renaming wires. ---"
renames -wire

# Optimize the design
puts "--- Optimizing design. ---"
opt -purge

# Technology mapping of adders
if { [env_var_exists_and_non_empty ADDER_MAP_FILE] } {
  puts "--- Mapping adders using $::env(ADDER_MAP_FILE) ---"
  # extract the full adders
  extract_fa
  # map full adders
  techmap -map $::env(ADDER_MAP_FILE)
  techmap
  # Quick optimization
  opt -fast -purge
}

# Technology mapping of latches
if { [env_var_exists_and_non_empty LATCH_MAP_FILE] } {
  puts "--- Mapping latches using $::env(LATCH_MAP_FILE) ---"
  techmap -map $::env(LATCH_MAP_FILE)
}

# Technology mapping of flip-flops
# dfflibmap only supports one liberty file
puts "--- Mapping flip-flops. ---"
if { [env_var_exists_and_non_empty DFF_LIB_FILE] } {
  dfflibmap -liberty $::env(DFF_LIB_FILE) {*}$lib_dont_use_args
} else {
  dfflibmap {*}$lib_args {*}$lib_dont_use_args
}
opt

# Replace undef values with defined constants
puts "--- Replacing undef values. ---"
setundef -zero

if {
  ![env_var_exists_and_non_empty SYNTH_WRAPPED_OPERATORS] &&
  ![env_var_exists_and_non_empty SWAP_ARITH_OPERATORS]
} {
  puts "--- Running standard ABC. ---"
  log_cmd abc {*}$abc_args
} else {
  puts "--- Running ABC for wrapped operators. ---"
  scratchpad -set abc9.script $::env(OPENROAD_SCRIPTS_DIR)/abc_speed_gia_only.script
  # crop out -script from arguments
  set abc_args [lrange $abc_args 2 end]
  log_cmd abc_new {*}$abc_args
  delete {t:$specify*}
}

# Splitting nets resolves unwanted compound assign statements in
# netlist (assign {..} = {..})
puts "--- Splitting nets. ---"
splitnets

# Remove unused cells and wires
puts "--- Cleaning up unused cells and wires. ---"
opt_clean -purge

# Technology mapping of constant hi- and/or lo-drivers
puts "--- Mapping hi/lo drivers. ---"
hilomap -singleton \
  -hicell {*}$::env(TIEHI_CELL_AND_PORT) \
  -locell {*}$::env(TIELO_CELL_AND_PORT)

# Insert buffer cells for pass through wires
puts "--- Inserting buffers. ---"
insbuf -buf {*}$::env(MIN_BUF_CELL_AND_PORTS)

# Reports
puts "--- Generating reports. ---"
tee -o $::env(REPORTS_DIR)/synth_check.txt check

tee -o $::env(REPORTS_DIR)/synth_stat.txt stat {*}$lib_args

# check the design is composed exclusively of target cells, and
# check for other problems
puts "--- Checking design. ---"
if {
  ![env_var_exists_and_non_empty SYNTH_WRAPPED_OPERATORS] &&
  ![env_var_exists_and_non_empty SWAP_ARITH_OPERATORS]
} {
  check -assert -mapped
} else {
  # Wrapped operator synthesis leaves around $buf cells which `check -mapped`
  # gets confused by, once Yosys#4931 is merged we can remove this branch and
  # always run `check -assert -mapped`
  check -assert
}

select -list a:keep_hierarchy
select -list A:keep_hierarchy
setattr -unset keep_hierarchy a:keep_hierarchy
setattr -mod -unset keep_hierarchy A:keep_hierarchy
flatten
clean -purge

# Write synthesized design
puts "--- Writing synthesized Verilog. ---"
write_verilog -nohex -nodec $::env(RESULTS_DIR)/1_synth.v
# One day a more sophisticated synthesis will write out a modified
# .sdc file after synthesis. For now, just copy the input .sdc file,
# making synthesis more consistent with other stages.
log_cmd exec cp $::env(SDC_FILE) $::env(RESULTS_DIR)/1_synth.sdc
puts "--- Finished synth.tcl ---"
