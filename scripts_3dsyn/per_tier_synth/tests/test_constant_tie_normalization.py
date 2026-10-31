import sys
import subprocess
import tempfile
import unittest
from collections import OrderedDict
from copy import deepcopy
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
STAGE_DIR = TEST_DIR.parent
FLOW_HOME = STAGE_DIR.parent.parent
TOOLKIT_ROOT = FLOW_HOME / "scripts_3dsyn" / "coarse_synth" / "common"
sys.path.insert(0, str(STAGE_DIR))
sys.path.insert(0, str(TOOLKIT_ROOT))

from constant_tie_normalization import normalize_module_constants
from yosys_json_toolkit import Design, Module, add_cell, add_netname, add_port, dump_design, validate_design


LEAF_TYPES = {"AND2", "TIELO", "TIEHI"}
TIE_SPECS = {
    "0": {"cell_type": "TIELO", "output_pin": "Y"},
    "1": {"cell_type": "TIEHI", "output_pin": "Y"},
}


def build_module(input_constant="0", output_bit=3, input_pin_direction="input"):
    module = Module(name="tier")
    add_port(module, "a", "input", [1])
    add_port(module, "y", "output", [output_bit])
    add_netname(module, "a", [1])
    add_netname(module, "y", [output_bit])
    add_cell(
        module,
        "u_and",
        "AND2",
        OrderedDict([("A", [1]), ("B", [input_constant]), ("Y", [output_bit])]),
        port_directions=OrderedDict(
            [("A", "input"), ("B", input_pin_direction), ("Y", "output")]
        ),
    )
    return module


class ConstantTieNormalizationTest(unittest.TestCase):
    def test_cell_input_constants_are_replaced_with_distinct_tie_cells(self):
        module = build_module("0")
        add_cell(
            module,
            "u_and_1",
            "AND2",
            OrderedDict([("A", [1]), ("B", ["1"]), ("Y", [4])]),
            port_directions=OrderedDict([("A", "input"), ("B", "input"), ("Y", "output")]),
        )
        add_netname(module, "y1", [4])

        stats = normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)

        self.assertEqual(stats["inserted_tie_count"], 2)
        self.assertEqual(stats["cell_input_0"], 1)
        self.assertEqual(stats["cell_input_1"], 1)
        self.assertTrue(all(isinstance(bit, int) for cell in module.cells.values() for bits in cell.connections.values() for bit in bits))
        tie_types = [cell.type for cell in module.cells.values() if cell.type in {"TIELO", "TIEHI"}]
        self.assertEqual(sorted(tie_types), ["TIEHI", "TIELO"])
        validate_design(Design(modules=OrderedDict([("tier", module)])))

    def test_module_output_constant_is_replaced(self):
        module = build_module("0")
        module.ports["y"].bits = ["1"]
        module.netnames["y"].bits = ["1"]
        stats = normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)
        self.assertEqual(stats["cell_input_0"], 1)
        self.assertEqual(stats["module_output_1"], 1)
        self.assertTrue(isinstance(module.ports["y"].bits[0], int))
        self.assertEqual(module.netnames["y"].bits, module.ports["y"].bits)

    def test_module_output_constant_without_matching_netname_is_rejected(self):
        module = build_module("0")
        module.ports["y"].bits = ["1"]
        with self.assertRaisesRegex(AssertionError, "output/netname mismatch"):
            normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)

    def test_second_run_is_idempotent(self):
        module = build_module("0")
        first = normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)
        second = normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)
        self.assertEqual(first["inserted_tie_count"], 1)
        self.assertEqual(second["inserted_tie_count"], 0)

    def test_unknown_constant_is_rejected(self):
        module = build_module("x")
        with self.assertRaisesRegex(AssertionError, "Unsupported direct constant"):
            normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)

    def test_constant_on_output_pin_is_rejected(self):
        module = build_module("0", input_pin_direction="output")
        with self.assertRaisesRegex(AssertionError, "only legal on a leaf input pin"):
            normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)

    def test_missing_tie_cell_is_rejected(self):
        module = build_module("0")
        with self.assertRaisesRegex(AssertionError, "absent from the active Liberty"):
            normalize_module_constants(module, {"AND2", "TIELO"}, TIE_SPECS)

    def test_constant_on_input_module_port_is_rejected(self):
        module = build_module("0")
        module.ports["a"].bits = ["0"]
        with self.assertRaisesRegex(AssertionError, "only legal on an output"):
            normalize_module_constants(module, LEAF_TYPES, TIE_SPECS)


class ConstantTieEquivalenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.yosys = FLOW_HOME.parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys"
        if not cls.yosys.is_file():
            raise unittest.SkipTest("Yosys executable is unavailable: {}".format(cls.yosys))

    def test_normalized_tie_cells_are_formally_equivalent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            original_module = build_module("1")
            normalized_module = deepcopy(original_module)
            normalize_module_constants(normalized_module, LEAF_TYPES, TIE_SPECS)
            original_json = root / "original.json"
            normalized_json = root / "normalized.json"
            dump_design(
                Design(modules=OrderedDict([("tier", original_module)])),
                original_json,
            )
            dump_design(
                Design(modules=OrderedDict([("tier", normalized_module)])),
                normalized_json,
            )
            models_v = root / "models.v"
            models_v.write_text(
                "module AND2(input A, input B, output Y); assign Y = A & B; endmodule\n"
                "module TIELO(output Y); assign Y = 1'b0; endmodule\n"
                "module TIEHI(output Y); assign Y = 1'b1; endmodule\n",
                encoding="utf-8",
            )
            script = root / "equiv.ys"
            script.write_text(
                "read_verilog {}\n"
                "read_json {}\n"
                "hierarchy -check -top tier\n"
                "flatten\n"
                "rename tier gold\n"
                "design -stash gold_design\n"
                "design -reset\n"
                "read_verilog {}\n"
                "read_json {}\n"
                "hierarchy -check -top tier\n"
                "flatten\n"
                "rename tier gate\n"
                "design -stash gate_design\n"
                "design -reset\n"
                "design -copy-from gold_design -as gold gold\n"
                "design -copy-from gate_design -as gate gate\n"
                "equiv_make gold gate equiv\n"
                "prep -top equiv\n"
                "equiv_simple\n"
                "equiv_status -assert\n".format(
                    models_v,
                    original_json,
                    models_v,
                    normalized_json,
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [str(self.yosys), "-q", "-s", str(script)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_normalized_module_output_has_one_driver_and_is_equivalent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            original_module = Module(name="tier")
            add_port(original_module, "y", "output", ["1"])
            add_netname(original_module, "y", ["1"])
            normalized_module = deepcopy(original_module)
            normalize_module_constants(normalized_module, LEAF_TYPES, TIE_SPECS)
            original_json = root / "original.json"
            normalized_json = root / "normalized.json"
            dump_design(Design(modules=OrderedDict([("tier", original_module)])), original_json)
            dump_design(Design(modules=OrderedDict([("tier", normalized_module)])), normalized_json)
            models_v = root / "models.v"
            models_v.write_text(
                "module TIELO(output Y); assign Y = 1'b0; endmodule\n"
                "module TIEHI(output Y); assign Y = 1'b1; endmodule\n",
                encoding="utf-8",
            )
            normalized_v = root / "normalized.v"
            script = root / "equiv_output.ys"
            script.write_text(
                "read_json {}\n"
                "hierarchy -check -top tier\n"
                "rename tier gold\n"
                "design -stash gold_design\n"
                "design -reset\n"
                "read_verilog {}\n"
                "read_json {}\n"
                "hierarchy -check -top tier\n"
                "flatten\n"
                "rename tier gate\n"
                "design -stash gate_design\n"
                "design -reset\n"
                "design -copy-from gold_design -as gold gold\n"
                "design -copy-from gate_design -as gate gate\n"
                "equiv_make gold gate equiv\n"
                "prep -top equiv\n"
                "equiv_simple\n"
                "equiv_status -assert\n"
                "design -reset\n"
                "read_verilog {}\n"
                "read_json {}\n"
                "hierarchy -check -top tier\n"
                "write_verilog -noattr {}\n".format(
                    original_json,
                    models_v,
                    normalized_json,
                    models_v,
                    normalized_json,
                    normalized_v,
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [str(self.yosys), "-q", "-s", str(script)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            normalized_text = normalized_v.read_text(encoding="utf-8")
            self.assertNotIn("assign y = 1'h1", normalized_text)


if __name__ == "__main__":
    unittest.main()
