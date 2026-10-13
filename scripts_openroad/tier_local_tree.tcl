# ============================================================
# tier_local_tree.tcl
# Build physically clustered, tier-pure buffer trees on both local domains of
# every dual-boundary split net.
#
# The immutable cross-tier interface remains:
#   source boundary buffer -> point-to-point bridge -> destination boundary
#
# Local trees are ordinary buffers, intentionally left mutable so the resizer
# can size, clone, or refine them during the active-tier optimization pass.
# For a high-fanout BTerm driver, the source tree is forced to one local root;
# consequently the original port net directly drives only that root and the
# source boundary buffer.
# ============================================================

if {![llength [info commands pin3d_read_split_manifest]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
}
if {![llength [info commands ::tier_split_or2::choose_buffer_master]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/split_net.tcl
}

namespace eval ::pin3d_local_tree {
  variable tree_serial 0
}

proc ::pin3d_local_tree::env_flag {name default_value} {
  if {![info exists ::env($name)] || [string trim $::env($name)] eq ""} {
    return $default_value
  }
  set value [string tolower [string trim $::env($name)]]
  return [expr {$value ni {0 false off no disabled}}]
}

proc ::pin3d_local_tree::env_positive_int {name default_value} {
  if {![info exists ::env($name)] || [string trim $::env($name)] eq ""} {
    return $default_value
  }
  set value [string trim $::env($name)]
  if {![string is integer -strict $value] || $value < 1} {
    puts "WARN(OR): $name='$value' is not a positive integer; using $default_value"
    return $default_value
  }
  return $value
}

proc ::pin3d_local_tree::iterm_record {iterm} {
  set inst [$iterm getInst]
  set loc [$inst getLocation]
  set x [lindex $loc 0]
  set y [lindex $loc 1]
  if {$x eq ""} { set x 0 }
  if {$y eq ""} { set y 0 }
  return [list $x $y [_pin3d_iterm_full_name $iterm] $iterm]
}

proc ::pin3d_local_tree::compare_x {left right} {
  set cmp [expr {[lindex $left 0] < [lindex $right 0] ? -1 : ([lindex $left 0] > [lindex $right 0] ? 1 : 0)}]
  if {$cmp != 0} { return $cmp }
  set cmp [expr {[lindex $left 1] < [lindex $right 1] ? -1 : ([lindex $left 1] > [lindex $right 1] ? 1 : 0)}]
  if {$cmp != 0} { return $cmp }
  return [string compare [lindex $left 2] [lindex $right 2]]
}

proc ::pin3d_local_tree::compare_y {left right} {
  set cmp [expr {[lindex $left 1] < [lindex $right 1] ? -1 : ([lindex $left 1] > [lindex $right 1] ? 1 : 0)}]
  if {$cmp != 0} { return $cmp }
  set cmp [expr {[lindex $left 0] < [lindex $right 0] ? -1 : ([lindex $left 0] > [lindex $right 0] ? 1 : 0)}]
  if {$cmp != 0} { return $cmp }
  return [string compare [lindex $left 2] [lindex $right 2]]
}

proc ::pin3d_local_tree::spatial_groups {records max_group_size} {
  set count [llength $records]
  if {$count == 0} {
    return {}
  }

  set min_x [lindex [lindex $records 0] 0]
  set max_x $min_x
  set min_y [lindex [lindex $records 0] 1]
  set max_y $min_y
  foreach record $records {
    set x [lindex $record 0]
    set y [lindex $record 1]
    if {$x < $min_x} { set min_x $x }
    if {$x > $max_x} { set max_x $x }
    if {$y < $min_y} { set min_y $y }
    if {$y > $max_y} { set max_y $y }
  }
  if {[expr {$max_x - $min_x}] >= [expr {$max_y - $min_y}]} {
    set sorted [lsort -command ::pin3d_local_tree::compare_x $records]
  } else {
    set sorted [lsort -command ::pin3d_local_tree::compare_y $records]
  }

  set group_count [expr {int(ceil(double($count) / double($max_group_size)))}]
  set base_size [expr {$count / $group_count}]
  set remainder [expr {$count % $group_count}]
  set groups {}
  set begin 0
  for {set group_idx 0} {$group_idx < $group_count} {incr group_idx} {
    set group_size [expr {$base_size + ($group_idx < $remainder ? 1 : 0)}]
    set end [expr {$begin + $group_size - 1}]
    lappend groups [lrange $sorted $begin $end]
    set begin [expr {$end + 1}]
  }
  return $groups
}

proc ::pin3d_local_tree::direct_domain_loads {net tier excluded_inst_names} {
  array set excluded {}
  foreach inst_name $excluded_inst_names {
    set excluded($inst_name) 1
  }

  set loads {}
  foreach iterm [$net getITerms] {
    set mterm [$iterm getMTerm]
    if {[_pin3d_safe_sigtype_from_mterm $mterm] in {POWER GROUND}} {
      continue
    }
    if {[_pin3d_safe_iotype_from_mterm $mterm] ne "INPUT"} {
      continue
    }
    set inst [$iterm getInst]
    set inst_name [$inst getName]
    if {[info exists excluded($inst_name)]} {
      continue
    }
    set inst_tier [_or_inst_tier $inst]
    if {$inst_tier eq "split_buffer"} {
      set inst_tier [_or_split_buffer_physical_tier $inst]
    }
    if {$inst_tier eq $tier} {
      lappend loads $iterm
    }
  }
  return $loads
}

# Return the mutable, same-tier loads that may be moved below an existing
# buffer output while repairing a buffer cone.  Split buffers form the fixed
# cross-tier interface and must remain connected to their current root net.
proc ::pin3d_local_tree::recursive_domain_loads {net tier} {
  set loads {}
  foreach iterm [::pin3d_local_tree::direct_domain_loads $net $tier {}] {
    set inst [$iterm getInst]
    if {[_or_inst_tier $inst] eq "split_buffer" ||
        [_or_is_split_buffer_name [$inst getName]]} {
      continue
    }
    lappend loads $iterm
  }
  return $loads
}

proc ::pin3d_local_tree::net_is_dont_touch {net} {
  if {[catch {set dont_touch [$net isDoNotTouch]}]} {
    return 0
  }
  return $dont_touch
}

proc ::pin3d_local_tree::compare_cone_depth_desc {left right} {
  set left_depth [lindex $left 0]
  set right_depth [lindex $right 0]
  if {$left_depth > $right_depth} { return -1 }
  if {$left_depth < $right_depth} { return 1 }
  return [string compare [lindex $left 1] [lindex $right 1]]
}

# Collect all nets reached by following ordinary same-tier buffers from a
# manifest domain root.  The walk intentionally stops at logic, inverters,
# clock/tie buffers, split buffers, and the opposite tier.  Collection happens
# before repair so newly-created trees cannot make the traversal unbounded.
proc ::pin3d_local_tree::collect_buffer_cone_nets {root_net tier max_depth report_fh} {
  array set visited {}
  set queue [list [list 0 $root_net]]
  set queue_idx 0
  set records {}

  while {$queue_idx < [llength $queue]} {
    lassign [lindex $queue $queue_idx] depth net
    incr queue_idx
    if {$net eq "" || $net eq "NULL"} {
      continue
    }
    set net_name [$net getName]
    if {[info exists visited($net_name)]} {
      continue
    }
    set visited($net_name) 1
    lappend records [list $depth $net_name $net]

    if {$depth >= $max_depth} {
      puts $report_fh "  CONE_LIMIT net=$net_name depth=$depth max_depth=$max_depth"
      continue
    }

    foreach load [::pin3d_local_tree::recursive_domain_loads $net $tier] {
      set inst [$load getInst]
      if {[_or_inst_tier $inst] ne $tier} {
        continue
      }
      set buffer_io [_pin3d_buffer_inst_io $inst 0]
      if {$buffer_io eq ""} {
        continue
      }
      set output_net [_pin3d_iterm_net [dict get $buffer_io output]]
      if {$output_net eq "" || $output_net eq "NULL"} {
        continue
      }
      set sig_type [$output_net getSigType]
      if {$sig_type in {POWER GROUND CLOCK}} {
        continue
      }
      lappend queue [list [expr {$depth + 1}] $output_net]
    }
  }
  return $records
}

proc ::pin3d_local_tree::group_centroid {group} {
  set sum_x 0.0
  set sum_y 0.0
  foreach record $group {
    set sum_x [expr {$sum_x + double([lindex $record 0])}]
    set sum_y [expr {$sum_y + double([lindex $record 1])}]
  }
  set count [llength $group]
  return [list [expr {round($sum_x / $count)}] [expr {round($sum_y / $count)}]]
}

proc ::pin3d_local_tree::create_parent_buffer {block root_net group tier label level branch_idx report_fh} {
  variable tree_serial
  incr tree_serial

  set load_count [llength $group]
  set buffer_info [::tier_split_or2::choose_buffer_master $tier $load_count]
  if {$buffer_info eq ""} {
    error "No usable $tier buffer master for PIN3D local tree '$label'"
  }
  lassign $buffer_info master_name input_pin output_pin _ chosen_drive required_drive
  set master [::tier_split_or2::find_master_by_name $master_name]
  if {$master eq "" || $master eq "NULL"} {
    error "Cannot find local-tree buffer master '$master_name'"
  }

  set safe_label [::tier_split_or2::sanitize_name_component $label]
  set stem "${safe_label}__PIN3D_LTREE_${tier}_L${level}_B${branch_idx}"
  set inst_name [::tier_split_or2::ensure_unique_name $block $stem]
  set child_net_name [::tier_split_or2::ensure_unique_name $block "${stem}_NET"]
  set inst [odb::dbInst_create $block $master $inst_name]
  if {$inst eq "" || $inst eq "NULL"} {
    error "Failed to create local-tree buffer '$inst_name'"
  }
  set child_net [odb::dbNet_create $block $child_net_name]
  if {$child_net eq "" || $child_net eq "NULL"} {
    catch {delete_instance $inst_name}
    error "Failed to create local-tree net '$child_net_name'"
  }
  catch {$child_net setSigType [$root_net getSigType]}

  set input_iterm [$inst findITerm $input_pin]
  set output_iterm [$inst findITerm $output_pin]
  if {$input_iterm eq "" || $output_iterm eq ""} {
    catch {delete_instance $inst_name}
    catch {::odb::dbNet_destroy $child_net}
    error "Cannot find $master_name local-tree pins $input_pin/$output_pin"
  }

  lassign [::pin3d_local_tree::group_centroid $group] x y
  $inst setLocation $x $y
  set anchor_iterm [lindex [lindex $group 0] 3]
  set anchor_inst [$anchor_iterm getInst]
  catch {$inst setOrient [$anchor_inst getOrient]}
  catch {$inst setPlacementStatus PLACED}

  $input_iterm connect $root_net
  $output_iterm connect $child_net
  foreach record $group {
    set load_iterm [lindex $record 3]
    $load_iterm connect $child_net
  }

  set ::_PIN3D_INST_CACHE($inst_name) $inst
  set ::_PIN3D_NET_CACHE($child_net_name) $child_net
  set ::_PIN3D_ITERM_CACHE([_pin3d_iterm_full_name $input_iterm]) $input_iterm
  set ::_PIN3D_ITERM_CACHE([_pin3d_iterm_full_name $output_iterm]) $output_iterm

  puts $report_fh "  BUFFER level=$level branch=$branch_idx inst=$inst_name master=$master_name loads=$load_count chosen_drive=$chosen_drive required_drive=$required_drive x=$x y=$y net=$child_net_name"
  return [list $x $y [_pin3d_iterm_full_name $input_iterm] $input_iterm]
}

proc ::pin3d_local_tree::build_domain_tree {block root_net loads tier label force_single_root min_fanout branch_factor report_fh} {
  set direct_fanout [llength $loads]
  if {$direct_fanout < $min_fanout} {
    puts $report_fh "DOMAIN label=$label tier=$tier root_net=[$root_net getName] direct_fanout=$direct_fanout action=skip_below_threshold threshold=$min_fanout"
    return [dict create built 0 buffers 0 levels 0 direct_fanout $direct_fanout]
  }

  puts $report_fh "DOMAIN label=$label tier=$tier root_net=[$root_net getName] direct_fanout=$direct_fanout action=build force_single_root=$force_single_root branch_factor=$branch_factor"
  set current {}
  foreach load $loads {
    lappend current [::pin3d_local_tree::iterm_record $load]
  }

  set level 0
  set buffer_count 0
  while {1} {
    incr level
    set parent_inputs {}
    set branch_idx 0
    foreach group [::pin3d_local_tree::spatial_groups $current $branch_factor] {
      lappend parent_inputs [::pin3d_local_tree::create_parent_buffer \
        $block $root_net $group $tier $label $level $branch_idx $report_fh]
      incr buffer_count
      incr branch_idx
    }
    set current $parent_inputs
    if {[llength $current] <= $branch_factor} {
      break
    }
  }

  if {$force_single_root && [llength $current] > 1} {
    incr level
    set current [list [::pin3d_local_tree::create_parent_buffer \
      $block $root_net $current $tier $label $level 0 $report_fh]]
    incr buffer_count
  }

  puts $report_fh "DOMAIN_DONE label=$label buffers=$buffer_count levels=$level root_loads=[llength $current]"
  return [dict create built 1 buffers $buffer_count levels $level direct_fanout $direct_fanout root_loads [llength $current]]
}

# Preserve the existing buffer cone and repair only overloaded output nets.
# Processing deepest nets first avoids changing connectivity that is still
# needed to discover descendants.  The build itself is idempotent: after a net
# is repaired its direct fanout is at most branch_factor, so a later stage skips
# it unless subsequent optimization makes it overloaded again.
proc ::pin3d_local_tree::repair_buffer_cone {block root_net tier label branch_factor max_depth report_fh} {
  set records [::pin3d_local_tree::collect_buffer_cone_nets \
    $root_net $tier $max_depth $report_fh]
  set checked 0
  set tree_count 0
  set buffer_count 0
  set max_fanout 0

  puts $report_fh "CONE_BEGIN label=$label tier=$tier root_net=[$root_net getName] nets=[llength $records] max_allowed_fanout=$branch_factor max_depth=$max_depth"
  foreach record [lsort -command ::pin3d_local_tree::compare_cone_depth_desc $records] {
    lassign $record depth net_name net
    incr checked
    set loads [::pin3d_local_tree::recursive_domain_loads $net $tier]
    set direct_fanout [llength $loads]
    if {$direct_fanout > $max_fanout} {
      set max_fanout $direct_fanout
    }
    if {[::pin3d_local_tree::net_is_dont_touch $net]} {
      puts $report_fh "  CONE_NET depth=$depth net=$net_name direct_fanout=$direct_fanout action=skip_dont_touch"
      continue
    }
    if {$direct_fanout <= $branch_factor} {
      puts $report_fh "  CONE_NET depth=$depth net=$net_name direct_fanout=$direct_fanout action=keep max_allowed_fanout=$branch_factor"
      continue
    }

    puts $report_fh "  CONE_NET depth=$depth net=$net_name direct_fanout=$direct_fanout action=repair max_allowed_fanout=$branch_factor"
    set stats [::pin3d_local_tree::build_domain_tree $block $net $loads $tier \
      "${label}:cone:d${depth}:${net_name}" 0 [expr {$branch_factor + 1}] \
      $branch_factor $report_fh]
    if {[dict get $stats built]} {
      incr tree_count
      incr buffer_count [dict get $stats buffers]
    }
  }
  puts $report_fh "CONE_DONE label=$label checked=$checked trees=$tree_count buffers=$buffer_count max_direct_fanout=$max_fanout"
  return [dict create checked $checked trees $tree_count buffers $buffer_count max_direct_fanout $max_fanout]
}

proc pin3d_build_local_trees_for_tier {tier args} {
  set tier [string tolower [string trim $tier]]
  if {$tier ni {upper bottom}} {
    error "pin3d_build_local_trees_for_tier: tier must be upper or bottom"
  }
  array set opt {
    -report ""
  }
  if {([llength $args] % 2) != 0} {
    error "pin3d_build_local_trees_for_tier: args must be key-value pairs, got: $args"
  }
  foreach {key value} $args {
    if {![info exists opt($key)]} {
      error "pin3d_build_local_trees_for_tier: unknown option $key"
    }
    set opt($key) $value
  }

  if {![::pin3d_local_tree::env_flag PIN3D_LOCAL_TREE_ENABLE 1]} {
    puts "INFO(OR): PIN3D local-tree construction disabled"
    return [dict create domains 0 trees 0 buffers 0]
  }
  set min_fanout [::pin3d_local_tree::env_positive_int PIN3D_LOCAL_TREE_MIN_FANOUT 32]
  set port_min_fanout [::pin3d_local_tree::env_positive_int PIN3D_PORT_ROOT_MIN_FANOUT $min_fanout]
  set branch_factor [::pin3d_local_tree::env_positive_int PIN3D_LOCAL_TREE_BRANCH_FACTOR 32]
  if {$branch_factor < 2} {
    puts "WARN(OR): PIN3D_LOCAL_TREE_BRANCH_FACTOR must be >= 2; using 2"
    set branch_factor 2
  }
  set recursive_cone [::pin3d_local_tree::env_flag PIN3D_LOCAL_TREE_RECURSIVE_CONE 0]
  set recursive_max_depth [::pin3d_local_tree::env_positive_int PIN3D_LOCAL_TREE_RECURSIVE_MAX_DEPTH 64]

  if {$opt(-report) eq ""} {
    set opt(-report) [file join [_get LOG_DIR] "pin3d_local_tree_${tier}.rpt"]
  }
  set report_fh [open $opt(-report) w]
  puts $report_fh "# PIN3D tier-local buffer-tree report"
  puts $report_fh "# tier=$tier min_fanout=$min_fanout port_min_fanout=$port_min_fanout branch_factor=$branch_factor recursive_cone=$recursive_cone recursive_max_depth=$recursive_max_depth"

  set records [pin3d_read_split_manifest]
  set block [ord::get_db_block]
  _pin3d_rebuild_name_caches
  ::tier_split_or2::init_existing_names $block

  set domain_count 0
  set tree_count 0
  set buffer_count 0
  # Track BTerm-driven split nets so ordinary port scanning does not rebuild them.
  set port_tree_nets {}
  set cone_checked 0
  set cone_tree_count 0
  set cone_buffer_count 0
  foreach record $records {
    if {![dict exists $record record_type] || [dict get $record record_type] ne "dual_boundary"} {
      continue
    }
    set missing_key ""
    foreach key {source_tier destination_tier original_net branch_net split_src_inst split_dst_inst driver_kind} {
      if {![dict exists $record $key]} {
        set missing_key $key
        break
      }
    }
    if {$missing_key ne ""} {
      puts $report_fh "SKIP reason=manifest_missing_$missing_key record=$record"
      continue
    }

    set source_tier [dict get $record source_tier]
    set destination_tier [dict get $record destination_tier]
    if {$tier eq $source_tier} {
      incr domain_count
      set root_net [_pin3d_find_net_by_name [dict get $record original_net]]
      if {$root_net eq "" || $root_net eq "NULL"} {
        puts $report_fh "DOMAIN label=[dict get $record original_net]:source action=skip_missing_root_net"
      } else {
        set loads [::pin3d_local_tree::direct_domain_loads \
          $root_net $tier [list [dict get $record split_src_inst]]]
        set is_port [expr {[dict get $record driver_kind] eq "bterm"}]
        if {$is_port} {
          lappend port_tree_nets [dict get $record original_net]
        }
        set threshold [expr {$is_port ? $port_min_fanout : $min_fanout}]
        set stats [::pin3d_local_tree::build_domain_tree $block $root_net $loads $tier \
          "[dict get $record original_net]:source" $is_port $threshold $branch_factor $report_fh]
        if {[dict get $stats built]} { incr tree_count }
        incr buffer_count [dict get $stats buffers]
        if {$recursive_cone} {
          set cone_stats [::pin3d_local_tree::repair_buffer_cone $block $root_net $tier \
            "[dict get $record original_net]:source" $branch_factor $recursive_max_depth $report_fh]
          incr cone_checked [dict get $cone_stats checked]
          incr cone_tree_count [dict get $cone_stats trees]
          incr cone_buffer_count [dict get $cone_stats buffers]
        }
      }
    }

    if {$tier eq $destination_tier} {
      incr domain_count
      set root_net [_pin3d_find_net_by_name [dict get $record branch_net]]
      if {$root_net eq "" || $root_net eq "NULL"} {
        puts $report_fh "DOMAIN label=[dict get $record branch_net]:destination action=skip_missing_root_net"
      } else {
        set loads [::pin3d_local_tree::direct_domain_loads \
          $root_net $tier [list [dict get $record split_dst_inst]]]
        set stats [::pin3d_local_tree::build_domain_tree $block $root_net $loads $tier \
          "[dict get $record branch_net]:destination" 0 $min_fanout $branch_factor $report_fh]
        if {[dict get $stats built]} { incr tree_count }
        incr buffer_count [dict get $stats buffers]
        if {$recursive_cone} {
          set cone_stats [::pin3d_local_tree::repair_buffer_cone $block $root_net $tier \
            "[dict get $record branch_net]:destination" $branch_factor $recursive_max_depth $report_fh]
          incr cone_checked [dict get $cone_stats checked]
          incr cone_tree_count [dict get $cone_stats trees]
          incr cone_buffer_count [dict get $cone_stats buffers]
        }
      }
    }
  }

  # Build trees for high-fanout top-level input ports that are not in the
  # dual-boundary split manifest (for example Ibex rst_ni).
  if {[::pin3d_local_tree::env_flag PIN3D_PORT_TREE_ENABLE 1]} {
    foreach bterm [$block getBTerms] {
      set net [$bterm getNet]
      if {$net eq "" || $net eq "NULL"} { continue }
      set net_name [$net getName]
      if {[lsearch -exact $port_tree_nets $net_name] >= 0} { continue }
      lappend port_tree_nets $net_name

      set sig_type ""
      catch {set sig_type [string toupper [$net getSigType]]}
      if {$sig_type in {CLOCK POWER GROUND}} { continue }

      set io_type ""
      catch {set io_type [string toupper [$bterm getIoType]]}
      if {$io_type ne "" && $io_type ni {INPUT INOUT}} { continue }

      set loads [::pin3d_local_tree::direct_domain_loads $net $tier {}]
      if {[llength $loads] < $port_min_fanout} { continue }
      set label "${net_name}:port_source"
      set stats [::pin3d_local_tree::build_domain_tree $block $net $loads $tier \
        $label 1 $port_min_fanout $branch_factor $report_fh]
      if {[dict get $stats built]} { incr tree_count }
      incr buffer_count [dict get $stats buffers]
    }
  }

  incr tree_count $cone_tree_count
  incr buffer_count $cone_buffer_count
  puts $report_fh "SUMMARY tier=$tier domains=$domain_count trees=$tree_count buffers=$buffer_count cone_checked=$cone_checked cone_trees=$cone_tree_count cone_buffers=$cone_buffer_count"
  close $report_fh
  _pin3d_rebuild_name_caches
  pin3d_metrics_invalidate_cache
  puts "INFO(OR): PIN3D local trees tier=$tier domains=$domain_count trees=$tree_count buffers=$buffer_count cone_checked=$cone_checked cone_trees=$cone_tree_count cone_buffers=$cone_buffer_count report=$opt(-report)"
  return [dict create domains $domain_count trees $tree_count buffers $buffer_count cone_checked $cone_checked cone_trees $cone_tree_count cone_buffers $cone_buffer_count report $opt(-report)]
}
