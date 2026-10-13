set coupled_l2_rtl_path [file dirname [info script]]
set vlog_defines [list SYNTHESIS]
set vlog_files {}

set file_list [open [file join $coupled_l2_rtl_path compile.f] r]
while {[gets $file_list line] >= 0} {
  set line [string trim $line]
  if {$line eq "" || [string match "#*" $line]} {
    continue
  }
  if {[string match "RTL/*" $line]} {
    set line [string range $line 4 end]
  }
  lappend vlog_files [file join $coupled_l2_rtl_path $line]
}
close $file_list

set top_module CoupledL2
