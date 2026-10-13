#!/usr/bin/env python3

import os
import sys
import unittest
from collections import OrderedDict


STAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLKIT_ROOT = os.path.normpath(os.path.join(STAGE_DIR, "..", "coarse_synth", "common"))
if TOOLKIT_ROOT not in sys.path:
    sys.path.insert(0, TOOLKIT_ROOT)

from yosys_json_toolkit import (  # noqa: E402
    Cell,
    Design,
    Memory,
    Module,
    Netname,
    Port,
    assert_backend_netname_normalization,
    assert_backend_netnames_normalized,
    normalize_backend_internal_netnames,
)


def make_net(name, bits, hide_name=0, attributes=None, extras=None):
    return Netname(
        name=name,
        hide_name=hide_name,
        bits=bits,
        attributes=attributes or {},
        offset=3 if len(bits) > 1 else None,
        upto=0 if len(bits) > 1 else None,
        signed=1 if len(bits) > 1 else None,
        extras=extras or {},
    )


def make_design():
    ports = OrderedDict(
        [
            ("clk", Port("clk", "input", [1])),
            ("port_taken", Port("port_taken", "output", [2])),
        ]
    )
    cells = OrderedDict(
        [
            (
                "cell_taken",
                Cell(
                    "cell_taken",
                    0,
                    "BUF",
                    port_directions={"A": "input", "Y": "output"},
                    connections={"A": [1], "Y": [2]},
                ),
            )
        ]
    )
    memories = OrderedDict([("memory_taken", Memory("memory_taken", 0, width=1, start_offset=0, size=1))])
    netnames = OrderedDict()
    for name, bits in [
        ("clk", [1]),
        ("port_taken", [2]),
        ("foo_bar", [3]),
        (r"\foo.bar", [3]),
        (r"\port.taken", [4]),
        (r"\cell.taken", [5]),
        (r"\memory.taken", [6]),
        ("mid\\slash", [7]),
        ("trail\\", [8]),
        ("many\\\\slashes", [9]),
        ("mix\\.$:[]/", [10, 11]),
        ("same\\a", [12]),
        ("same\\.a", [13]),
        ("\\", [16]),
        (r"\123", [17]),
        ("alias_plain", [10, 11]),
        ("__d2d_ctrl$a_reg_en_0", [14]),
        ("inst_upper.__syn3d_pi_clk", [15]),
    ]:
        netnames[name] = make_net(name, bits, attributes={"keep": "1"}, extras={"custom": [name]})
    module = Module(
        "top",
        attributes={"top": "1"},
        ports=ports,
        cells=cells,
        memories=memories,
        netnames=netnames,
        extras={"custom_module": "kept"},
    )
    return Design(creator="unit-test", modules=OrderedDict([("top", module)]))


class BackendNetnameNormalizationTest(unittest.TestCase):
    def test_supported_names_collisions_aliases_and_metadata(self):
        design = make_design()
        before = design.modules["top"].copy()
        result = normalize_backend_internal_netnames(design, "top")

        expected = {
            r"\foo.bar": "foo_bar_1",
            r"\port.taken": "port_taken_1",
            r"\cell.taken": "cell_taken_1",
            r"\memory.taken": "memory_taken_1",
            "mid\\slash": "mid_slash",
            "trail\\": "trail_",
            "many\\\\slashes": "many_slashes",
            "mix\\.$:[]/": "mix_",
            "same\\a": "same_a_1",
            "same\\.a": "same_a",
            "\\": "net",
            r"\123": "net_123",
        }
        self.assertEqual(dict(result.mapping), expected)
        self.assertEqual(result.selected_count, len(expected))
        self.assertGreaterEqual(result.collision_count, 5)
        assert_backend_netname_normalization(before, design.modules["top"], result.mapping)
        assert_backend_netnames_normalized(design, "top")

        self.assertEqual(design.modules["top"].netnames["mix_"].bits, [10, 11])
        self.assertEqual(design.modules["top"].netnames["alias_plain"].bits, [10, 11])
        for unchanged in ["clk", "port_taken", "alias_plain", "__d2d_ctrl$a_reg_en_0", "inst_upper.__syn3d_pi_clk"]:
            self.assertIn(unchanged, design.modules["top"].netnames)

    def test_no_selected_names_is_strict_noop(self):
        design = make_design()
        module = design.modules["top"]
        module.netnames = OrderedDict(
            (name, netname) for name, netname in module.netnames.items() if "\\" not in name
        )
        before = design.to_dict()
        result = normalize_backend_internal_netnames(design, "top")
        self.assertEqual(result.selected_count, 0)
        self.assertEqual(result.collision_count, 0)
        self.assertEqual(result.mapping, OrderedDict())
        self.assertEqual(design.to_dict(), before)

    def test_primary_port_with_backslash_is_rejected(self):
        design = make_design()
        module = design.modules["top"]
        module.ports[r"\bad.port"] = Port(r"\bad.port", "input", [20])
        module.netnames[r"\bad.port"] = make_net(r"\bad.port", [20])
        with self.assertRaisesRegex(AssertionError, "primary port"):
            normalize_backend_internal_netnames(design, "top")

    def test_primary_port_without_same_name_netname_is_rejected(self):
        design = make_design()
        design.modules["top"].ports[r"\bad.port"] = Port(r"\bad.port", "input", [1])
        with self.assertRaisesRegex(AssertionError, "primary ports contain backslashes"):
            normalize_backend_internal_netnames(design, "top")

    def test_used_bit_without_visible_netname_is_rejected(self):
        design = make_design()
        module = design.modules["top"]
        module.cells["cell_taken"].connections["A"] = [99]
        module.netnames["hidden"] = make_net("hidden", [99], hide_name=1)
        with self.assertRaisesRegex(AssertionError, "without a visible netname"):
            normalize_backend_internal_netnames(design, "top")

    def test_key_name_mismatch_is_rejected(self):
        design = make_design()
        design.modules["top"].netnames[r"\foo.bar"].name = "different"
        with self.assertRaisesRegex(AssertionError, "does not match Netname.name"):
            normalize_backend_internal_netnames(design, "top")

    def test_empty_selected_bit_list_is_rejected(self):
        design = make_design()
        design.modules["top"].netnames[r"\foo.bar"].bits = []
        with self.assertRaisesRegex(AssertionError, "non-empty bit list"):
            normalize_backend_internal_netnames(design, "top")

    def test_invalid_selected_bit_is_rejected(self):
        design = make_design()
        design.modules["top"].netnames[r"\foo.bar"].bits = ["invalid"]
        with self.assertRaisesRegex(ValueError, "invalid bit value"):
            normalize_backend_internal_netnames(design, "top")

    def test_non_bijective_mapping_is_rejected(self):
        before = make_design().modules["top"]
        after = before.copy()
        mapping = OrderedDict((name, "duplicate") for name in before.netnames if "\\" in name)
        with self.assertRaisesRegex(AssertionError, "not one-to-one"):
            assert_backend_netname_normalization(before, after, mapping)

    def test_non_name_field_change_is_rejected(self):
        design = make_design()
        before = design.modules["top"].copy()
        result = normalize_backend_internal_netnames(design, "top")
        changed_name = next(iter(result.mapping.values()))
        design.modules["top"].netnames[changed_name].bits.append(100)
        with self.assertRaisesRegex(AssertionError, "fields other than its name"):
            assert_backend_netname_normalization(before, design.modules["top"], result.mapping)

    def test_remaining_backslash_is_rejected(self):
        design = make_design()
        before = design.modules["top"].copy()
        selected = [name for name in before.netnames if "\\" in name]
        mapping = OrderedDict((name, name.replace("\\", "_") + "\\") for name in selected)
        with self.assertRaisesRegex(AssertionError, "backslash-containing output"):
            assert_backend_netname_normalization(before, design.modules["top"], mapping)


if __name__ == "__main__":
    unittest.main()
