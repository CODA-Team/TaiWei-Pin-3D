"""Exercise native flow dispatch without running synthesis or physical tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ["cds-coarse-synth", "ord-coarse-partition", "cds-per-tier-synth",
            "ord-3dsyn-handoff"]
BACKEND = ["ord-3d-floorplan", "ord-3d-io", "ord-3d-split-net",
           "ord-place-macro-upper", "ord-place-macro-bottom", "ord-3d-pdn-only",
           "ord-place-init", "ord-place-init-upper", "ord-place-init-bottom",
           "ord-place-upper", "ord-place-bottom", "ord-gp2lg",
           "ord-detail-place-3d", "ord-cts-3d", "ord-route-3d-cts", "ord-final"]


class NativeFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ["env.sh", "test/openroad/ORD_3D_NEW_FLOW.sh",
                     "test/openroad/README.sh", "test/common/run_stage.sh",
                     "test/common/run_case.sh", "test/asap7_3D/gcd/ord/run.sh",
                     "scripts_3dsyn/run_3d_syn.sh"]:
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
        design = self.root / "designs/asap7_3D/gcd"
        design.mkdir(parents=True)
        (design / "config.mk").touch()
        (design / "config2d.mk").touch()
        self.trace = self.root / "trace.jsonl"
        self.mock_make = self.root / "bin/make"
        self.mock_make.parent.mkdir()
        self.mock_make.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
target = [arg for arg in args if not arg.startswith('-') and '=' not in arg][-1]
config = next((arg.split('=', 1)[1] for arg in args if arg.startswith('DESIGN_CONFIG=')), os.getenv('DESIGN_CONFIG'))
record = dict(target=target, config=config, variant=os.getenv('FLOW_VARIANT'),
              results=os.getenv('RESULTS_DIR'), allow_net=os.getenv('TIER_ALLOW_NET'))
with open(os.environ['NATIVE_TEST_TRACE'], 'a') as stream:
    stream.write(json.dumps(record) + '\\n')
if target == os.getenv('NATIVE_TEST_FAIL'):
    sys.exit(23)
''')
        self.mock_make.chmod(0o755)
        # Keep tests independent of the invoking shell's flow/Make settings.
        self.env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG") if key in os.environ}
        self.env.update(PATH=f"{self.mock_make.parent}:{self.env.get('PATH', '')}",
                        NATIVE_TEST_TRACE=str(self.trace), FLOW_VARIANT="native_test")

    def run_script(self, name, args=(), **env):
        self.trace.unlink(missing_ok=True)
        result = subprocess.run(["bash", str(self.root / name), *args],
                                cwd=self.root, env={**self.env, **env},
                                text=True, capture_output=True)
        records = [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return result, records

    def launch(self, **env):
        return self.run_script("test/openroad/ORD_3D_NEW_FLOW.sh",
                               ["asap7_3D", "native_test", "openroad", "gcd"], **env)

    def test_default_case_dispatches_native_stages_with_matching_handoffs(self):
        result, records = self.run_script("test/asap7_3D/gcd/ord/run.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['target'] for r in records], ["clean_all"] + FRONTEND + BACKEND)
        for record in records:
            expected_config = "config2d.mk" if record['target'] in FRONTEND else "config.mk"
            self.assertEqual(record['config'], f"designs/asap7_3D/gcd/{expected_config}")
            self.assertEqual(record['variant'], "native_test")
            self.assertEqual(record['results'], "./results/asap7_3D/gcd/native_test")
        for tier in ("upper", "bottom"):
            record = next(r for r in records if r['target'] == f'ord-place-{tier}')
            self.assertEqual(record['allow_net'], f'{tier}-only')

    def test_resume_skips_clean_and_completed_stages(self):
        for start in ("cds-per-tier-synth", "ord-3d-floorplan", "ord-detail-place-3d", "ord-cts-3d", "ord-route"):
            with self.subTest(start=start):
                result, records = self.launch(START_FROM=start)
                self.assertEqual(result.returncode, 0, result.stderr)
                stages = FRONTEND + BACKEND
                canonical = "ord-route-3d-cts" if start == "ord-route" else start
                self.assertEqual([r['target'] for r in records], stages[stages.index(canonical):])

    def test_failed_stage_stops_pipeline_before_consuming_stale_handoffs(self):
        for stage in FRONTEND + ["ord-place-upper", "ord-detail-place-3d", "ord-cts-3d"]:
            with self.subTest(stage=stage):
                result, records = self.launch(NATIVE_TEST_FAIL=stage)
                self.assertEqual(result.returncode, 23)
                self.assertEqual(records[-1]['target'], stage)
                self.assertNotIn("flow completed", result.stdout)

    def test_legacy_bootstrap_and_invalid_resume_fail_before_clean(self):
        for env in ({"SKIP_2D_PART": "1"}, {"REUSE_2DPART_FROM_VARIANT": "old"},
                    {"START_FROM": "ord-pre"}, {"START_FROM": "ord-cts-post"},
                    {"OUTER_ITERATIONS": "0"}):
            with self.subTest(env=env):
                result, records = self.launch(**env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(records, [])

    def test_single_stage_wrapper_uses_frontend_libraries(self):
        for stage in FRONTEND + ["ord-3d-synth", "ord-detail-place-3d", "ord-cts-3d"]:
            with self.subTest(stage=stage):
                result, records = self.run_script("test/common/run_stage.sh",
                    ["asap7_3D", "native_test", "openroad", "gcd", stage])
                self.assertEqual(result.returncode, 0, result.stderr)
                config = "config2d.mk" if stage in FRONTEND + ["ord-3d-synth"] else "config.mk"
                self.assertEqual(records[0]['config'], f"designs/asap7_3D/gcd/{config}")

    def test_standalone_synthesis_defaults_to_openroad(self):
        result, records = self.run_script("scripts_3dsyn/run_3d_syn.sh", ["asap7_3D", "gcd", "native_test"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['target'] for r in records], FRONTEND)

    def test_readme_example_uses_same_native_pipeline(self):
        result, records = self.run_script("test/openroad/README.sh", ENABLEMENT="asap7_3D")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['target'] for r in records], ["clean_all"] + FRONTEND + BACKEND)

    def run_make_target(self, target, config, **env):
        self.trace.unlink(missing_ok=True)
        result = subprocess.run(["/usr/bin/make", "--no-print-directory",
                                 f"MAKE={self.mock_make}", f"DESIGN_CONFIG=designs/asap7_3D/gcd/{config}", target],
                                cwd=ROOT, env={**self.env, **env}, text=True, capture_output=True)
        records = [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return result, records

    def test_make_backend_matches_launcher(self):
        result, records = self.run_make_target("ord-3d-flow", "config.mk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['target'] for r in records], BACKEND)

    def test_make_frontend_keeps_3d_output_directory(self):
        result, records = self.run_make_target("ord-3d-synth", "config2d.mk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['target'] for r in records], FRONTEND)
        for record in records:
            self.assertEqual(record['results'], "./results/asap7_3D/gcd/native_test")
        result, records = self.run_make_target("ord-3d-synth", "config.mk")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(records, [])

    def test_make_global_placement_failure_stops_native_backend(self):
        result, records = self.run_make_target("ord-3d-flow", "config.mk", NATIVE_TEST_FAIL="ord-place-upper")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(records[-1]['target'], "ord-place-upper")


if __name__ == '__main__':
    unittest.main()
