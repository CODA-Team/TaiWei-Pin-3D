# Test Script Guide

This directory contains the stable entry points for running, rerunning, evaluating, and inspecting 3D flow test cases.

Use these scripts as the public interface. Strategy documents under `DOC/` should describe behavior and architecture, but should not embed ad hoc runtime-artifact paths.

## Common Wrappers

### Run one full case

- `test/common/run_case.sh <ord|cds> <case_dir>`

Examples:

```bash
bash test/common/run_case.sh ord test/asap7_3D/ibex/ord
bash test/common/run_case.sh cds test/asap7_3D/ibex/cds
```

What it does:

- resolves the repo root from the case directory
- selects the correct launcher
- forwards `FLOW_VARIANT`, `USE_FLOW`, and other flow environment variables

### Run one stage only

- `test/common/run_stage.sh <enablement> <flow_variant> <use_flow> <design_nickname> <make_target>`

Examples:

```bash
bash test/common/run_stage.sh asap7_3D ORD_CI openroad ibex ord-route
bash test/common/run_stage.sh asap7_3D cadence cadence ibex cds-route
```

Use this when:

- reproducing a bug at a single stage
- rerunning `cts`, `route`, `final`, or `restore` without launching the whole flow
- validating a local Tcl change quickly

### Run evaluation only

- `test/common/eval_case.sh <ord|cds> <case_dir>`

Examples:

```bash
bash test/common/eval_case.sh ord test/asap7_3D/ibex/ord
bash test/common/eval_case.sh cds test/asap7_3D/ibex/cds
```

Behavior:

- `ord` evaluation runs `cds-final`
- `cds` evaluation runs `cds-restore`

This asymmetric contract is the supported CI policy:

- `ord` means OpenROAD-origin results with native OpenROAD metrics plus Cadence `cds-final` eval
- `cds` means Cadence-origin results with native Cadence metrics plus Cadence `cds-restore` eval
- `cds -> ord-final` and `cds -> cds-final(defIn)` are research-only paths, not blocking CI

### Run internal CI regression

- `python3 util/run_internal_ci.py <smoke|full>`

Examples:

```bash
python3 util/run_internal_ci.py smoke
python3 util/run_internal_ci.py full --jobs 6
python3 util/run_internal_ci.py smoke --flow ord
python3 util/run_internal_ci.py smoke --host-list hnode19 hnode21 --max-jobs-per-host 1
python3 util/run_internal_ci.py smoke --research-cds-openroad-eval
```

Behavior:

- runs supported contracts only by default:
  - `ord` flow -> native OpenROAD metrics + Cadence `cds-final` eval
  - `cds` flow -> native Cadence metrics + Cadence `cds-restore` eval
- default CI variants are derived from `--variant-base`:
  - `ORD_CI__ord` means the `ord` flow-origin result directory for a given `tech/design`
  - `ORD_CI__cds` means the `cds` flow-origin result directory for the same `tech/design`
  - in practice, each `tech/design` can therefore have two CI handoff trees under `logs/`, `results/`, and `reports/`
- reuses `run_experiments.py` for the supported flow/eval path
- compares generated JSONs against baselines under:
  - supported `ord` baselines:
    - `designs/<tech>/<case>/ci/ord/openroad_eval.json`
    - `designs/<tech>/<case>/ci/ord/cadence_eval.json`
    - legacy fallback:
      - `designs/<tech>/<case>/openroad_eval.json`
      - `designs/<tech>/<case>/cadence_eval.json`
  - supported `cds` baseline:
    - `designs/<tech>/<case>/ci/cds/cadence_eval.json`
- if `--research-cds-openroad-eval` is enabled, it also compares against:
  - `designs/<tech>/<case>/ci/research/cds/openroad_eval.json`
- if a baseline JSON is missing, seeds it from the current run automatically

## OpenROAD Entry Points

### Default Native 3D OpenROAD flow

- `test/openroad/ORD_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>`

Examples:

```bash
bash test/openroad/ORD_3D_NEW_FLOW.sh asap7_3D ORD_CI openroad ibex
bash test/openroad/ORD_3D_NEW_FLOW.sh nangate45_3D debug_variant openroad swerv_wrapper
```

On `native-3d`, this launcher (also used by per-case `run.sh` and
`run_experiments.py --flow ord`) selects 3D-Syn, TDP and 3DCTS automatically.
Genus, 3D-Syn-enabled Yosys and TDP/3DCTS-enabled OpenROAD must be available.

The frontend runs `cds-coarse-synth`, `ord-coarse-partition`,
`cds-per-tier-synth`, and `ord-3dsyn-handoff` with `config2d.mk`. The backend
uses `config.mk`, starting with `ord-3d-floorplan`, keeping the existing
floorplan/IO/macro/PDN/global-placement preparation, then running
`ord-gp2lg`, `ord-detail-place-3d`, `ord-cts-3d`, `ord-route-3d-cts`, and `ord-final`.
Both configurations use the same 3D platform, design and variant output paths.
The 3D-Syn handoff supplies `<design>_3D.fp.v/.def`; do not run `ord-pre`
after it, because that would regenerate views from the coarse netlist.

For Make-level operation, run the frontend and backend with their respective
library configurations:

```bash
make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk FLOW_VARIANT=native ord-3d-synth
make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk FLOW_VARIANT=native ord-3d-flow
```

`START_FROM` skips cleaning and earlier stages. It accepts the four frontend
targets and the native backend stages, including `ord-detail-place-3d`,
`ord-cts-3d` and `ord-route-3d-cts` (`ord-route` is a resume alias).
Use `START_FROM=ord-3d-floorplan` after an existing 3D-Syn handoff.
Legacy `SKIP_2D_PART`, `REUSE_2DPART_FROM_VARIANT`, `ord-pre` and
`ord-cts-post` resume requests are rejected before cleaning results.

Useful environment variables:

- `NUM_CORES`
- `OUTER_ITERATIONS`
- `PIN3D_ALLOW_NET_FLOW`
- `PIN3D_SPLIT_NET_FLOW`
- `START_FROM`

### Allow-net comparison matrix

- `test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh`

Use this when comparing:

- allow-net on vs off
- split-net on vs off
- matrix-style OpenROAD experiments on the same design

### OpenROAD GUI reopen

- `test/openroad/ORD_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>`

Examples:

```bash
bash test/openroad/ORD_3D_OPEN_GUI.sh asap7_3D ORD_CI ibex ord-route
bash test/openroad/ORD_3D_OPEN_GUI.sh asap7_3D ORD_CI ibex results/asap7_3D/ibex/ORD_CI/handoffs/route.tcl
```

Use this to reopen a stage handoff in the OpenROAD GUI.

## Cadence Entry Points

### Full 3D Cadence flow

- `test/commercial/CDS_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>`

Examples:

```bash
bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_3D cadence cadence ibex
bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_nangate45_3D cadence_debug cadence swerv_wrapper
```

The Cadence launcher retains its own staged flow and these controls:

- `NUM_CORES`
- `OUTER_ITERATIONS`
- `PIN3D_ALLOW_NET_FLOW`
- `PIN3D_SPLIT_NET_FLOW`
- `SKIP_2D_PART`
- `START_FROM`

### Allow-net comparison matrix

- `test/commercial/CDS_3D_ALLOW_NET_MATRIX.sh`

Use this when running Cadence allow-net / split-flow comparisons on the same design.

### Cadence GUI reopen

- `test/commercial/CDS_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>`

Examples:

```bash
bash test/commercial/CDS_3D_OPEN_GUI.sh asap7_3D cadence ibex cds-route
bash test/commercial/CDS_3D_OPEN_GUI.sh asap7_3D cadence ibex route-legacy
```

Use this to reopen a staged Cadence handoff in Innovus GUI.

## Per-Case Wrappers

Each design directory also contains tiny per-case wrappers such as:

- `test/asap7_3D/ibex/ord/run.sh`
- `test/asap7_3D/ibex/cds/run.sh`

These are convenient when:

- you already know the exact case directory
- you want a short command that plugs into `run_case.sh`
- you want to keep CI or regression scripts compact

## Example Workflows

### Fresh OpenROAD run

```bash
FLOW_VARIANT=ORD_CI bash test/asap7_3D/ibex/ord/run.sh
```

### Resume one OpenROAD stage

```bash
bash test/common/run_stage.sh asap7_3D ORD_CI openroad ibex ord-cts-3d
```

### Fresh Cadence run

```bash
FLOW_VARIANT=cadence bash test/asap7_3D/ibex/cds/run.sh
```

### Re-extract final metrics only

```bash
bash test/common/run_stage.sh asap7_3D cadence cadence ibex cds-restore
```
