from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "export_partition.py"
SPEC = importlib.util.spec_from_file_location("export_partition", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class ExportPartitionTest(unittest.TestCase):
    def write_def(self, root: Path, names: list[str]) -> Path:
        path = root / "input.def"
        components = "".join(f"- {name} BUF + PLACED ( 0 0 ) N ;\n" for name in names)
        path.write_text(
            f"VERSION 5.8 ;\nCOMPONENTS {len(names)} ;\n"
            f"{components}END COMPONENTS\nEND DESIGN\n",
            encoding="utf-8",
        )
        return path

    def write_assignment(self, root: Path, records: list[dict[str, object]]) -> Path:
        path = root / "assignment.json"
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

    def test_exports_original_def_names_in_def_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(root, [r"u\[0\]", "u2"])
            assignment = self.write_assignment(
                root,
                [{"node": "u2", "tier": 1}, {"node": "u_0_", "tier": 0}],
            )
            output = root / "partition.txt"
            summary = root / "summary.json"

            status = EXPORT.main(
                [
                    "--def",
                    str(def_path),
                    "--assignment",
                    str(assignment),
                    "--output",
                    str(output),
                    "--summary",
                    str(summary),
                ]
            )

            self.assertEqual(status, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), "u\\[0\\] 0\nu2 1\n")
            report = json.loads(summary.read_text(encoding="utf-8"))
            self.assertEqual(report["tier0_count"], 1)
            self.assertEqual(report["tier1_count"], 1)

    def test_rejects_incomplete_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def_path = self.write_def(root, ["u1", "u2"])
            assignment = self.write_assignment(
                root, [{"node": "u1", "tier": 0}]
            )

            with self.assertRaisesRegex(ValueError, "does not cover DEF components exactly"):
                EXPORT.main(
                    [
                        "--def",
                        str(def_path),
                        "--assignment",
                        str(assignment),
                        "--output",
                        str(root / "partition.txt"),
                        "--summary",
                        str(root / "summary.json"),
                    ]
                )


if __name__ == "__main__":
    unittest.main()
