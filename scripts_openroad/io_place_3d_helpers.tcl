# ============================================================
# io_place_3d_helpers.tcl
# Partition-aware helpers for 3D IO placement.
# ============================================================

namespace eval ::pin3d_io {}

proc ::pin3d_io::normalize_name {name} {
  set normalized [string trim $name]
  if {$normalized ne "" && [string index $normalized 0] eq "\\"} {
    set normalized [string range $normalized 1 end]
  }
  return [string map [list {\/} {/} {\[} {[} {\]} {]}] $normalized]
}

proc ::pin3d_io::parse_partition_file {path} {
  if {$path eq "" || ![file exists $path]} {
    error "3D IO partition file not found: $path"
  }

  set part_map [dict create]
  set fh [open $path r]
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} {
      continue
    }
    set fields [split $line]
    if {[llength $fields] < 2} {
      continue
    }
    set partition_id [lindex $fields end]
    if {$partition_id ni {0 1}} {
      continue
    }
    set name [::pin3d_io::normalize_name [lindex $fields 0]]
    if {[dict exists $part_map $name] && [dict get $part_map $name] ne $partition_id} {
      close $fh
      error "Conflicting TritonPart assignments for '$name' in $path"
    }
    dict set part_map $name $partition_id
  }
  close $fh

  if {[dict size $part_map] == 0} {
    error "3D IO partition file is empty or invalid: $path"
  }
  return $part_map
}

proc ::pin3d_io::instance_tier {inst} {
  set master [$inst getMaster]
  if {$master ne "" && $master ne "NULL"} {
    set master_name [$master getName]
    if {[string match "*_upper" $master_name]} {
      return upper
    }
    if {[string match "*_bottom" $master_name]} {
      return bottom
    }
  }

  set inst_name [$inst getName]
  if {[string match "*_upper" $inst_name]} {
    return upper
  }
  if {[string match "*_bottom" $inst_name]} {
    return bottom
  }
  return ""
}

# partition.txt uses TritonPart labels, while generate_3d_views may globally
# swap those labels before mapping cells to *_upper / *_bottom masters. Infer
# that global orientation from the generated 3D design so IO placement always
# follows the same label-to-die convention as instance placement.
proc ::pin3d_io::infer_label_to_tier {part_map} {
  set block [ord::get_db_block]
  if {$block eq "" || $block eq "NULL"} {
    error "OpenDB block is not initialized while resolving 3D IO partitions."
  }

  array set counts {
    0,upper 0
    0,bottom 0
    1,upper 0
    1,bottom 0
  }
  set matched 0
  foreach inst [$block getInsts] {
    set name [::pin3d_io::normalize_name [$inst getName]]
    if {![dict exists $part_map $name]} {
      continue
    }
    set tier [::pin3d_io::instance_tier $inst]
    if {$tier eq ""} {
      continue
    }
    set partition_id [dict get $part_map $name]
    incr counts($partition_id,$tier)
    incr matched
  }

  if {$matched == 0} {
    error "Cannot infer TritonPart label orientation: no partitioned 3D instances matched upper/bottom masters."
  }

  set original_score [expr {$counts(0,upper) + $counts(1,bottom)}]
  set swapped_score [expr {$counts(0,bottom) + $counts(1,upper)}]
  puts [format {IO-PARTITION: matched_instances=%d label0={upper=%d bottom=%d} label1={upper=%d bottom=%d}} \
    $matched $counts(0,upper) $counts(0,bottom) $counts(1,upper) $counts(1,bottom)]

  if {$original_score == $matched && $swapped_score < $matched} {
    puts "IO-PARTITION: TritonPart label 0 -> upper, label 1 -> bottom"
    return [dict create 0 upper 1 bottom]
  }
  if {$swapped_score == $matched && $original_score < $matched} {
    puts "IO-PARTITION: TritonPart label 0 -> bottom, label 1 -> upper"
    return [dict create 0 bottom 1 upper]
  }

  error [format {TritonPart labels are inconsistent with the generated 3D view: matched=%d original_score=%d swapped_score=%d. Rerun ord-pre and ord-3d-floorplan from the same partition.txt.} \
    $matched $original_score $swapped_score]
}

proc ::pin3d_io::partition_ports {partition_path ports} {
  set part_map [::pin3d_io::parse_partition_file $partition_path]
  set label_to_tier [::pin3d_io::infer_label_to_tier $part_map]
  set upper_pins {}
  set bottom_pins {}
  set missing {}

  foreach pin $ports {
    set normalized [::pin3d_io::normalize_name $pin]
    if {![dict exists $part_map $normalized]} {
      lappend missing $pin
      continue
    }
    set partition_id [dict get $part_map $normalized]
    set tier [dict get $label_to_tier $partition_id]
    if {$tier eq "upper"} {
      lappend upper_pins $pin
    } else {
      lappend bottom_pins $pin
    }
  }

  if {[llength $missing] > 0} {
    error [format {TritonPart did not assign %d signal ports: %s} \
      [llength $missing] [join $missing {, }]]
  }

  set upper_pins [lsort -dictionary -unique $upper_pins]
  set bottom_pins [lsort -dictionary -unique $bottom_pins]
  puts [format {IO-PARTITION: ports upper=%d bottom=%d total=%d source=%s} \
    [llength $upper_pins] [llength $bottom_pins] \
    [expr {[llength $upper_pins] + [llength $bottom_pins]}] $partition_path]

  return [dict create \
    upper_pins $upper_pins \
    bottom_pins $bottom_pins \
    part_map $part_map \
    label_to_tier $label_to_tier]
}

# place_pins always considers every unfixed BTerm. Create geometry-free FIRM
# sentinels for all pins outside the requested subset, run the normal placer,
# then remove only those temporary sentinels. Pins placed in an earlier tier
# remain FIRM and are naturally ignored by the next call.
proc ::pin3d_io::mask_all_except {allowed_pins} {
  set block [ord::get_db_block]
  set allowed [dict create]
  foreach pin $allowed_pins {
    dict set allowed $pin 1
  }

  set sentinels {}
  foreach bterm [$block getBTerms] {
    set name [$bterm getName]
    if {[dict exists $allowed $name]} {
      continue
    }

    set bpins [$bterm getBPins]
    if {[llength $bpins] > 0} {
      set status [[lindex $bpins 0] getPlacementStatus]
      if {$status in {FIRM FIXED LOCKED COVER}} {
        continue
      }
      error "Cannot temporarily mask IO pin '$name': it already has a non-fixed BPin."
    }

    set sentinel [odb::dbBPin_create $bterm]
    $sentinel setPlacementStatus FIRM
    lappend sentinels $sentinel
  }
  return $sentinels
}

proc ::pin3d_io::remove_sentinels {sentinels} {
  foreach sentinel $sentinels {
    odb::dbBPin_destroy $sentinel
  }
}

proc ::pin3d_io::set_pin_status {pins status} {
  set block [ord::get_db_block]
  foreach pin $pins {
    set bterm [$block findBTerm $pin]
    if {$bterm eq "" || $bterm eq "NULL"} {
      error "Cannot set placement status for missing IO pin '$pin'."
    }
    foreach bpin [$bterm getBPins] {
      $bpin setPlacementStatus $status
    }
  }
}

proc ::pin3d_io::place_subset {tier pins hor_layer ver_layer corner_margin min_tracks} {
  if {[llength $pins] == 0} {
    puts "IO-INFO: no $tier-tier signal pins to place."
    return
  }

  set sentinels [::pin3d_io::mask_all_except $pins]
  puts [format {IO-PLACE[%s]: pins=%d hor_layer=%s ver_layer=%s masked_bterms=%d} \
    $tier [llength $pins] $hor_layer $ver_layer [llength $sentinels]]
  log_cmd place_pins \
    -hor_layers $hor_layer \
    -ver_layers $ver_layer \
    -corner_avoidance $corner_margin \
    -min_distance $min_tracks \
    -min_distance_in_tracks
  # PPL emits PLACED BPins. Promote this completed tier to FIRM so the next
  # place_pins call treats it as immutable; the caller restores PLACED after
  # both tier passes finish.
  ::pin3d_io::set_pin_status $pins FIRM
  ::pin3d_io::remove_sentinels $sentinels
}

proc ::pin3d_io::pin_layers {pin_name} {
  set block [ord::get_db_block]
  set bterm [$block findBTerm $pin_name]
  if {$bterm eq "" || $bterm eq "NULL"} {
    error "Placed IO pin '$pin_name' was not found in OpenDB."
  }
  set layers {}
  foreach bpin [$bterm getBPins] {
    foreach box [$bpin getBoxes] {
      lappend layers [[$box getTechLayer] getName]
    }
  }
  return [lsort -dictionary -unique $layers]
}

proc ::pin3d_io::verify_and_report {partition_info upper_layers bottom_layers report_path} {
  set fh [open $report_path w]
  puts $fh "# pin partition tier layer"
  set checked 0

  foreach tier {upper bottom} {
    set pins [dict get $partition_info ${tier}_pins]
    if {$tier eq "upper"} {
      set expected_layers $upper_layers
    } else {
      set expected_layers $bottom_layers
    }
    foreach pin $pins {
      set layers [::pin3d_io::pin_layers $pin]
      if {[llength $layers] == 0} {
        close $fh
        error "IO pin '$pin' has no physical shape after $tier-tier placement."
      }
      foreach layer $layers {
        if {$layer ni $expected_layers} {
          close $fh
          error "IO pin '$pin' belongs to $tier tier but was placed on layer '$layer' (expected one of: $expected_layers)."
        }
      }
      set normalized [::pin3d_io::normalize_name $pin]
      set partition_id [dict get [dict get $partition_info part_map] $normalized]
      puts $fh [format {%s %s %s %s} $pin $partition_id $tier [join $layers ,]]
      incr checked
    }
  }
  close $fh
  puts [format {IO-VERIFY: checked=%d partition-consistent pins report=%s} $checked $report_path]
}
