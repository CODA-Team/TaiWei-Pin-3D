import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


COARSE_SYNTH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(COARSE_SYNTH_DIR))

import characterize_coarse_units as characterize


class CellPolicyEnvironmentTest(unittest.TestCase):
    def test_tier_policy_parses_patterns_and_optional_exceptions(self):
        environment = {
            "SYN3D_DONT_USE_CELLS_UPPER": "'*x1p*_ASAP7*_upper' ICG*_upper",
            "SYN3D_GENUS_DONT_USE_EXCEPTIONS_UPPER": "HAxp5_ASAP7_75t_R_upper",
        }
        with mock.patch.dict(characterize.os.environ, environment, clear=True):
            self.assertEqual(
                characterize.tier_cell_policy("upper"),
                {
                    "dont_use": ["*x1p*_ASAP7*_upper", "ICG*_upper"],
                    "exceptions": ["HAxp5_ASAP7_75t_R_upper"],
                },
            )

    def test_missing_required_tier_policy_is_rejected(self):
        with mock.patch.dict(characterize.os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "Required cell policy is empty"):
                characterize.tier_cell_policy("bottom")

    def test_missing_exception_variable_is_supported(self):
        environment = {
            "SYN3D_DONT_USE_CELLS_BOTTOM": "TAPCELL_X1_bottom",
        }
        with mock.patch.dict(characterize.os.environ, environment, clear=True):
            self.assertEqual(
                characterize.tier_cell_policy("bottom"),
                {
                    "dont_use": ["TAPCELL_X1_bottom"],
                    "exceptions": [],
                },
            )


class ManifestContractTest(unittest.TestCase):
    def test_empty_manifest_is_a_valid_empty_set(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "coarse_units.list"
            manifest.write_text("", encoding="utf-8")

            units = characterize.read_unit_manifest(manifest)
            characterize.validate_manifest_sources(units, root / "missing_sources")
            summary = characterize.write_empty_characterization(
                root / "characterization", "nangate45_3D"
            )

            self.assertEqual(units, [])
            self.assertEqual(summary["unit_count"], 0)
            self.assertEqual(summary["units"], {})
            written = json.loads(
                (root / "characterization" / "summary.json").read_text(encoding="utf-8")
            )
            self.assertEqual(written, summary)
            for path in [
                root / "characterization" / "implementation",
                root / "characterization" / "metrics" / "bottom",
                root / "characterization" / "metrics" / "upper",
                root / "characterization" / "library",
            ]:
                self.assertTrue(path.is_dir(), path)

    def test_missing_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with self.assertRaisesRegex(RuntimeError, "manifest is missing"):
                characterize.read_unit_manifest(Path(temp_dir) / "missing.list")

    def test_duplicate_manifest_entry_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest = Path(temp_dir) / "coarse_units.list"
            manifest.write_text("unit_a\nunit_a\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "duplicate coarse-unit type"):
                characterize.read_unit_manifest(manifest)

    def test_manifest_and_rtlil_set_must_match(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_dir = root / "coarse_units"
            source_dir.mkdir()
            (source_dir / "unit_a.rtlil").write_text("module \\unit_a\nend\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "manifest/source mismatch"):
                characterize.validate_manifest_sources([], source_dir)
            with self.assertRaisesRegex(RuntimeError, "manifest/source mismatch"):
                characterize.validate_manifest_sources(["unit_a", "unit_b"], source_dir)


if __name__ == "__main__":
    unittest.main()
