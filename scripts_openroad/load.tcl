proc load_design {design_file sdc_file msg} {
  if {![info exists standalone] || $standalone} {
    # Read liberty files
    puts "Reading liberty files..."
    source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
    # Read design files
    set ext [file extension $design_file]
    if {$ext == ".def"} {
      if {[info exist ::env(LEF_FILES)]} {
        foreach lef $::env(LEF_FILES) {
          read_lef $lef
        }
      }
      # read_verilog $::env(RESULTS_DIR)/$design_file
      # puts "Linking design $::env(DESIGN_NAME)..."
      # link_design $::env(DESIGN_NAME)
      read_def $::env(RESULTS_DIR)/$design_file
    } elseif {$ext == ".odb"} {
      read_db $::env(RESULTS_DIR)/$design_file
    } elseif {$ext == ".v"} {
            if {[info exist ::env(LEF_FILES)]} {
        foreach lef $::env(LEF_FILES) {
          read_lef $lef
        }
      }
      read_verilog $::env(RESULTS_DIR)/$design_file
      puts "Linking design $::env(DESIGN_NAME)..."
      link_design $::env(DESIGN_NAME)
      set def_file [file rootname $::env(RESULTS_DIR)/$design_file].def
      if {[file exists $def_file]} {
        read_def -floorplan_initialize $def_file
      }
    } else {
      error "Unrecognized input file $design_file"
    }

    # Read SDC file
    
    read_sdc $::env(RESULTS_DIR)/$sdc_file

    if [file exists $::env(PLATFORM_DIR)/derate.tcl] {
      source $::env(PLATFORM_DIR)/derate.tcl
    }

    source $::env(SET_RC_TCL)
  } else {
    puts $msg
  }
}

proc _get {name {def ""}} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $def
}
