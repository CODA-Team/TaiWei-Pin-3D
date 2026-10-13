#!/usr/bin/env python3

import os
import sys
import unittest


STAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLOW_HOME = os.path.normpath(os.path.join(STAGE_DIR, "..", ".."))
if STAGE_DIR not in sys.path:
    sys.path.insert(0, STAGE_DIR)

from cell_map import load_cell_map  # noqa: E402


class CellMapTest(unittest.TestCase):
    def test_current_taiwei_schema_is_canonicalized(self):
        path = os.path.join(FLOW_HOME, "platforms", "asap7_nangate45_3D", "map.json")
        data = load_cell_map(path)
        entry = data["cells"]["AND2_X1"]
        self.assertEqual(entry["base"], "AND2_X1")
        self.assertEqual(entry["bottom"]["macro"], "AND2_X1_bottom")
        self.assertEqual(entry["upper"]["macro"], "AND2x2_ASAP7_75t_R_upper")
        self.assertEqual(entry["pin_map"]["A1"], "A")
        self.assertEqual(entry["pin_map"]["ZN"], "Y")


if __name__ == "__main__":
    unittest.main()
