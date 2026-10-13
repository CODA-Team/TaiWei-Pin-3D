set black_parrot_rtl_path [file dirname [info script]]
set source_path [file normalize [file join $black_parrot_rtl_path .. SOURCE]]

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

# Collect include search dirs from the listed source parents so bare
# `include headers such as bsg_defines.svh resolve. The uniform read_rtl hook
# automatically passes any *_incdirs variable it finds to set_verilog_file.
set black_parrot_incdirs [list]
foreach _f $vlog_files {
  set _d [file dirname $_f]
  if {[lsearch -exact $black_parrot_incdirs $_d] < 0} {
    lappend black_parrot_incdirs $_d
  }
}
