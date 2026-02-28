# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_common.tcl — Stable pre-GR/pre-legal setup for Innovus placement
# Dependencies: utils.tcl / lib_setup.tcl / design_setup.tcl / mmmc_setup.tcl must be sourced.
# Environment Variables (Optional):
#   PAD_REGEX  : Regex for base cell names to add padding to (e.g., "BUF.*|INV.*")
#   PAD_LEFT   : Left padding in sites (default 0)
#   PAD_RIGHT  : Right padding in sites (default 0)
#   DISABLE_SCAN_REORDER : Set to 1 to disable scan reordering (default 1, more stable)
#   NON_TIMING_PLACE     : Set to 1 to disable timing-driven placement (default 0)
#   USE_PLACE_OPT        : Set to 1 to use place_opt_design (default 1)
#   USE_CONCURRENT_MACRO : Set to 1 for concurrent macro and standard cell placement (default 0; requires movable macros)
#   HONOR_INST_PAD       : Set to 1 to treat instance padding as a hard rule
#   MAX_ROUTING_LAYER / MIN_ROUTING_LAYER : Constrain routing layers
# ==========================================
# Ensure namespace exists
if {![namespace exists pc]} {
  namespace eval pc {
    namespace export setup_basic run_place
  }
}

proc pc::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

proc pc::setup_basic {} {
  # --- Threading and Analysis ---
  catch { setMultiCpuUsage -localCpu [_get NUM_CORES 16] }
  catch { set_interactive_constraint_modes {CON} }
  catch { setAnalysisMode -reset }
  catch { setAnalysisMode -analysisType onChipVariation -cppr both }

  # --- Routing Layer Constraints (if set) ---
  if {[info exists ::env(MAX_ROUTING_LAYER)]} { catch { setDesignMode -topRoutingLayer    $::env(MAX_ROUTING_LAYER) } }
  if {[info exists ::env(MIN_ROUTING_LAYER)]} { catch { setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER) } }

  # --- Legalization and Filler ---
  catch { setPlaceMode -place_detail_legalization_inst_gap 1 }
  catch { setFillerMode -fitGap true }

  # --- Scan Chain (default off, enable when flow is mature) ---
  set disable_scan [pc::_env_or DISABLE_SCAN_REORDER 1]
  catch { setPlaceMode -place_global_reorder_scan [expr {$disable_scan ? "false" : "true"}] }

  # --- Timing-Driven (can be disabled for prototyping) ---
  set non_timing [pc::_env_or NON_TIMING_PLACE 0]
  if {$non_timing} { catch { setPlaceMode -place_global_timing_effort false } }

  # --- Strictly Honor Instance Padding (Optional) ---
  if {[pc::_env_or HONOR_INST_PAD 0]} {
    catch { setPlaceMode -place_detail_honor_inst_pad true }
  }

  # --- Add instance-level padding as needed ---
  set pad_l   [pc::_env_or PAD_LEFT  0]
  set pad_r   [pc::_env_or PAD_RIGHT 0]
  set pad_rxp [pc::_env_or PAD_REGEX ""]
  if {($pad_l>0 || $pad_r>0) && $pad_rxp ne ""} {
    puts "INFO\[pc\]: Applying inst padding L=$pad_l R=$pad_r on regex: $pad_rxp"
    # Filter using get_db; attribute names may differ between versions, provide fallback
    set sel {}
    # Priority: base cell name
    catch { set sel [get_db insts -if {.[baseCell].name =~ $pad_rxp}] }
    # Fallback: libcell name path (older versions)
    if {[llength $sel] == 0} {
      catch { set sel [get_db insts -if {.[cell].name =~ $pad_rxp}] }
    }
    if {[llength $sel] > 0} {
      catch { setInstPad $sel -left $pad_l -right $pad_r }
    } else {
      puts "WARN\[pc\]: No insts matched PAD_REGEX='$pad_rxp' — padding skipped."
    }
  }
}

# Single-step: place_opt_design (recommended)
proc pc::run_place {} {
  set use_pod           [pc::_env_or USE_PLACE_OPT 1]
  set do_concurrent_mac [pc::_env_or USE_CONCURRENT_MACRO 0]

  if {$do_concurrent_mac} {
    puts "INFO\[pc\]: place_design -concurrent_macros"
    catch { place_design -concurrent_macros } msg
    if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  } else {
    puts "INFO\[pc\]: Skip concurrent_macros (disabled or no movable macros)."
  }

  if {$use_pod} {
    puts "INFO\[pc\]: place_opt_design (integrated preCTS opt)"
    # Report directory/prefix might be defined in your design script; provide a compatible fallback
    set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
    file mkdir $reports_dir
    catch { place_opt_design -out_dir $reports_dir -prefix prects } msg
    if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  } else {
    puts "INFO\[pc\]: classic flow: place_design + optDesign -preCTS"
    catch { place_design }
    catch { optDesign -preCTS }
  }

  catch { checkPlace }
}
