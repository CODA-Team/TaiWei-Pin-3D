# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# lib_setup.tcl  — common LIB/LEF setup for Genus & Innovus
# ==========================================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
puts "=== lib_setup.tcl ==="
# ---- inputs from environment (config.mk provides these) ----
set LIB_FILES   [_get LIB_FILES]
set LEF_FILES   [_get LEF_FILES]
set libdir  [_get LIB_DIR]
set lefdir  [_get LEF_DIR]
set QRC_FILE  [_get QRC_FILE]

set_db init_lib_search_path { \
  $libdir \
  $lefdir \
}

set libworst $LIB_FILES
set libbest $LIB_FILES

set lefs $LEF_FILES

puts "Setting up libraries:"
puts "  LIB_FILES: $LIB_FILES"
puts "  LEF_FILES: $LEF_FILES"

set qrc_max $QRC_FILE
set qrc_min $QRC_FILE

puts "  QRC_FILE: $QRC_FILE"

# setDesignMode -process $::env(PROCESS)
# We do this because we don't have a real 3D QRC file.
setDesignMode -process 45
