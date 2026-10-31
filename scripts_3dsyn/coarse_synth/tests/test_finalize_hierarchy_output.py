#!/usr/bin/env python3

import sys
import tempfile
import unittest
from pathlib import Path


COARSE_SYNTH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(COARSE_SYNTH_DIR))

import finalize_hierarchy_output as finalize


class ZeroAreaClassificationTest(unittest.TestCase):
    def test_nonzero_area_is_retained(self):
        self.assertFalse(
            finalize.should_eliminate_actual_unit("kept", 1.0, 2.0, 1, 1)
        )

    def test_zero_area_and_zero_cells_is_eliminated(self):
        self.assertTrue(
            finalize.should_eliminate_actual_unit("gone", 0.0, 0.0, 0, 0)
        )

    def test_zero_area_with_cells_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "zero cells in both tiers"):
            finalize.should_eliminate_actual_unit("bad", 0.0, 0.0, 1, 1)

    def test_one_zero_tier_is_not_an_elimination_candidate(self):
        self.assertFalse(
            finalize.should_eliminate_actual_unit("one_tier", 0.0, 1.0, 0, 1)
        )


class SelectiveFlattenTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.yosys = finalize.resolve_yosys_exe("")
        if not Path(cls.yosys).is_file():
            raise unittest.SkipTest("Yosys executable is unavailable")

    def test_no_candidates_preserves_original_design(self):
        sentinel = object()
        design, json_path, instance_count = finalize.flatten_eliminated_actual_instances(
            self.yosys, sentinel, "top", set(), "."
        )
        self.assertIs(design, sentinel)
        self.assertIsNone(json_path)
        self.assertEqual(instance_count, 0)

    def test_only_marked_zero_area_instances_are_flattened(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir = Path(temp_dir)
            input_v = temp_dir / "input.v"
            raw_json = temp_dir / "raw.json"
            input_v.write_text(
                """
module gone(input wire B, output wire Y);
  assign Y = B;
endmodule

module kept(input wire A, output wire Y);
  assign Y = ~A;
endmodule

module top(
  input wire B,
  input wire A,
  output wire Y0,
  output wire Y1,
  output wire K
);
  gone g0(.B(B), .Y(Y0));
  gone g1(.B(B), .Y(Y1));
  kept k0(.A(A), .Y(K));
endmodule
"""
            )
            finalize.verilog_to_json(self.yosys, input_v, "top", raw_json)
            raw_design = finalize.load_design(raw_json)

            pruned_design, pruned_json, instance_count = \
                finalize.flatten_eliminated_actual_instances(
                    self.yosys,
                    raw_design,
                    "top",
                    {"gone"},
                    temp_dir,
                )

            self.assertEqual(instance_count, 2)
            self.assertTrue(Path(pruned_json).is_file())
            self.assertEqual(
                [cell.type for cell in raw_design.get_module("top").cells.values()].count("gone"),
                2,
            )
            top = pruned_design.get_module("top")
            self.assertNotIn("gone", {cell.type for cell in top.cells.values()})
            self.assertIn("kept", {cell.type for cell in top.cells.values()})
            self.assertEqual(top.ports["B"].bits, top.ports["Y0"].bits)
            self.assertEqual(top.ports["B"].bits, top.ports["Y1"].bits)


class PublishedVariantSetTest(unittest.TestCase):
    def test_consistent_outputs_are_accepted(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            actual = "unit_a"
            for path in [
                root / "coarse_units" / "bottom",
                root / "coarse_units" / "upper",
                root / "metrics" / "bottom" / actual,
                root / "metrics" / "upper" / actual,
                root / "lib" / "2d",
                root / "lib" / "bottom",
                root / "lib" / "upper",
                root / "lef" / "2d",
                root / "lef" / "bottom",
                root / "lef" / "upper",
            ]:
                path.mkdir(parents=True, exist_ok=True)

            (root / "coarse_units" / "bottom" / (actual + ".v")).write_text("")
            (root / "coarse_units" / "upper" / (actual + ".v")).write_text("")
            (root / "lib" / "2d" / (actual + ".lib")).write_text("")
            (root / "lib" / "2d" / "coarse_units.lib").write_text("")
            (root / "lib" / "bottom" / (actual + ".bottom.lib")).write_text("")
            (root / "lib" / "upper" / (actual + ".upper.lib")).write_text("")
            (root / "lef" / "2d" / "coarse_units.lef").write_text(
                "MACRO {}\nEND {}\n".format(actual, actual)
            )
            (root / "lef" / "bottom" / "coarse_units.lef").write_text(
                "MACRO {0}_bottom\nEND {0}_bottom\n".format(actual)
            )
            (root / "lef" / "upper" / "coarse_units.lef").write_text(
                "MACRO {0}_upper\nEND {0}_upper\n".format(actual)
            )

            finalize.validate_published_variant_sets(root, [actual])

            (root / "coarse_units" / "bottom" / "stale.v").write_text("")
            with self.assertRaisesRegex(RuntimeError, "published variant set mismatch"):
                finalize.validate_published_variant_sets(root, [actual])


class EmptyHandoffTest(unittest.TestCase):
    def test_empty_handoff_has_complete_parseable_shape(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "handoff"
            finalize.publish_empty_handoff(root, "nangate45_3D")

            for tier in ["2d", "bottom", "upper"]:
                lef_path = root / "lef" / tier / "coarse_units.lef"
                lib_path = root / "lib" / tier / "coarse_units.lib"
                self.assertTrue(lef_path.is_file())
                self.assertTrue(lib_path.is_file())
                self.assertEqual(finalize.collect_macro_names(lef_path), set())
                self.assertIn("END LIBRARY", lef_path.read_text(encoding="utf-8"))
                self.assertIn("library (", lib_path.read_text(encoding="utf-8"))

            for tier in ["bottom", "upper"]:
                self.assertTrue((root / "coarse_units" / tier).is_dir())
                self.assertEqual(list((root / "coarse_units" / tier).iterdir()), [])

            finalize.validate_published_variant_sets(root, [])


if __name__ == "__main__":
    unittest.main()
