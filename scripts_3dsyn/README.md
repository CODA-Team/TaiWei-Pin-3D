# 3D-Syn: 3D Synthesis for TaiWei

3D-Syn is a synthesis flow for face-to-face 3D integrated circuits. It extends
Yosys with coarse-unit synthesis capabilities and uses the existing TaiWei
infrastructure for physical preparation, tier partitioning, and backend
implementation. Coarse partitioning and backend handoff can use either
Cadence Innovus or OpenROAD, while the Genus-based synthesis stages are shared.
The original TaiWei 2D synthesis flow remains available.

The Yosys commands used by this flow are implemented in
`ORFS-Research/tools/yosys/passes/3dsyn` and are compiled directly into Yosys.
This directory contains the Tcl, Python, and shell code that composes those
commands with Yosys, Cadence Genus, Innovus, OpenROAD, and TaiWei.

## Flow overview

The implementation follows the main steps of the 3D-Syn method:

1. **Coarse-Grained Netlist Construction.** Yosys identifies arithmetic and
   multibit sequential coarse units and replaces each type with a preserved
   wrapper. The coarse units are then synthesized and characterized.
2. **Routability-Aware Area Estimation.** A trained area model estimates the
   utilization of each coarse unit. The predicted footprint is used to build
   its abstract physical and timing views. This step is part of
   `coarse_synth` rather than a separate flow stage.
3. **Coarse-Grained Tier Partitioning.** TaiWei performs a 2D pre-placement and
   partitions the coarse-grained netlist between the bottom and upper tiers.
4. **HBT-Aware Per-Tier Synthesis.** The coarse units are expanded using their
   tier implementations, and the two tiers are synthesized with an explicit
   hybrid-bonding-terminal (HBT) RC model.

An additional backend handoff stage converts the 3D-Syn result to the netlist,
partition, and 3D floorplan views consumed by the existing TaiWei backend.

| Flow stage | Paper step | Make target | Primary output |
| --- | --- | --- | --- |
| `coarse_synth` | Coarse-Grained Netlist Construction and Routability-Aware Area Estimation | `cds-coarse-synth` | `1_synth.v`, `1_synth.sdc`, coarse-unit LEF/Liberty and tier netlists |
| `coarse_partition` | Coarse-Grained Tier Partitioning | `cds-coarse-partition` or `ord-coarse-partition` | `2_2_floorplan_io.v/.def/.odb`, `partition.txt` |
| `per_tier_synth` | HBT-Aware Per-Tier Synthesis | `cds-per-tier-synth` | `base.v`, `partition_from_flow.txt` |
| `handoff` | TaiWei backend interface | `cds-3dsyn-handoff` or `ord-3dsyn-handoff` | `<design>_3D.fp.v/.def`, `partition.backend.txt` |

The complete stage sequence is:

```text
cds-coarse-synth
cds-coarse-partition | ord-coarse-partition
cds-per-tier-synth
cds-3dsyn-handoff    | ord-3dsyn-handoff
```

## Repository layout

```text
scripts_3dsyn/
├── run_3d_syn.sh                 End-to-end 3D-Syn driver
├── coarse_synth/
│   ├── run_coarse_synth.sh       Stage driver
│   ├── yosys/                    Coarse-netlist generation
│   ├── genus/                    Coarse-unit and hierarchy synthesis
│   ├── area/                     Area-model inference and checkpoints
│   └── common/                   Shared netlist utilities
├── coarse_partition/
│   ├── run_cds_coarse_partition.sh
│   └── run_ord_coarse_partition.sh
├── per_tier_synth/
│   ├── run_per_tier_synth.sh     Stage driver
│   ├── run_flow.py               Ordered per-tier synthesis driver
│   └── 01_*.py ... 09_*.py       Per-tier transformation steps
└── handoff/
    ├── run_cds_handoff.sh
    ├── run_ord_handoff.sh
    ├── cds/                      Innovus backend adapter
    └── ord/                      OpenROAD backend adapter
```

Intermediate files are written under
`objects/<platform>/<design>/<flow_variant>/3dsyn`. Stable cross-stage results
are written under `results/<platform>/<design>/<flow_variant>`, with logs and
reports in the corresponding `logs` and `reports` directories.

## Build and environment

The 3D-Syn sources are already part of ORFS-Research; no source patch or
standalone Yosys plugin installation is required. Build the TaiWei toolchain in
the usual way, for example:

```bash
cd ORFS-Research
./build_openroad.sh --local --threads <jobs>
```

Before running the flow, make Cadence Genus and the selected physical backend
available in the shell, then initialize TaiWei from the flow root:

```bash
cd TaiWei-Pin-3D
source ./env.sh
```

The current flow supports `asap7_3D`, `nangate45_3D`, and
`asap7_nangate45_3D`. Each design must provide
`designs/<platform>/<design>/config2d.mk` and the platform data referenced by
that configuration.

Designs containing hard macros must provide their 2D physical and timing views
through `ADDITIONAL_LEFS` and `ADDITIONAL_LIBS`. For a heterogeneous platform,
the per-tier macro Liberty views are specified separately:

| Design variable | Purpose |
| --- | --- |
| `ADDITIONAL_LEFS` | Macro LEF used by 2D synthesis, pre-placement, and partitioning. |
| `ADDITIONAL_LIBS` | Base macro Liberty used by 2D synthesis and backend handoff. |
| `SYN3D_BOTTOM_ADDITIONAL_LIBS` | Bottom-tier macro Liberty used by per-tier synthesis. |
| `SYN3D_UPPER_ADDITIONAL_LIBS` | Upper-tier macro Liberty used by per-tier synthesis. |

The two tier-specific variables are required when the upper and bottom macro
masters differ. Hard macros remain black boxes during per-tier synthesis and
are mapped to their final tier masters during backend handoff.

## Running 3D-Syn

Run all four stages for one platform and design:

```bash
./scripts_3dsyn/run_3d_syn.sh <platform_3d> <design> [flow_variant]
```

For example:

```bash
./scripts_3dsyn/run_3d_syn.sh asap7_3D gcd release_test
```

If omitted, `flow_variant` defaults to `3dsyn`. A flow variant identifies one
run and must be reused when stages are invoked separately.

The default backend is Cadence/Innovus. Select OpenROAD with:

```bash
SYN3D_BACKEND=ord \
./scripts_3dsyn/run_3d_syn.sh asap7_3D gcd release_test_ord
```

### Configuration

Configuration is passed through environment variables before invoking the
driver.

| Variable | Default | Description |
| --- | --- | --- |
| `NUM_CORES` | `16` | Maximum parallel worker count used by the flow. |
| `SYN3D_BACKEND` | `cds` | Physical backend used by coarse partition and handoff: `cds` or `ord`. |
| `SYN3D_COARSE_UNIT_KEEP_MODE` | `all` | Coarse-unit categories to preserve: `all`, `arithmetic`, `multibit_ff`, or `none`. |
| `SYN3D_FIXED_UTIL` | unset | Optional fixed coarse-unit utilization in `(0, 1]`; when unset, the area model predicts utilization. |
| `SYN3D_HBT_MODEL_MODE` | `scale` | HBT model mode: `scale` or `direct`. |
| `SYN3D_HBT_R_SCALE` | `0` | Producer-tier drive-resistance scale in `scale` mode. |
| `SYN3D_HBT_C_SCALE` | `0.25` | Consumer-tier input-capacitance scale in `scale` mode. |
| `SYN3D_HBT_R_OHM` | unset | HBT resistance in ohms; required in `direct` mode. |
| `SYN3D_HBT_C_FF` | unset | HBT capacitance in femtofarads; required in `direct` mode. |
| `SYN3D_BACKEND_PREPLACE_OPT` | `0` | Use `0` to preserve the per-tier instance set during backend pre-placement; use `1` to enable pre-placement optimization and partition updating. |

`SYN3D_BACKEND_PREPLACE_OPT` has the same meaning for both backends. Innovus
uses `place_design -noPrePlaceOpt` when it is `0`. OpenROAD retains the complete
floorplan, IO placement, and global placement flow but skips commands that can
change the instance/master set. A value of `1` runs the native complete
pre-placement flow and updates the backend partition when necessary.

Example using direct HBT values:

```bash
SYN3D_HBT_MODEL_MODE=direct \
SYN3D_HBT_R_OHM=2.0 \
SYN3D_HBT_C_FF=0.5 \
./scripts_3dsyn/run_3d_syn.sh asap7_3D gcd direct_rc
```

## Running individual stages

Initialize the TaiWei environment, choose one coarse-partition target and the
matching handoff target, then run the stages in order. Every frontend target
uses the same 2D design configuration and flow variant.

Cadence/Innovus path:

```bash
source ./env.sh

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-coarse-synth

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-coarse-partition

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-per-tier-synth

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-3dsyn-handoff
```

OpenROAD path (the synthesis stages remain Genus-based):

```bash
export USE_FLOW=openroad

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-coarse-synth

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test ord-coarse-partition

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test cds-per-tier-synth

make DESIGN_CONFIG=designs/asap7_3D/gcd/config2d.mk \
     FLOW_VARIANT=stage_test ord-3dsyn-handoff

make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk \
     FLOW_VARIANT=stage_test ord-3d-floorplan
```

Each target validates the stable outputs required from the preceding stage and
stops on an incomplete handoff. The coarse-partition files keep their standard
TaiWei names. Backend pre-placement uses private `*.backend.*` names, so it
does not overwrite the coarse-stage netlist, floorplan, or partition. Both
handoff targets publish `<design>_3D.fp.v` and `<design>_3D.fp.def`; these are
consumed directly by `cds-3d-floorplan` or `ord-3d-floorplan`.

## Tests

Run the per-tier unit tests, including scalar, single-bit-vector, and bus
interface cases, with:

```bash
python3 -m unittest discover -s scripts_3dsyn/per_tier_synth/tests -v
```

After making Genus available in the environment, its interface round-trip can
be checked separately:

```bash
python3 scripts_3dsyn/per_tier_synth/tests/run_genus_port_interface_test.py
```

## Batch execution

`batch_experiments/run_3d_syn_batch.sh` can distribute design-platform cases to
remote nodes through `nohup` queues. It supports `plan`, `launch`, and `status`
actions, and can select either the original TaiWei 2D synthesis frontend or
3D-Syn:

```bash
SYN3D_BATCH_ACTION=plan \
SYN3D_BATCH_SYNTH_MODE=3d \
SYN3D_BATCH_BACKEND=ord \
SYN3D_BATCH_CASES="asap7_3D/gcd nangate45_3D/gcd" \
./batch_experiments/run_3d_syn_batch.sh
```

Set `SYN3D_BATCH_STOP_AFTER=synthesis` to stop after the selected synthesis
frontend, `SYN3D_BATCH_STOP_AFTER=floorplan` to additionally run the selected
3D-Syn backend's 3D floorplan, or `SYN3D_BATCH_STOP_AFTER=full` to continue
through the existing TaiWei backend. The `floorplan` boundary applies to 3D-Syn
mode only. Batch manifests, logs, and status files are stored in
`batch_experiments/runs/<run_tag>`.
