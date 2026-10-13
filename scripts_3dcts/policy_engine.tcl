# =====================================================================
# cts_policy_engine.tcl — 3D Construction Policy Engine (Item 1)
# =====================================================================
# Replaces per-design hand-set 3D-CTS levers with an algorithmic decision
# procedure over quantities measured from the loaded ODB at CTS start.
# Levers decided: HETEROGENEOUS_3D, CTS_NO_INSERTION_DELAY,
#                 CTS_ENABLE_UNIFIED_TREE, CTS_ENABLE_PER_TIER_CTS,
#                 CTS_ENABLE_DIR_SKEW (+alpha/shift/level).
# Gate: CTS_POLICY_ENGINE=1 (default off -> byte-identical flow).
# Override discipline: a lever explicitly set (and != "auto") always wins;
# the engine logs it as OVERRIDE in the audit CSV.
# Audit artifact: $CTS3D_WORK_DIR/cts_policy_decisions.csv
# Evidence basis (memory/CLAUDE.md): nid-noinsertiondelay-nonmacro (R2),
# unified-tree A/B ariane/swerv (R3), autonomous-construction-loop iter2 +
# pertier-off-hurts-aes (R4), P3 dir-skew per-design data (R5).
# =====================================================================

namespace eval cpe {
  variable XTHRESH_UNIFIED_MACROS 32   ;# macro-sink count threshold (7 vs 120, decade-separated)
  variable MIN_DOMAIN_FFS 50           ;# FFs under a gated root to count as a clock domain
}

# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------
proc cpe::is_ff_master {mname} {
  return [regexp {DFF|SDFF|LATCH|dff|sdff} $mname]
}
proc cpe::is_buf_inv_master {mname} {
  return [regexp {^(BUF|INV|CKBUF|CKINV|CLKBUF|CLKINV|HB\d*x|BUFx|INVx|BUF_X|INV_X|CLKBUF_X)} $mname]
}
proc cpe::tier_of_master {mname} {
  if {[string match *upper* $mname]}  { return 1 }
  if {[string match *bottom* $mname]} { return 0 }
  return -1
}

# ---------------------------------------------------------------------
# measure_design_structure: ODB walk, no STA, <5s
# returns dict: n_sinks n_macro n_reg n_bot n_up tier_balance n_domains
#               is_hetero delivery_on
# ---------------------------------------------------------------------
proc cpe::measure_design_structure {} {
  set block [ord::get_db_block]
  set n_macro 0
  set n_bot 0; set n_up 0
  set ff_clk_iterms {}
  set h_bot -1; set h_up -1
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    set mname  [$master getName]
    set mtype  [$master getType]
    if {$mtype eq "BLOCK"} {
      # macro clock sink if it has a CLK-like input connected
      foreach it [$inst getITerms] {
        set mt [$it getMTerm]
        if {[regexp {^(CLK|CK|clk)$} [$mt getName]] && [$it getNet] ne "NULL"} {
          incr n_macro
          break
        }
      }
      continue
    }
    if {[cpe::is_ff_master $mname]} {
      set tier [cpe::tier_of_master $mname]
      if {$tier == 0} { incr n_bot
        if {$h_bot < 0} { set h_bot [$master getHeight] }
      } elseif {$tier == 1} { incr n_up
        if {$h_up < 0} { set h_up [$master getHeight] }
      }
      foreach it [$inst getITerms] {
        set mt [$it getMTerm]
        if {[regexp {^(CLK|CK|CP|GCLK|clk)$} [$mt getName]]} {
          set net [$it getNet]
          if {$net ne "NULL"} { lappend ff_clk_iterms [list $inst $net] }
          break
        }
      }
    }
  }
  set n_reg [expr {$n_bot + $n_up}]
  set n_sinks [expr {$n_reg + $n_macro}]
  set tb 0.0
  if {$n_reg > 0} {
    set tb [expr {double(min($n_bot,$n_up)) / double($n_reg)}]
  }
  # heterogeneity: FF master heights differ across tiers
  set is_hetero 0
  if {$h_bot > 0 && $h_up > 0 && $h_bot != $h_up} { set is_hetero 1 }

  # n_domains: walk UP from each FF clock net through BUF/INV chains to the
  # terminal source (port or non-buffer cell output = gated root); count
  # distinct roots feeding >= MIN_DOMAIN_FFS FFs.
  variable MIN_DOMAIN_FFS
  array set rootcount {}
  foreach pair $ff_clk_iterms {
    set net [lindex $pair 1]
    set guard 0
    while {$guard < 32} {
      incr guard
      # driver of this net: an output iterm, or a bterm (port)
      set drv ""
      foreach it [$net getITerms] {
        if {[$it getIoType] eq "OUTPUT"} { set drv $it; break }
      }
      if {$drv eq ""} {
        # port-driven
        set bts [$net getBTerms]
        if {[llength $bts] > 0} {
          set key "PORT:[[lindex $bts 0] getName]"
        } else {
          set key "NET:[$net getName]"
        }
        if {[info exists rootcount($key)]} { incr rootcount($key) } else { set rootcount($key) 1 }
        break
      }
      set dinst [$drv getInst]
      set dm [[$dinst getMaster] getName]
      if {[cpe::is_buf_inv_master $dm]} {
        # continue up through the buffer's input net
        set upnet ""
        foreach it [$dinst getITerms] {
          if {[$it getIoType] eq "INPUT"} {
            set n2 [$it getNet]
            if {$n2 ne "NULL"} { set upnet $n2; break }
          }
        }
        if {$upnet eq ""} { set key "INST:[$dinst getName]"
          if {[info exists rootcount($key)]} { incr rootcount($key) } else { set rootcount($key) 1 }
          break }
        set net $upnet
      } else {
        set key "GATER:[$dinst getName]"
        if {[info exists rootcount($key)]} { incr rootcount($key) } else { set rootcount($key) 1 }
        break
      }
    }
  }
  set n_domains 0
  foreach k [array names rootcount] {
    if {$rootcount($k) >= $MIN_DOMAIN_FFS} { incr n_domains }
  }
  if {$n_domains == 0} { set n_domains 1 }

  set delivery_on 0
  if {[info exists ::env(ENABLE_PROPAGATED_CTS)] && $::env(ENABLE_PROPAGATED_CTS) == 1} {
    set delivery_on 1
  }
  puts "\[CPE\] measured: sinks=$n_sinks macro=$n_macro reg=$n_reg bot=$n_bot up=$n_up balance=[format %.2f $tb] domains=$n_domains hetero=$is_hetero delivery=$delivery_on"
  return [dict create n_sinks $n_sinks n_macro $n_macro n_reg $n_reg \
          n_bot $n_bot n_up $n_up tier_balance $tb n_domains $n_domains \
          is_hetero $is_hetero delivery_on $delivery_on]
}

# ---------------------------------------------------------------------
# decide_cts_policy: rules R1-R6 (each cites causal evidence)
# ---------------------------------------------------------------------
proc cpe::decide_cts_policy {m} {
  variable XTHRESH_UNIFIED_MACROS
  set n_macro    [dict get $m n_macro]
  set n_domains  [dict get $m n_domains]
  set is_hetero  [dict get $m is_hetero]
  set delivery   [dict get $m delivery_on]

  set p [dict create]
  # R1: platform heterogeneity (measured, replaces hand HETEROGENEOUS_3D)
  dict set p HETEROGENEOUS_3D [list $is_hetero "R1:ff-height-mismatch"]
  # R2: LatencyBalancer — NID=1 only when macros AND useful-skew delivery active
  #     (evidence: nid memory — balancer x skew-target interaction harms macro hold;
  #      NID=1 cripples multi-domain non-macro base trees)
  # Current-flow semantics: the audited pure-construction table uses NID=0 for
  # ALL designs (LatencyBalancer ON). The macro-with-useful-skew-delivery NID=1
  # exception belongs to the legacy delivery flow (9_Pin3D_Deliver2 generation)
  # and is keyed to an explicit flag there, not inferred here.
  set nid 0
  dict set p CTS_NO_INSERTION_DELAY [list $nid "R2:balancer-on(current-flow);macro=$n_macro"]
  # R3: unified vs macro/reg split (evidence: ariane 120 macros unified WIN;
  #     swerv 7 macros split WIN; threshold mid-decade at 32)
  # R3 v2 (fresh 10x2 validation, ): unified merges fragmented clock
  # sub-trees. Beneficial when (a) macro-heavy (ariane 120: dedup of interleaved
  # spans) or (b) macro-less MULTI-DOMAIN (ibex: merging split sub-trees was
  # worth +71.8K fresh). Low-macro-count (swerv 7) and single-domain designs
  # prefer the split (engine beat the hand vector by +38K/+6.7K there).
  set uni [expr {($n_macro >= $XTHRESH_UNIFIED_MACROS)
                 || ($n_macro == 0 && $n_domains >= 2) ? 1 : 0}]
  dict set p CTS_ENABLE_UNIFIED_TREE [list $uni "R3v2:macro=$n_macro,domains=$n_domains"]
  # R4: per-tier vs single spanning tree (evidence: iter2 per-tier OFF wins only
  #     homo+multi-domain+non-macro; aes single-domain prefers ON; hetero/macro ON)
  set pt [expr {(!$is_hetero && $n_macro == 0 && $n_domains >= 2) ? 0 : 1}]
  dict set p CTS_ENABLE_PER_TIER_CTS [list $pt "R4:hetero=$is_hetero,macro=$n_macro,domains=$n_domains"]
  # R5: directional useful-skew — fire exactly when R4 fired OFF (audited table)
  if {$pt == 0} {
    dict set p CTS_ENABLE_DIR_SKEW      [list 1    "R5:per-tier-off"]
    dict set p CTS_DIR_SKEW_ALPHA       [list 0.40 "R5"]
    dict set p CTS_DIR_MAX_SHIFT        [list 12.0 "R5"]
    dict set p CTS_DIR_SKEW_MAX_LEVEL   [list 3    "R5"]
  } else {
    dict set p CTS_ENABLE_DIR_SKEW      [list 0 "R5:per-tier-on"]
  }
  # R6: V58 macro-recipe corollary (delivery flow only): NID=1 without unified
  #     collapses the macro/reg split -> force it. Never on hetero (CLAUDE.md guard).
  if {$nid == 1 && $uni == 0 && !$is_hetero} {
    dict set p CTS_FORCE_MACRO_REG_SPLIT [list 1 "R6:nid-no-unified-homo"]
  }
  return $p
}

# ---------------------------------------------------------------------
# apply_cts_policy: env writes with override discipline + audit CSV
# ---------------------------------------------------------------------
proc cpe::apply_cts_policy {p m} {
  set csvdir "."
  if {[info exists ::env(CTS3D_WORK_DIR)]} { set csvdir $::env(CTS3D_WORK_DIR) }
  set f [open "$csvdir/cts_policy_decisions.csv" w]
  puts $f "lever,decision,rule,source,measured"
  set meas "sinks=[dict get $m n_sinks];macro=[dict get $m n_macro];domains=[dict get $m n_domains];hetero=[dict get $m is_hetero];balance=[format %.2f [dict get $m tier_balance]]"
  dict for {lever dv} $p {
    lassign $dv val rule
    if {[info exists ::env($lever)] && $::env($lever) ne "" && $::env($lever) ne "auto"} {
      puts $f "$lever,$::env($lever),$rule,OVERRIDE,$meas"
      puts "\[CPE\] $lever = $::env($lever) (OVERRIDE; rule would set $val by $rule)"
    } else {
      set ::env($lever) $val
      puts $f "$lever,$val,$rule,rule,$meas"
      puts "\[CPE\] $lever = $val ($rule)"
    }
  }
  close $f
  puts "\[CPE\] decisions written to $csvdir/cts_policy_decisions.csv"
}

# convenience entry
proc cpe::run {} {
  set m [cpe::measure_design_structure]
  cpe::apply_cts_policy [cpe::decide_cts_policy $m] $m
}
