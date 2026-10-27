import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "predict_util.py"
SPEC = importlib.util.spec_from_file_location("predict_util", MODULE_PATH)
PREDICT_UTIL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREDICT_UTIL)


ALU_SCHEMA = {
    "ALU": {
        "parameterized_ports": [
            {"name": "A", "direction": "input", "slot_idx": 0},
            {"name": "B", "direction": "input", "slot_idx": 1},
            {"name": "X", "direction": "output", "slot_idx": 2},
            {"name": "Y", "direction": "output", "slot_idx": 3},
            {"name": "CO", "direction": "output", "slot_idx": 4},
        ],
        "fixed_ports": [
            {"name": "CI", "direction": "input"},
            {"name": "BI", "direction": "input"},
        ],
    }
}


def port(width):
    return {"dir": "input", "width": width}


class ZeroWidthPortTest(unittest.TestCase):
    def setUp(self):
        self.zero_a_ports = {
            "B": port(32),
            "BI": port(1),
            "CI": port(1),
            "CO": port(32),
            "X": port(32),
            "Y": port(32),
        }

    def test_zero_width_parameterized_port_may_be_absent(self):
        vector = PREDICT_UTIL.build_bitwidth_vec(
            "ALU",
            self.zero_a_ports,
            ALU_SCHEMA,
            "_alu_B32_BI1_CI1_CO32_X32_Y32",
        )
        self.assertEqual(vector, [0, 32, 32, 32, 32])

    def test_positive_width_parameterized_port_must_exist(self):
        with self.assertRaisesRegex(AssertionError, "Positive-width port ALU.A"):
            PREDICT_UTIL.build_bitwidth_vec(
                "ALU",
                self.zero_a_ports,
                ALU_SCHEMA,
                "_alu_A32_B32_BI1_CI1_CO32_X32_Y32",
            )

    def test_fixed_port_must_exist(self):
        ports = dict(self.zero_a_ports)
        ports.pop("CI")
        with self.assertRaisesRegex(AssertionError, "Fixed ports missing"):
            PREDICT_UTIL.build_bitwidth_vec(
                "ALU",
                ports,
                ALU_SCHEMA,
                "_alu_B32_BI1_CI1_CO32_X32_Y32",
            )

    def test_unexpected_port_is_rejected(self):
        ports = dict(self.zero_a_ports, UNKNOWN=port(1))
        with self.assertRaisesRegex(AssertionError, "Unexpected netlist ports"):
            PREDICT_UTIL.build_bitwidth_vec(
                "ALU",
                ports,
                ALU_SCHEMA,
                "_alu_B32_BI1_CI1_CO32_X32_Y32",
            )


if __name__ == "__main__":
    unittest.main()
