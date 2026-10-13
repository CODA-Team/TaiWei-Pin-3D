set black_parrot_rtl_path [file dirname [info script]]
set source_path [file normalize [file join $black_parrot_rtl_path .. SOURCE]]

set black_parrot_incdirs [list \
  [file join $source_path rtl bsg_ip_cores bsg_misc] \
  [file join $source_path rtl bp_common src include] \
  [file join $source_path rtl bp_fe src include] \
  [file join $source_path rtl bp_be src include] \
  [file join $source_path rtl bp_be src include bp_be_dcache] \
  [file join $source_path rtl bp_me src include v] \
]

set vlog_files [list \
  [file join $black_parrot_rtl_path physical_memory_binding.sv] \
]

set compile_file [open [file join $source_path compile.f] r]
while {[gets $compile_file line] >= 0} {
  set line [string trim $line]
  if {$line ne "" && ![string match "#*" $line]} {
    lappend vlog_files [file join $source_path $line]
  }
}
close $compile_file

lappend vlog_files [file join $source_path local black_parrot.sv]
