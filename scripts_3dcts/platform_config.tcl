# Platform adapter for the isolated 3DCTS stage.
#
# Current TaiWei platform files intentionally remain unchanged.  The original
# 3DCTS flow expected CTS_BUF_BOTTOM and CTS_BUF_UPPER in its platform config;
# derive those private inputs here and validate them against the LEF view that
# ord-cts-3d actually loaded.

proc dcts_env_default {name value} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    set ::env($name) $value
  }
}

set dcts_platform ""
if {[info exists ::env(PLATFORM)]} {
  set dcts_platform $::env(PLATFORM)
} elseif {[info exists ::env(PLATFORM_DIR)]} {
  set dcts_platform [file tail [file normalize $::env(PLATFORM_DIR)]]
}

switch -- $dcts_platform {
  asap7_3D {
    dcts_env_default HETEROGENEOUS_3D 0
    dcts_env_default CTS_BUF_BOTTOM \
      "BUFx4_ASAP7_75t_R_bottom BUFx8_ASAP7_75t_R_bottom"
    dcts_env_default CTS_BUF_UPPER \
      "BUFx4_ASAP7_75t_R_upper BUFx8_ASAP7_75t_R_upper"
  }
  nangate45_3D {
    dcts_env_default HETEROGENEOUS_3D 0
    dcts_env_default CTS_BUF_BOTTOM "BUF_X4_bottom"
    dcts_env_default CTS_BUF_UPPER "BUF_X4_upper"
  }
  asap7_nangate45_3D {
    dcts_env_default HETEROGENEOUS_3D 1
    dcts_env_default CTS_BUF_BOTTOM "BUF_X4_bottom"
    dcts_env_default CTS_BUF_UPPER "BUFx4_ASAP7_75t_R_upper"
  }
  default {
    dcts_env_default HETEROGENEOUS_3D 0
    if {![info exists ::env(CTS_BUF_CELL)] || $::env(CTS_BUF_CELL) eq ""} {
      error "3DCTS has no buffer mapping for platform '$dcts_platform'; set CTS_BUF_CELL, CTS_BUF_BOTTOM and CTS_BUF_UPPER"
    }
    set dcts_root [lindex $::env(CTS_BUF_CELL) 0]
    if {[string match "*_bottom" $dcts_root]} {
      dcts_env_default CTS_BUF_BOTTOM $dcts_root
      dcts_env_default CTS_BUF_UPPER [string map {_bottom _upper} $dcts_root]
    } elseif {[string match "*_upper" $dcts_root]} {
      dcts_env_default CTS_BUF_UPPER $dcts_root
      dcts_env_default CTS_BUF_BOTTOM [string map {_upper _bottom} $dcts_root]
    } else {
      error "Cannot derive tier buffers from CTS_BUF_CELL='$dcts_root' on platform '$dcts_platform'"
    }
  }
}

if {![info exists ::env(CTS_BUF_CELL)] || $::env(CTS_BUF_CELL) eq ""} {
  set dcts_owner [expr {[info exists ::env(CTS_LAYER)] ? $::env(CTS_LAYER) : "bottom"}]
  if {$dcts_owner eq "upper"} {
    set ::env(CTS_BUF_CELL) [lindex $::env(CTS_BUF_UPPER) 0]
  } else {
    set ::env(CTS_BUF_CELL) [lindex $::env(CTS_BUF_BOTTOM) 0]
  }
}

set dcts_db [ord::get_db]
foreach dcts_var {CTS_BUF_CELL CTS_BUF_BOTTOM CTS_BUF_UPPER} {
  if {![info exists ::env($dcts_var)] || $::env($dcts_var) eq ""} {
    error "3DCTS buffer configuration '$dcts_var' is empty"
  }
  foreach dcts_master $::env($dcts_var) {
    set dcts_db_master [$dcts_db findMaster $dcts_master]
    if {$dcts_db_master eq "NULL" || $dcts_db_master eq ""} {
      error "3DCTS master '$dcts_master' from $dcts_var is absent from the loaded LEF view"
    }
  }
}

puts "INFO(3DCTS): platform=$dcts_platform heterogeneous=$::env(HETEROGENEOUS_3D)"
puts "INFO(3DCTS): root=$::env(CTS_BUF_CELL)"
puts "INFO(3DCTS): bottom_buffers=$::env(CTS_BUF_BOTTOM)"
puts "INFO(3DCTS): upper_buffers=$::env(CTS_BUF_UPPER)"
