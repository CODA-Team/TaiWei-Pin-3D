#!/usr/bin/env python3

import os
import sys
import unittest


STAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if STAGE_DIR not in sys.path:
    sys.path.insert(0, STAGE_DIR)

from hbt_model import build_hbt_model, render_hbt_tcl, resolve_hbt_config  # noqa: E402


def wrapper_plan():
    return {
        "data_d2d_channels": [
            {
                "d2d_name": "bottom_to_upper",
                "producer_tier": "bottom",
                "consumer_tier": "upper",
            },
            {
                "d2d_name": "upper_to_bottom",
                "producer_tier": "upper",
                "consumer_tier": "bottom",
            },
        ],
        "clock": {"clock_d2d_channels": []},
    }


DRIVERS = {"upper": "BUFx2_ASAP7_75t_R_upper", "bottom": "BUF_X1_bottom"}


class HbtModelTest(unittest.TestCase):
    def test_default_direct_configuration(self):
        config = resolve_hbt_config({})
        self.assertEqual(config["mode"], "direct")
        self.assertEqual(config["r_ohm"], 1.0)
        self.assertEqual(config["c_fF"], 0.5)

        model = build_hbt_model(wrapper_plan(), "asap7_nangate45_3D", config, DRIVERS)
        entries = {entry["net_name"]: entry for entry in model["entries"]}
        self.assertEqual(entries["bottom_to_upper"]["applied_res_kohm"], 0.001)
        self.assertEqual(entries["upper_to_bottom"]["applied_res_ohm"], 1.0)
        self.assertEqual(entries["bottom_to_upper"]["applied_cap_fF"], 0.5)
        self.assertEqual(entries["upper_to_bottom"]["applied_cap_fF"], 0.5)

        tcl = render_hbt_tcl(model)
        self.assertEqual(tcl.count("set_resistance 0.001"), 2)
        self.assertEqual(tcl.count("set_load -wire_load 0.5"), 2)

    def test_scale_applies_producer_r_and_consumer_c(self):
        config = resolve_hbt_config(
            {
                "SYN3D_HBT_MODEL_MODE": "scale",
                "SYN3D_HBT_R_SCALE": "2",
                "SYN3D_HBT_C_SCALE": "0.5",
            }
        )
        model = build_hbt_model(wrapper_plan(), "asap7_nangate45_3D", config, DRIVERS)
        entries = {entry["net_name"]: entry for entry in model["entries"]}
        self.assertAlmostEqual(entries["bottom_to_upper"]["applied_res_kohm"], 4.979428871745193)
        self.assertAlmostEqual(entries["upper_to_bottom"]["applied_res_kohm"], 3.1411111111111114)
        self.assertAlmostEqual(entries["bottom_to_upper"]["applied_cap_fF"], 0.288521)
        self.assertAlmostEqual(entries["upper_to_bottom"]["applied_cap_fF"], 0.4873295)
        self.assertEqual(render_hbt_tcl(model).count("set_resistance"), 2)

    def test_direct_values_and_units(self):
        config = resolve_hbt_config(
            {
                "SYN3D_HBT_MODEL_MODE": "direct",
                "SYN3D_HBT_R_OHM": "250",
                "SYN3D_HBT_C_FF": "3.5",
            }
        )
        model = build_hbt_model(wrapper_plan(), "asap7_nangate45_3D", config, DRIVERS)
        self.assertTrue(all(entry["applied_res_kohm"] == 0.25 for entry in model["entries"]))
        self.assertTrue(all(entry["applied_cap_fF"] == 3.5 for entry in model["entries"]))
        tcl = render_hbt_tcl(model)
        self.assertEqual(tcl.count("set_resistance 0.25"), 2)
        self.assertEqual(tcl.count("set_load -wire_load 3.5"), 2)

    def test_zero_scale_disables_constraints(self):
        config = resolve_hbt_config(
            {"SYN3D_HBT_MODEL_MODE": "scale", "SYN3D_HBT_R_SCALE": "0", "SYN3D_HBT_C_SCALE": "0"}
        )
        model = build_hbt_model(wrapper_plan(), "asap7_nangate45_3D", config, DRIVERS)
        self.assertEqual(model["status"], "disabled")
        tcl = render_hbt_tcl(model)
        self.assertNotIn("set_resistance", tcl)
        self.assertNotIn("set_load", tcl)

    def test_invalid_public_configurations(self):
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            resolve_hbt_config({"SYN3D_HBT_MODEL_MODE": "unknown"})
        with self.assertRaisesRegex(ValueError, "non-negative"):
            resolve_hbt_config({"SYN3D_HBT_MODEL_MODE": "scale", "SYN3D_HBT_R_SCALE": "-1"})
        with self.assertRaisesRegex(ValueError, "non-negative"):
            resolve_hbt_config({"SYN3D_HBT_MODEL_MODE": "direct", "SYN3D_HBT_C_FF": "-1"})

    def test_driver_mismatch_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, "ABC driver"):
            build_hbt_model(
                wrapper_plan(),
                "asap7_nangate45_3D",
                resolve_hbt_config({}),
                {"upper": "wrong", "bottom": "BUF_X1_bottom"},
            )


if __name__ == "__main__":
    unittest.main()
