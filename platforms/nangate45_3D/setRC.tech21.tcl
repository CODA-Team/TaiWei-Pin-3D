# Liberty units are fF,kOhm (values per um).
# Fitted from swerv_wrapper base_ord 6_final.def + 6_final.spef. The SPEF was
# extracted with the Innovus-derived NangateOpenCellLibrary.tech.rcx_patterns.rules.
# Method: NNLS over ~95k nets; C R^2=0.97, R R^2=1.00.
# Bottom-tier fits are used for both tiers, since the upper tier is the same
# process and has far less routing to fit from.
# M1 carries no routed wire, so its R is kept and its C is set to 1.1x M2.
set_layer_rc -layer M1  -resistance 5.4286e-03 -capacitance 1.96e-01
set_layer_rc -layer M2  -resistance 3.6025e-03 -capacitance 1.780e-01
set_layer_rc -layer M3  -resistance 3.5772e-03 -capacitance 1.741e-01
set_layer_rc -layer M4  -resistance 1.4981e-03 -capacitance 1.876e-01
set_layer_rc -layer M5  -resistance 1.4986e-03 -capacitance 1.847e-01
set_layer_rc -layer M6  -resistance 1.4981e-03 -capacitance 1.703e-01
set_layer_rc -layer M7  -resistance 1.8470e-04 -capacitance 2.052e-01
set_layer_rc -layer M8  -resistance 1.8620e-04 -capacitance 1.870e-01
set_layer_rc -layer M9  -resistance 3.6700e-05 -capacitance 2.558e-01
set_layer_rc -layer M10 -resistance 3.6600e-05 -capacitance 2.365e-01
set_layer_rc -layer M1_m -resistance 5.4286e-03 -capacitance 1.96e-01
set_layer_rc -layer M2_m -resistance 3.6025e-03 -capacitance 1.780e-01
set_layer_rc -layer M3_m -resistance 3.5772e-03 -capacitance 1.741e-01
set_layer_rc -layer M4_m -resistance 1.4981e-03 -capacitance 1.876e-01
set_layer_rc -layer M5_m -resistance 1.4986e-03 -capacitance 1.847e-01
set_layer_rc -layer M6_m -resistance 1.4981e-03 -capacitance 1.703e-01
set_layer_rc -layer M7_m -resistance 1.8470e-04 -capacitance 2.052e-01
set_layer_rc -layer M8_m -resistance 1.8620e-04 -capacitance 1.870e-01
set_layer_rc -layer M9_m -resistance 3.6700e-05 -capacitance 2.558e-01

set_layer_rc -via via1 -resistance 5.15e-03
set_layer_rc -via via2 -resistance 5.30e-03
set_layer_rc -via via3 -resistance 5.31e-03
set_layer_rc -via via4 -resistance 3.15e-03
set_layer_rc -via via5 -resistance 3.25e-03
set_layer_rc -via via6 -resistance 3.12e-03
set_layer_rc -via via7 -resistance 8.9e-04
set_layer_rc -via via8 -resistance 8.8e-04
set_layer_rc -via via9 -resistance 5.4e-04
set_layer_rc -via hb_layer -resistance 2.96e-03
set_layer_rc -via via8_m -resistance 8.8e-04
set_layer_rc -via via7_m -resistance 8.9e-04
set_layer_rc -via via6_m -resistance 3.12e-03
set_layer_rc -via via5_m -resistance 3.25e-03
set_layer_rc -via via4_m -resistance 3.15e-03
set_layer_rc -via via3_m -resistance 5.31e-03
set_layer_rc -via via2_m -resistance 5.30e-03
set_layer_rc -via via1_m -resistance 5.15e-03

# Placement-stage estimate: average weighted by routed length on swerv (R 2.75 ohm/um, C 0.178 fF/um).
set_wire_rc -signal -resistance 2.7466e-03 -capacitance 1.780e-01
set_wire_rc -clock  -layer M5
