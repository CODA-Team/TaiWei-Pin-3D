from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "export_partition.py"
SPEC = importlib.util.spec_from_file_location("export_partition", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
EXPORT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EXPORT
SPEC.loader.exec_module(EXPORT)


class ExportPartitionTest(unittest.TestCase):
    def write_def(
        self,
        root: Path,
        components: list[str],
        ports: list[dict[str, str]] | None = None,
        nets: list[dict[str, object]] | None = None,
    ) -> Path:
        ports = ports or []
        nets = nets or []
        component_text = "".join(
            f"- {name} BUF + PLACED ( 0 0 ) N ;\n" for name in components
        )
        pin_records: list[str] = []
        for port in ports:
            fields = [f"- {port['name']}", f"+ NET {port['net']}"]
            if "direction" in port:
                fields.append(f"+ DIRECTION {port['direction']}")
            if "use" in port:
                fields.append(f"+ USE {port['use']}")
            pin_records.append(" ".join(fields) + " ;\n")
        net_records: list[str] = []
        for net in nets:
            endpoints = " ".join(
                f"( {endpoint} {pin} )" for endpoint, pin in net["endpoints"]
            )
            suffix = str(net.get("suffix", ""))
            net_records.append(f"- {net['name']} {endpoints} {suffix} ;\n")
        path = root / "input.def"
        path.write_text(
            "VERSION 5.8 ;\n"
            f"COMPONENTS {len(components)} ;\n{component_text}END COMPONENTS\n"
            f"PINS {len(ports)} ;\n{''.join(pin_records)}END PINS\n"
            f"NETS {len(nets)} ;\n{''.join(net_records)}END NETS\n"
            "END DESIGN\n",
            encoding="utf-8",
        )
        return path

    def write_assignment(self, root: Path, tiers: dict[str, int]) -> Path:
        path = root / "assignment.json"
        records = [{"node": node, "tier": tier} for node, tier in tiers.items()]
        path.write_text(
            json.dumps(
                {
                    "schema": "orfs.d3d-partition.assignment",
                    "schema_version": 1,
                    "case_name": "unit",
                    "movable_count": len(records),
                    "assignments": records,
                }
            ),
            encoding="utf-8",
        )
        return path

    def run_export(
        self,
        root: Path,
        def_path: Path,
        assignment: Path,
        deferred: Path | None = None,
    ) -> tuple[str, dict[str, object]]:
        output = root / "partition.txt"
        summary = root / "summary.json"
        argv = [
            "--def",
            str(def_path),
            "--assignment",
            str(assignment),
            "--output",
            str(output),
            "--summary",
            str(summary),
        ]
        if deferred is not None:
            argv.extend(["--deferred-ties", str(deferred)])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(EXPORT.main(argv), 0)
        return output.read_text(encoding="utf-8"), json.loads(
            summary.read_text(encoding="utf-8")
        )

    def test_assigns_ports_by_unique_component_majority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ports = [
                {"name": "upper_port", "net": "n_upper", "direction": "INPUT"},
                {"name": "bottom_port", "net": "n_bottom", "direction": "OUTPUT"},
                {"name": "tie_port", "net": "n_tie", "direction": "INOUT"},
                {"name": "duplicate_pin_port", "net": "n_dup", "direction": "INPUT"},
                {"name": "orphan_port", "net": "n_orphan", "direction": "OUTPUT"},
                {"name": "shared_a", "net": "n+shared", "direction": "INPUT"},
                {"name": "shared_b", "net": "n+shared", "direction": "OUTPUT"},
                {"name": "VDD", "net": "VDD", "use": "POWER"},
                {"name": "VSS", "net": "VSS", "use": "GROUND"},
            ]
            nets = [
                {"name": "n_upper", "endpoints": [("PIN", "upper_port"), ("u0", "A"), ("u1", "A"), ("b0", "A")]},
                {"name": "n_bottom", "endpoints": [("PIN", "bottom_port"), ("b0", "B"), ("b1", "B"), ("u0", "B")]},
                {"name": "n_tie", "endpoints": [("PIN", "tie_port"), ("u0", "Y"), ("b0", "Y")]},
                {"name": "n_dup", "endpoints": [("PIN", "duplicate_pin_port"), ("u0", "A"), ("u0", "B"), ("b0", "A")]},
                {"name": "n_orphan", "endpoints": [("PIN", "orphan_port")]},
                {"name": "n+shared", "endpoints": [("PIN", "shared_a"), ("PIN", "shared_b"), ("u0", "A"), ("u1", "A")], "suffix": "+ ROUTED M1 ( 100 200 ) ( 300 400 )"},
                {"name": "VDD", "endpoints": [("PIN", "VDD"), ("u0", "VDD")]},
                {"name": "VSS", "endpoints": [("PIN", "VSS"), ("b0", "VSS")]},
            ]
            def_path = self.write_def(root, ["u0", "u1", "b0", "b1"], ports, nets)
            assignment = self.write_assignment(root, {"u0": 0, "u1": 0, "b0": 1, "b1": 1})

            output, report = self.run_export(root, def_path, assignment)

            self.assertEqual(
                output.splitlines(),
                [
                    "u0 0", "u1 0", "b0 1", "b1 1",
                    "upper_port 0", "bottom_port 1", "tie_port 1",
                    "duplicate_pin_port 1", "orphan_port 1",
                    "shared_a 0", "shared_b 0",
                ],
            )
            self.assertNotIn("VDD", output)
            self.assertNotIn("VSS", output)
            self.assertEqual(report["signal_port_count"], 7)
            self.assertEqual(report["port_tier0_count"], 3)
            self.assertEqual(report["port_tier1_count"], 4)
            self.assertEqual(report["port_tie_count"], 3)
            self.assertEqual(report["port_no_partitioned_neighbor_count"], 1)
            assignments = {item["port"]: item for item in report["io_assignments"]}
            self.assertEqual(assignments["duplicate_pin_port"]["upper_component_count"], 1)
            self.assertEqual(assignments["duplicate_pin_port"]["bottom_component_count"], 1)
            self.assertEqual(assignments["orphan_port"]["reason"], "no_partitioned_neighbor")
            repeat_output, repeat_report = self.run_export(root, def_path, assignment)
            self.assertEqual(repeat_output, output)
            self.assertEqual(repeat_report, report)

    def test_preserves_def_spelling_and_normalizes_escaped_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                [r"u\/x\[0\]"],
                [{"name": r"data\[0\]", "net": r"n\[0\]", "direction": "INPUT"}],
                [{"name": r"n\[0\]", "endpoints": [("PIN", r"data\[0\]"), (r"u\/x\[0\]", "A")]}],
            )
            assignment = self.write_assignment(root, {"u_x_0_": 0})

            output, _ = self.run_export(root, def_path, assignment)

            self.assertEqual(output, "u\\/x\\[0\\] 0\ndata\\[0\\] 0\n")

    def test_excludes_deferred_tie_from_component_and_io_counts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                ["u0", "tie0"],
                [{"name": "out", "net": "n", "direction": "OUTPUT"}],
                [{"name": "n", "endpoints": [("PIN", "out"), ("u0", "Y"), ("tie0", "H")]}],
            )
            assignment = self.write_assignment(root, {"u0": 0})
            deferred = root / "deferred.json"
            deferred.write_text(
                json.dumps(
                    {
                        "schema": "taiwei.d3d-partition.deferred-ties",
                        "schema_version": 1,
                        "source_def_sha256": EXPORT.sha256(def_path),
                        "deferred_instance_count": 1,
                        "deferred_net_count": 1,
                        "deferred_instances": [
                            {"d2d_name": "tie0", "normalized_instance": "tie0", "polarity": 1}
                        ],
                    }
                ),
                encoding="utf-8",
            )

            output, report = self.run_export(root, def_path, assignment, deferred)

            self.assertEqual(output, "u0 0\nout 0\n")
            self.assertEqual(report["deferred_tie_count"], 1)
            self.assertEqual(report["io_assignments"][0]["upper_component_count"], 1)

    def test_rejects_incomplete_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(root, ["u1", "u2"])
            assignment = self.write_assignment(root, {"u1": 0})

            with self.assertRaisesRegex(ValueError, "does not cover DEF components exactly"):
                self.run_export(root, def_path, assignment)

    def test_rejects_unknown_net_component_or_port(self) -> None:
        cases = [
            (("missing", "A"), "unknown component"),
            (("PIN", "missing_port"), "unknown ports"),
        ]
        for endpoint, message in cases:
            with self.subTest(endpoint=endpoint), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                def_path = self.write_def(
                    root,
                    ["u0"],
                    [{"name": "in", "net": "n", "direction": "INPUT"}],
                    [{"name": "n", "endpoints": [("PIN", "in"), endpoint]}],
                )
                assignment = self.write_assignment(root, {"u0": 0})
                with self.assertRaisesRegex(ValueError, message):
                    self.run_export(root, def_path, assignment)

    def test_rejects_pin_net_mismatch_and_multiple_net_membership(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                ["u0"],
                [{"name": "in", "net": "n0", "direction": "INPUT"}],
                [
                    {"name": "n0", "endpoints": [("PIN", "in"), ("u0", "A")]},
                    {"name": "n1", "endpoints": [("PIN", "in"), ("u0", "B")]},
                ],
            )
            assignment = self.write_assignment(root, {"u0": 0})
            with self.assertRaisesRegex(ValueError, "appears in 2 NETS records"):
                self.run_export(root, def_path, assignment)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                ["u0"],
                [{"name": "in", "net": "n0", "direction": "INPUT"}],
                [{"name": "n0", "endpoints": [("u0", "A")]}],
            )
            assignment = self.write_assignment(root, {"u0": 0})
            with self.assertRaisesRegex(ValueError, "absent from NETS record"):
                self.run_export(root, def_path, assignment)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                ["u0"],
                [{"name": "in", "net": "missing_net", "direction": "INPUT"}],
            )
            assignment = self.write_assignment(root, {"u0": 0})
            with self.assertRaisesRegex(ValueError, "references missing net"):
                self.run_export(root, def_path, assignment)

    def test_rejects_component_name_normalization_collision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(root, [r"u\/x", "u_x"])
            assignment = self.write_assignment(root, {"u_x": 0})
            with self.assertRaisesRegex(ValueError, "normalization creates 1 collision"):
                self.run_export(root, def_path, assignment)

    def test_rejects_port_name_normalization_collision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(
                root,
                ["u0"],
                [
                    {"name": r"in\[0\]", "net": "n", "direction": "INPUT"},
                    {"name": "in[0]", "net": "n", "direction": "INPUT"},
                ],
                [{"name": "n", "endpoints": [("PIN", r"in\[0\]"), ("u0", "A")]}],
            )
            assignment = self.write_assignment(root, {"u0": 0})
            with self.assertRaisesRegex(ValueError, "duplicate normalized port names"):
                self.run_export(root, def_path, assignment)


if __name__ == "__main__":
    unittest.main()
