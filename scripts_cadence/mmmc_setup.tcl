# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
puts "Setting up MMC timing libraries and corners"
create_library_set -name WC_LIB -timing $libworst
create_library_set -name BC_LIB -timing $libbest
 
# If QRC tech files exist, use them; otherwise fall back to default rc corners
if {[info exists qrc_max] && $qrc_max ne "" && [file exists $qrc_max]} {
    create_rc_corner -name Cmax -qx_tech_file $qrc_max
} else {
    create_rc_corner -name Cmax
}
if {[info exists qrc_min] && $qrc_min ne "" && [file exists $qrc_min]} {
    create_rc_corner -name Cmin -qx_tech_file $qrc_min
} else {
    create_rc_corner -name Cmin
}

create_delay_corner -name WC -library_set WC_LIB -rc_corner Cmax
create_delay_corner -name BC -library_set BC_LIB -rc_corner Cmin

create_constraint_mode -name CON -sdc_file $sdc 
create_analysis_view -name WC_VIEW -delay_corner WC -constraint_mode CON
create_analysis_view -name BC_VIEW -delay_corner BC -constraint_mode CON
