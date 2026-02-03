####################################
# global connections
####################################
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDDPE$}
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDDCE$}
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSS$} -ground
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSSE$}
global_connect
####################################
# voltage domains
####################################
set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}
####################################
# standard cell grid
####################################
define_pdn_grid -name {grid} -voltage_domains {CORE}
add_pdn_stripe -grid {grid} -layer {M1} -width {0.17} -pitch {2.4} -offset {0} -followpins
add_pdn_stripe -grid {grid} -layer {M4} -width {0.84} -pitch {20.16} -offset {2}
add_pdn_stripe -grid {grid} -layer {M7} -width {2.4} -pitch {40.0} -offset {2}
add_pdn_connect -grid {grid} -layers {M1 M4}
add_pdn_connect -grid {grid} -layers {M4 M7}
####################################
# macro grids
####################################
####################################
# grid for: CORE_macro_grid_1
####################################
# define_pdn_grid -name {CORE_macro_grid_1} -voltage_domains {CORE} -macro -orient {R0 R180 MX MY} -halo {2.0 2.0 2.0 2.0} -cells {.*}
# add_pdn_stripe -grid {CORE_macro_grid_1} -layer {M5} -width {0.93} -pitch {10.0} -offset {2}
# add_pdn_stripe -grid {CORE_macro_grid_1} -layer {M6} -width {0.93} -pitch {10.0} -offset {2}
# add_pdn_connect -grid {CORE_macro_grid_1} -layers {M4 M5}
# add_pdn_connect -grid {CORE_macro_grid_1} -layers {M5 M6}
# add_pdn_connect -grid {CORE_macro_grid_1} -layers {M6 M7}
# ####################################
# # grid for: CORE_macro_grid_2
# ####################################
# define_pdn_grid -name {CORE_macro_grid_2} -voltage_domains {CORE} -macro -orient {R90 R270 MXR90 MYR90} -halo {2.0 2.0 2.0 2.0} -cells {.*}
# add_pdn_stripe -grid {CORE_macro_grid_2} -layer {M6} -width {0.93} -pitch {40.0} -offset {2}
# add_pdn_connect -grid {CORE_macro_grid_2} -layers {M4 M6}
# add_pdn_connect -grid {CORE_macro_grid_2} -layers {M6 M7}
