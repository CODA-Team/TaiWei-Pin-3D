# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.

if {[info exists ::env(PROCESS)] && $::env(PROCESS) == 7} {
  puts "  PROCESS=7 detected, setting library units: time=1ps"
  setLibraryUnit -time 1ps
}

puts "Setting up MMC timing libraries and corners"
create_library_set -name WC_LIB -timing $libworst
create_library_set -name BC_LIB -timing $libbest
 
# Never silently replace a requested QRC model with an approximate model.
set cds_rc_mode [string tolower [_get CDS_RC_MODE qrc]]
if {$cds_rc_mode ni {qrc lef}} {
    error "CDS_RC_MODE must be qrc or lef; got '$cds_rc_mode'"
}
foreach {corner variable} {Cmax qrc_max Cmin qrc_min} {
    if {$cds_rc_mode eq "qrc"} {
        if {![info exists $variable] || [set $variable] eq "" || ![file isfile [set $variable]]} {
            error "Requested QRC extraction but $variable is missing. Supply a validated technology file or explicitly set CDS_RC_MODE=lef for approximate research evaluation."
        }
        create_rc_corner -name $corner -qx_tech_file [set $variable]
    } else {
        puts "WARN(RC): $corner explicitly uses approximate LEF/basic RC; not a validated 3D QRC model."
        create_rc_corner -name $corner
    }
}

create_delay_corner -name WC -library_set WC_LIB -rc_corner Cmax
create_delay_corner -name BC -library_set BC_LIB -rc_corner Cmin

set resolved_sdc ""
if {[info exists sdc] && $sdc ne ""} {
    set resolved_sdc $sdc
} elseif {[info exists SDC_IN] && $SDC_IN ne ""} {
    set resolved_sdc $SDC_IN
}
if {$resolved_sdc eq ""} {
    error "MMMC setup requires a non-empty SDC path (variables 'sdc' or 'SDC_IN')."
}
if {![file exists $resolved_sdc]} {
    error "MMMC setup is missing the required SDC file: $resolved_sdc"
}
set sdc $resolved_sdc
create_constraint_mode -name CON -sdc_files [list $sdc]
create_analysis_view -name WC_VIEW -delay_corner WC -constraint_mode CON
create_analysis_view -name BC_VIEW -delay_corner BC -constraint_mode CON
