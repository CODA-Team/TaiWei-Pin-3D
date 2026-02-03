#######################################################
#                                                     
#  Innovus Command Logging File                     
#  Created on Thu Nov  6 19:57:28 2025                
#                                                     
#######################################################

#@(#)CDS: Innovus v21.39-s058_1 (64bit) 04/04/2024 09:59 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: NanoRoute 21.39-s058_1 NR231113-0413/21_19-UB (database version 18.20.605_1) {superthreading v2.17}
#@(#)CDS: AAE 21.19-s004 (64bit) 04/04/2024 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: CTE 21.19-s010_1 () Mar 27 2024 01:55:37 ( )
#@(#)CDS: SYNTECH 21.19-s002_1 () Sep  6 2023 22:17:00 ( )
#@(#)CDS: CPE v21.19-s026
#@(#)CDS: IQuantus/TQuantus 21.1.1-s966 (64bit) Wed Mar 8 10:22:20 PST 2023 (Linux 3.10.0-693.el7.x86_64)

set_global _enable_mmmc_by_default_flow      $CTE::mmmc_default
suppressMessage ENCEXT-2799
getVersion
create_library_set -name WC_LIB -timing $lib_list
create_library_set -name BC_LIB -timing $lib_list
create_rc_corner -name Cmax
create_rc_corner -name Cmin
create_delay_corner -name WC -library_set WC_LIB -rc_corner Cmax
create_delay_corner -name BC -library_set BC_LIB -rc_corner Cmin
create_constraint_mode -name CON -sdc_file $sdc
create_analysis_view -name WC_VIEW -delay_corner WC -constraint_mode CON
create_analysis_view -name BC_VIEW -delay_corner BC -constraint_mode CON
set init_pwr_net VDD
set init_gnd_net VSS
set init_verilog ./1_synth.v
set init_design_netlisttype Verilog
set init_design_settop 1
set init_top_cell top_mixed
set init_lef_file {./nangate45_asap7_2M1P2M.lef ../lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef ../lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef}
setMultiCpuUsage -localCpu 8
init_design -setup WC_VIEW -hold BC_VIEW
clearGlobalNets
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi -inst * -override
globalNetConnect VSS -type tielo -inst * -override
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
floorPlan -r 1.0 0.40 0.2 0.2 0.2 0.2
editPin -layer Pad_mid -pin {CLK A B C Y 0x0 0x0 0x0 0x0} -side LEFT -spreadType SIDE -snap TRACK -fixOverlap 1 -fixedPin
place_design
defOut -floorplan ./2_floorplan.def
saveNetlist ./2_floorplan.v
deleteRow -site asap7sc7p5t
floorPlan -b 0.0 0.0 2.376 2.052 0.0 0.0 2.376 2.052 0.216 0.216 2.16 1.836 -siteOnly asap7sc7p5t
defOut -floorplan ./variant_small.def
deleteRow -site asap7sc7p5t
floorPlan -b 0.0 0.0 2.376 2.052 0.0 0.0 2.376 2.052 0.216 0.216 2.16 1.836 -siteOnly FreePDK45_38x28_10R_NP_162NW_34O
defOut -floorplan ./variant_big.def
win
fit
fit
place_design
win
setLayerPreference violation -isVisible 0
setLayerPreference violation -isVisible 1
setLayerPreference violation -isVisible 0
fit
defIn variant_small.def
setLayerPreference violation -isVisible 1
place_design
