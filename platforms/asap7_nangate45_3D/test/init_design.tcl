set RESULTS_DIR "."
set OBJECTS_DIR "."
set REPORTS_DIR "."
set LOG_DIR     "."

proc _must_exist {path msg} { if {![file exists $path]} { error $msg } }

proc box_flat4 {box} {
  if {[llength $box] == 1} { set box [lindex $box 0] }
  if {[llength $box] == 2 && [llength [lindex $box 0]] == 2} {
    set ll [lindex $box 0]; set ur [lindex $box 1]
    return [list [lindex $ll 0] [lindex $ll 1] [lindex $ur 0] [lindex $ur 1]]
  }
  return $box
}

set lef_list {}
lappend lef_list "./nangate45_asap7_2M1P2M.lef"
lappend lef_list "../lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef"
lappend lef_list "../lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef"

puts "LEF list:"; foreach f $lef_list { puts "  $f" }

set lib_list {}
lappend lib_list "../lib_upper/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.upper.lib"
lappend lib_list "../lib_upper/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.upper.lib"
lappend lib_list "../lib_upper/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.upper.lib"
lappend lib_list "../lib_upper/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.upper.lib"
lappend lib_list "../lib_upper/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.upper.lib"
lappend lib_list "../lib_bottom/NangateOpenCellLibrary_typical.bottom.lib"

puts "LIB list:"; foreach f $lib_list { puts "  $f" }

set netlist "./1_synth.v"
set sdc     "./1_synth.sdc"
set DESIGN  "top_mixed"
_must_exist $netlist "Missing netlist: $netlist"
_must_exist $sdc     "Missing sdc: $sdc"
puts "DESIGN: $DESIGN"

set_db init_lib_search_path [list . ../lib_bottom ../lib_upper ../lef_bottom ../lef_upper]

if {[llength $lib_list] > 0} {
  create_library_set -name WC_LIB -timing $lib_list
  create_library_set -name BC_LIB -timing $lib_list
} else {
  create_library_set -name WC_LIB
  create_library_set -name BC_LIB
}
create_rc_corner -name Cmax
create_rc_corner -name Cmin
create_delay_corner -name WC -library_set WC_LIB -rc_corner Cmax
create_delay_corner -name BC -library_set BC_LIB -rc_corner Cmin
create_constraint_mode -name CON -sdc_file $sdc
create_analysis_view -name WC_VIEW -delay_corner WC -constraint_mode CON
create_analysis_view -name BC_VIEW -delay_corner BC -constraint_mode CON

set init_pwr_net  VDD
set init_gnd_net  VSS
set init_verilog  $netlist
set init_design_netlisttype "Verilog"
set init_design_settop 1
set init_top_cell $DESIGN
set init_lef_file $lef_list
setMultiCpuUsage -localCpu 8

puts "Running init_design ..."
init_design -setup {WC_VIEW} -hold {BC_VIEW}

clearGlobalNets
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi -inst * -override
globalNetConnect VSS -type tielo -inst * -override
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both

set CORE_UTIL    0.40
set ASPECT_RATIO 1.0
set CORE_MARGIN  0.2
set mL $CORE_MARGIN; set mR $CORE_MARGIN; set mT $CORE_MARGIN; set mB $CORE_MARGIN
floorPlan -r $ASPECT_RATIO $CORE_UTIL $mL $mB $mR $mT

set tports [dbGet top.nets.terms.name]
if {[llength $tports] > 0} {
  catch { editPin -layer Pad_mid -pin $tports -side LEFT -spreadType SIDE -snap TRACK -fixOverlap 1 -fixedPin }
}

place_design

set DEF_BASE [file join $RESULTS_DIR "2_floorplan.def"]
set V_OUT    [file join $RESULTS_DIR "2_floorplan.v"]
defOut -floorplan $DEF_BASE
saveNetlist $V_OUT
puts "INFO: baseline floorplan written: $DEF_BASE"

# dbSet [dbGet top.insts].pStatus fixed
# dbSet [dbGet top.terms].pStatus fixed

set dieBoxF  [box_flat4 [dbGet top.fPlan.box]]
set ioBoxF   [box_flat4 [dbGet top.fPlan.ioBox]]
set coreBoxF [box_flat4 [dbGet top.fPlan.coreBox]]
puts "dieBox  = $dieBoxF"
puts "ioBox   = $ioBoxF"
puts "coreBox = $coreBoxF"

set smallSite "asap7sc7p5t"
set bigSite   "FreePDK45_38x28_10R_NP_162NW_34O"

deleteRow -site $smallSite
eval floorPlan -b $dieBoxF $ioBoxF $coreBoxF -siteOnly $smallSite
set OUT_SMALL [file join $RESULTS_DIR "variant_small.def"]
defOut -floorplan $OUT_SMALL
puts "WROTE: $OUT_SMALL (rows = $smallSite)"

deleteRow -site $smallSite
eval floorPlan -b $dieBoxF $ioBoxF $coreBoxF -siteOnly $bigSite
set OUT_BIG [file join $RESULTS_DIR "variant_big.def"]
defOut -floorplan $OUT_BIG
puts "WROTE: $OUT_BIG (rows = $bigSite)"

puts "DONE:"
puts "  baseline DEF : $DEF_BASE"
puts "  variant_small: $OUT_SMALL"
puts "  variant_big  : $OUT_BIG"
