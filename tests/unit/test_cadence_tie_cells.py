#!/usr/bin/env python3
"""Static regression checks for Cadence tie-cell handling."""

from pathlib import Path
import re
import subprocess
import textwrap


def repo_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / "Makefile").exists() and (parent / "scripts_cadence").is_dir():
            return parent
    raise RuntimeError("could not find repository root")


REPO = repo_root()


def read(relpath):
    return (REPO / relpath).read_text()


def config_exports(relpath):
    exports = {}
    for line in read(relpath).splitlines():
        match = re.match(r"\s*export\s+([A-Za-z0-9_]+)\s*(?:\?|:)?=\s*(.*?)\s*$", line)
        if match:
            exports[match.group(1)] = match.group(2).split()
    return exports


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run_tcl(script):
    body = textwrap.dedent(script)
    wrapped = (
        "if {[catch {\n"
        f"{body}\n"
        "} err opts]} {\n"
        "  puts stderr $err\n"
        "  exit 1\n"
        "}\n"
    )
    result = subprocess.run(
        ["tclsh"],
        cwd=REPO,
        input=wrapped,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"tclsh failed with exit code {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result.stdout


def test_asap7_nangate45_bottom_tie_polarity():
    exports = config_exports("platforms/asap7_nangate45_3D/config.mk")

    require(
        exports.get("BOTTOM_TIEHI_CELL_AND_PORT", [None])[0] == "LOGIC1_X1_bottom",
        "asap7_nangate45_3D bottom tie-high must use LOGIC1_X1_bottom",
    )
    require(
        exports.get("BOTTOM_TIELO_CELL_AND_PORT", [None])[0] == "LOGIC0_X1_bottom",
        "asap7_nangate45_3D bottom tie-low must use LOGIC0_X1_bottom",
    )


def test_cadence_tier_policy_selects_active_tie_cells():
    tier_policy = read("scripts_cadence/tier_cell_policy.tcl")

    for tier in ("UPPER", "BOTTOM"):
        require(
            f"set ::env(TIEHI_CELL_AND_PORT) $::env({tier}_TIEHI_CELL_AND_PORT)"
            in tier_policy,
            f"apply_tier_policy must select {tier.lower()} tie-high cell",
        )
        require(
            f"set ::env(TIELO_CELL_AND_PORT) $::env({tier}_TIELO_CELL_AND_PORT)"
            in tier_policy,
            f"apply_tier_policy must select {tier.lower()} tie-low cell",
        )


def test_cadence_place_common_repairs_tie_cells():
    place_common = read("scripts_cadence/place_common.tcl")

    require("proc pc::repair_tie_cells" in place_common, "place_common must define a tie repair helper")
    require("setTieHiLoMode" in place_common, "tie repair helper must configure Innovus tie mode")
    require("addTieHiLo" in place_common, "tie repair helper must insert tie cells")
    require(
        place_common.count("pc::repair_tie_cells") >= 4,
        "tie repair must be called from setup and post placement optimization stages",
    )


def test_cadence_tie_pg_reconnect_filters_null_handles_and_missing_nets():
    place_common = read("scripts_cadence/place_common.tcl")

    require(
        "proc pc::_valid_db_ptr" in place_common,
        "tie PG reconnect must have a helper that rejects Innovus null handles",
    )
    require(
        'eq "0x0"' in place_common,
        "tie PG reconnect must explicitly reject Innovus 0x0 handles",
    )
    require(
        "proc pc::_db_net_exists" in place_common,
        "tie PG reconnect must check that PG nets exist before globalNetConnect",
    )
    require(
        "skip tie PG reconnect" in place_common,
        "tie PG reconnect should log an explicit skip when PG nets are unavailable",
    )


def test_cadence_tie_pg_reconnect_runtime_guards():
    run_tcl(
        r"""
        source scripts_cadence/place_common.tcl
        proc dbGet {query} {
          switch -- $query {
            inst0.term.name { return 0x0 }
            inst0.name { return U0/A }
            default { return "" }
          }
        }
        set pin_name [pc::_inst_term_pin_name inst0]
        if {![string equal $pin_name A]} {
          error "expected instTerm fallback to parse U0/A as A, got '$pin_name'"
        }
        """
    )

    run_tcl(
        r"""
        source scripts_cadence/place_common.tcl
        proc dbGet {query} {
          switch -- $query {
            inst0.name { return {{U0/CK}} }
            default { return "" }
          }
        }
        set pin_name [pc::_inst_term_pin_name inst0]
        if {![string equal $pin_name CK]} {
          error "expected instTerm parser to trim Tcl list braces from {U0/CK}, got '$pin_name'"
        }
        """
    )

    run_tcl(
        r"""
        source scripts_cadence/place_common.tcl
        set ::calls {}
        proc dbGet {args} {
          set query [lindex $args 0]
          if {$query eq "-e"} {
            set query [lindex $args 1]
          }
          switch -- $query {
            top.insts { return {0x0 tie0 u0} }
            top.nets - top.pgNets { return {} }
            tie0.cell.name { return LOGIC1_X1 }
            tie0.name { return PIN3D_tie0 }
            u0.cell.name { return NAND2_X1 }
            u0.name { return U0 }
            default { return "" }
          }
        }
        proc globalNetConnect {args} {
          lappend ::calls $args
        }
        pc::_connect_tie_cell_pg {LOGIC1_X1 LOGIC0_X1} unit
        if {[llength $::calls] != 0} {
          error "globalNetConnect should be skipped when PG nets are missing: $::calls"
        }
        """
    )

    run_tcl(
        r"""
        source scripts_cadence/place_common.tcl
        set ::calls {}
        proc dbGet {args} {
          set query [lindex $args 0]
          if {$query eq "-e"} {
            set query [lindex $args 1]
          }
          switch -- $query {
            top.insts { return {0x0 tie0 tie1 u0} }
            top.nets { return {vdd vss} }
            top.pgNets { return {} }
            vdd.name { return VDD }
            vss.name { return VSS }
            tie0.cell.name { return LOGIC1_X1 }
            tie0.name { return PIN3D_tie0 }
            tie1.cell.name { return LOGIC0_X1 }
            tie1.name { return PIN3D_tie1 }
            u0.cell.name { return NAND2_X1 }
            u0.name { return U0 }
            default { return "" }
          }
        }
        proc globalNetConnect {args} {
          lappend ::calls $args
        }
        pc::_connect_tie_cell_pg {LOGIC1_X1 LOGIC0_X1} unit
        if {[llength $::calls] != 8} {
          error "expected 8 globalNetConnect calls for two tie instances, got [llength $::calls]: $::calls"
        }
        foreach call $::calls {
          if {[lsearch -exact $call "0x0"] >= 0} {
            error "globalNetConnect used Innovus null handle: $call"
          }
        }
        """
    )


def main():
    tests = [
        test_asap7_nangate45_bottom_tie_polarity,
        test_cadence_tier_policy_selects_active_tie_cells,
        test_cadence_place_common_repairs_tie_cells,
        test_cadence_tie_pg_reconnect_filters_null_handles_and_missing_nets,
        test_cadence_tie_pg_reconnect_runtime_guards,
    ]
    for test in tests:
        test()
    print(f"{len(tests)} tie-cell regression checks passed")


if __name__ == "__main__":
    main()
