set rocket_gemmini_rtl_path [file dirname [info script]]
set filelist_path [file join $rocket_gemmini_rtl_path compile.f]
set filelist_handle [open $filelist_path r]
set vlog_files [list]
set vlog_defines [list SYNTHESIS]

foreach source [split [read $filelist_handle] "\n"] {
    set source [string trim $source]
    if {$source ne "" && ![string match "#*" $source]} {
        if {[string match "RTL/*" $source]} {
            set source [string range $source 4 end]
        }
        lappend vlog_files [file join $rocket_gemmini_rtl_path $source]
    }
}
close $filelist_handle

set top_module DigitalTop
