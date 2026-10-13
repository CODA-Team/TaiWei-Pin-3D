#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
STAGE_DIR = TEST_DIR.parent
FLOW_HOME = STAGE_DIR.parent.parent
TOOLKIT_ROOT = FLOW_HOME / "scripts_3dsyn" / "coarse_synth" / "common"
sys.path.insert(0, str(TOOLKIT_ROOT))

from yosys_json_toolkit import (  # noqa: E402
    Module,
    add_port_with_netname,
    copy_port_shape_metadata,
    load_design,
    module_port_shape_signature,
    normalize_module_port_shapes,
    port_bit_labels,
    port_is_single_bit_vector,
)


DEFAULT_YOSYS = FLOW_HOME.parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys"
YOSYS = Path(os.environ.get("YOSYS", str(DEFAULT_YOSYS)))
SOURCE_V = TEST_DIR / "data" / "port_shapes.v"


class PortInterfaceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not YOSYS.is_file():
            raise unittest.SkipTest("Yosys executable not found: {}".format(YOSYS))
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="syn3d_port_interface_")
        cls.source_json = Path(cls.temp_dir.name) / "source.json"
        cls.roundtrip_v = Path(cls.temp_dir.name) / "roundtrip.v"
        cls.roundtrip_json = Path(cls.temp_dir.name) / "roundtrip.json"
        script = Path(cls.temp_dir.name) / "roundtrip.ys"
        script.write_text(
            "read_verilog {source}\n"
            "hierarchy -top port_shapes\n"
            "proc\n"
            "write_json {source_json}\n"
            "write_verilog -norename -noexpr -noattr {roundtrip_v}\n"
            "design -reset\n"
            "read_verilog {roundtrip_v}\n"
            "hierarchy -top port_shapes\n"
            "proc\n"
            "write_json {roundtrip_json}\n".format(
                source=SOURCE_V,
                source_json=cls.source_json,
                roundtrip_v=cls.roundtrip_v,
                roundtrip_json=cls.roundtrip_json,
            )
        )
        subprocess.run([str(YOSYS), "-q", "-s", str(script)], check=True)
        cls.source = load_design(str(cls.source_json)).modules["port_shapes"]
        cls.roundtrip = load_design(str(cls.roundtrip_json)).modules["port_shapes"]

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temp_dir"):
            cls.temp_dir.cleanup()

    def test_02_scalar_and_explicit_single_bit_vectors_are_distinct(self):
        self.assertEqual(port_bit_labels(self.source, "scalar_i"), [(None, "scalar_i")])
        self.assertEqual(port_bit_labels(self.source, "zero_i"), [(0, "zero_i[0]")])
        self.assertEqual(port_bit_labels(self.source, "five_i"), [(5, "five_i[5]")])
        self.assertFalse(port_is_single_bit_vector(self.source, "scalar_i"))
        self.assertTrue(port_is_single_bit_vector(self.source, "zero_i"))
        self.assertTrue(port_is_single_bit_vector(self.source, "five_i"))

    def test_02_bus_labels_follow_yosys_bit_order(self):
        self.assertEqual(
            port_bit_labels(self.source, "down_i"),
            [(4, "down_i[4]"), (5, "down_i[5]"), (6, "down_i[6]"), (7, "down_i[7]")],
        )
        self.assertEqual(
            port_bit_labels(self.source, "up_i"),
            [(5, "up_i[5]"), (4, "up_i[4]"), (3, "up_i[3]"), (2, "up_i[2]")],
        )

    def test_07_08_yosys_roundtrip_preserves_the_semantic_interface(self):
        self.assertEqual(
            module_port_shape_signature(self.source),
            module_port_shape_signature(self.roundtrip),
        )
        text = self.roundtrip_v.read_text()
        self.assertIn("input [0:0] zero_i;", text)
        self.assertIn("input [5:5] five_i;", text)
        self.assertIn("input scalar_i;", text)

    def test_05_wrapper_copies_single_bit_vector_metadata(self):
        wrapper = Module(name="wrapper")
        for name, source_port in self.source.ports.items():
            add_port_with_netname(
                wrapper,
                name,
                source_port.direction,
                source_port.bits,
                offset=source_port.offset,
                upto=source_port.upto,
                signed=source_port.signed,
            )
            copy_port_shape_metadata(self.source, wrapper, name)
        self.assertEqual(
            module_port_shape_signature(self.source),
            module_port_shape_signature(wrapper),
        )

    def test_06_tool_boundary_normalization_uses_the_source_contract(self):
        normalized = deepcopy(self.source)
        for name in ("zero_i", "five_i", "zero_o", "five_o"):
            port = normalized.ports[name]
            netname = normalized.netnames[name]
            port.offset = None
            port.upto = None
            netname.offset = None
            netname.upto = None
            netname.attributes.pop("single_bit_vector", None)
        normalized.ports = normalized.ports.__class__(reversed(list(normalized.ports.items())))

        changed = normalize_module_port_shapes(self.source, normalized)
        self.assertEqual(changed, ["zero_i", "five_i", "zero_o", "five_o"])
        self.assertEqual(
            module_port_shape_signature(self.source),
            module_port_shape_signature(normalized),
        )

    def test_09_partition_labels_cover_every_primary_bit_exactly(self):
        labels = []
        for port_name in self.source.ports:
            labels.extend(label for _index, label in port_bit_labels(self.source, port_name))
        self.assertEqual(len(labels), sum(len(port.bits) for port in self.source.ports.values()))
        self.assertEqual(len(labels), len(set(labels)))
        self.assertIn("zero_i[0]", labels)
        self.assertIn("five_i[5]", labels)
        self.assertIn("scalar_i", labels)
        self.assertNotIn("zero_i", labels)

    def test_conflicting_same_name_netname_is_rejected(self):
        broken = deepcopy(self.source)
        broken.netnames["zero_i"].bits = [999]
        with self.assertRaisesRegex(ValueError, "different bits"):
            port_bit_labels(broken, "zero_i")


if __name__ == "__main__":
    unittest.main()
