puts "--- Starting 3D-Syn coarse netlist generation ---"

source $::env(OPENROAD_SCRIPTS_DIR)/synth_preamble.tcl

set yosys_work_dir "$::env(SYN3D_COARSE_SYNTH_DIR)/yosys"
set coarse_unit_dir "$yosys_work_dir/coarse_units"
set coarse_unit_manifest "$yosys_work_dir/coarse_units.list"
file delete -force $yosys_work_dir
file mkdir $coarse_unit_dir

read_design_sources
dict for {key value} [env_var_or_empty VERILOG_TOP_PARAMS] {
  chparam -set $key $value $::env(DESIGN_NAME)
}

hierarchy -check -top $::env(DESIGN_NAME)
opt_clean -purge

if { [env_var_equals SYNTH_GUT 1] } {
  delete $::env(DESIGN_NAME)/c:*
}

if { [env_var_exists_and_non_empty SYNTH_KEEP_MODULES] } {
  foreach module $::env(SYNTH_KEEP_MODULES) {
    select -module $module
    setattr -mod -set keep_hierarchy 1
    select -clear
  }
}

if { [env_var_exists_and_non_empty SYNTH_HIER_SEPARATOR] } {
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

if { ![env_var_equals SYNTH_HIERARCHICAL 1] } {
  synth -flatten -run :fine {*}$synth_full_args
} else {
  synth -run :fine
  if { [env_var_exists_and_non_empty SYNTH_MINIMUM_KEEP_SIZE] } {
    convert_liberty_areas
    keep_hierarchy -min_cost $::env(SYNTH_MINIMUM_KEEP_SIZE)
  } else {
    keep_hierarchy
  }
  synth -flatten -run coarse:fine {*}$synth_full_args
}

set keep_mode all
if { [env_var_exists_and_non_empty SYN3D_COARSE_UNIT_KEEP_MODE] } {
  set keep_mode $::env(SYN3D_COARSE_UNIT_KEEP_MODE)
}
if { [lsearch -exact {all arithmetic multibit_ff none} $keep_mode] < 0 } {
  error "Unsupported SYN3D_COARSE_UNIT_KEEP_MODE=$keep_mode; expected all, arithmetic, multibit_ff, or none"
}

syn3d_mark_coarse_units \
  -keep $keep_mode \
  -output-dir $coarse_unit_dir \
  -manifest $coarse_unit_manifest

if { [env_var_exists_and_non_empty SYNTH_RETIME_MODULES] } {
  select $::env(SYNTH_RETIME_MODULES)
  opt -fast -full
  memory_map
  opt -full
  techmap
  abc -dff -script $::env(OPENROAD_SCRIPTS_DIR)/abc_retime.script
  select -clear
}

synth -top $::env(DESIGN_NAME) -run fine: {*}$synth_full_args

chformal -remove
delete t:\$print
renames -wire
opt -purge

if { [env_var_exists_and_non_empty ADDER_MAP_FILE] } {
  extract_fa
  techmap -map $::env(ADDER_MAP_FILE)
  techmap
  opt -fast -purge
}

if { [env_var_exists_and_non_empty LATCH_MAP_FILE] } {
  techmap -map $::env(LATCH_MAP_FILE)
}

if { [env_var_exists_and_non_empty DFF_LIB_FILE] } {
  dfflibmap -liberty $::env(DFF_LIB_FILE) {*}$lib_dont_use_args
} else {
  dfflibmap {*}$lib_args {*}$lib_dont_use_args
}
syn3d_normalize_instance_names
opt
setundef -zero

log_cmd abc {*}$abc_args
delete {t:$specify*}
splitnets
opt_clean -purge

# Keep constants as logical nets here; the whole-netlist Genus step performs
# the technology-specific constant-cell handling.
insbuf -buf {*}$::env(MIN_BUF_CELL_AND_PORTS)

tee -o $::env(REPORTS_DIR)/3dsyn_coarse_netlist_check.txt check
tee -o $::env(REPORTS_DIR)/3dsyn_coarse_netlist_stat.txt stat {*}$lib_args
check -assert -mapped

setattr -unset keep_hierarchy a:keep_hierarchy
setattr -mod -unset keep_hierarchy A:keep_hierarchy
flatten
clean -purge

write_rtlil $yosys_work_dir/coarse_netlist.rtlil
write_verilog -nohex -nodec -noattr $yosys_work_dir/coarse_netlist.v

puts "--- Coarse netlist: $yosys_work_dir/coarse_netlist.v"
puts "--- Coarse-unit manifest: $coarse_unit_manifest"
puts "--- Finished 3D-Syn coarse netlist generation ---"
