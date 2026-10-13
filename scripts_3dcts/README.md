# Shared-Tap Useful-Skew Clock Tree Synthesis for Face-to-Face 3D ICs

This directory contains the TaiWei flow driver for useful-skew clock tree
synthesis (3DCTS) on face-to-face (F2F) 3D ICs with hybrid bonding. The stage
runs after 3D placement, builds and refines a clock tree whose buffers may
reside on both tiers, and publishes the standard TaiWei CTS handoff for routing.

## Overview

Useful-skew CTS assigns a target clock arrival time to each sequential element.
Those targets must then be realized by a physical clock tree made of discrete
buffer stages and shared clock paths. In an F2F design, the latency available to
a sink also depends on its tier, the tier-specific buffer library, its clock
branch, and any hybrid-bonding terminal (HBT) crossing.

3DCTS addresses the difference between scheduled and physically delivered
clock arrival—the **realizability gap**—with a 3D H-tree and shared tap
delivery. Sinks on the same branch and tier share a cascaded buffer chain while
selecting individual tap depths. A group on the tier opposite its branch driver
is reached through a single HBT crossing.

The method has four main phases:

1. **Balanced 3D tree and propagated-clock analysis.** A balanced tree is
   constructed on the placed design. Propagated-clock STA provides base clock
   arrivals, register-to-register slacks, and I/O timing edges.
2. **Useful-skew scheduling.** An OR-Tools GLOP linear program computes bounded
   per-sink arrival targets. The default formulation first optimizes endpoint
   WNS and then minimizes endpoint TNS under a WNS guard.
3. **Shared tap delivery.** A 3D H-tree delivers the schedule through cascaded
   tap chains shared by branch and tier. Each sink retains its own tap depth,
   and remote groups share an HBT entry.
4. **Physical refinement.** Post-CTS timing guides tap reassignment and clock
   buffer sizing. Candidate edits are accepted only when the configured setup
   and hold guards are satisfied.

The stage also performs clock-net repair, clock-cell legalization, optional hold
repair, and timing/debug extraction before publishing its outputs.

## Position in the TaiWei flow

```text
3D placement
  3_place.def / 3_place.v / 3_place.sdc
                         |
                         v
                    ord-cts-3d
                         |
                         +-- balanced reference and timing graph
                         +-- useful-skew LP
                         +-- 3D H-tree and shared tap delivery
                         +-- refinement and buffer sizing
                         |
                         v
CTS handoff
  4_cts.def / 4_cts.v / 4_cts.sdc / 4_cts.odb
                         |
                         v
                     ord-route
```

`ord-cts-3d` is an explicit stage target. It does not run placement and is not
selected automatically by another CTS target.

## Running 3DCTS

Build OpenROAD with the `3dcts` module, then initialize the TaiWei environment:

```bash
cd TaiWei-Integration/TaiWei-Pin-3D
source env.sh
```

The selected design, platform, and `FLOW_VARIANT` must already contain the
placement handoff:

```text
results/<platform>/<design>/<variant>/3_place.def
results/<platform>/<design>/<variant>/3_place.v
results/<platform>/<design>/<variant>/3_place.sdc
```

Run the stage with the TaiWei Make target:

```bash
make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk \
     FLOW_VARIANT=3dcts_test \
     ord-cts-3d
```

The wrapper script provides the same entry point:

```bash
./scripts_3dcts/run_3dcts.sh \
  designs/asap7_3D/gcd/config.mk \
  3dcts_test
```

After a successful run, continue with routing using the same configuration and
variant:

```bash
make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk \
     FLOW_VARIANT=3dcts_test \
     ord-route
```

The platform adapter currently provides tier-buffer mappings for:

- `asap7_3D`
- `nangate45_3D`
- `asap7_nangate45_3D`

For another platform, provide `CTS_BUF_CELL`, `CTS_BUF_BOTTOM`, and
`CTS_BUF_UPPER` with masters present in the loaded LEF view.

## Outputs

Successful execution writes the routing handoff to:

```text
results/<platform>/<design>/<variant>/4_cts.def
results/<platform>/<design>/<variant>/4_cts.v
results/<platform>/<design>/<variant>/4_cts.sdc
results/<platform>/<design>/<variant>/4_cts.odb
```

The principal reports are:

```text
logs/<platform>/<design>/<variant>/4_cts_3d.log
reports/<platform>/<design>/<variant>/4_cts_timing.rpt
reports/<platform>/<design>/<variant>/4_cts_cross_tier.rpt
```

Timing graphs, LP solutions, tap-refinement data, sizing decisions, and debug
CSVs are kept separately under:

```text
objects/<platform>/<design>/<variant>/3dcts/
```

## Configuration

Default flow parameters are defined in `cts_params.env`. Values written with a
shell default expression can be overridden before invoking Make, for example:

```bash
CTS_REUSE_TIMING_GRAPH=0 \
PRE_CTS_MAX_SKEW=0.080 \
make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk \
     FLOW_VARIANT=3dcts_fresh_graph \
     ord-cts-3d
```

Frequently used controls are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `ENABLE_PROPAGATED_CTS` | `1` | Build the balanced reference and extract propagated-clock timing. |
| `CTS_REUSE_TIMING_GRAPH` | `1` | Reuse complete Phase-1 CSVs already present in the work directory. |
| `PRE_CTS_MAX_SKEW` | `0.100` | Bound scheduled clock-arrival displacement, in ns. |
| `CTS_ENABLE_UNIFIED_TREE` | `1` | Build one H-tree over sinks on both tiers. |
| `CTS_ENABLE_PER_TIER_CTS` | `0` | Build independent tier trees when explicitly enabled. |
| `CTS_SHARED_TAP` | `1` | Share cascaded tap chains within each branch/tier group. |
| `CTS_BRIDGE_PROTOTYPE` | `1` | Use a dedicated cross-tier bridge entry for remote delivery groups. |
| `CTS_ENABLE_CTR` | `1` | Run timing-guarded tap reassignment and downsizing. |
| `ENABLE_BUFFER_SIZING` | `1` | Run Liberty-aware clock-buffer sizing. |
| `BUFFER_SIZING_ITERATIVE` | `1` | Apply sizing iteratively with STA acceptance guards. |
| `CTS_ENABLE_DEBUG_EXTRACT` | `1` | Generate per-sink, per-edge, and clock-tree debug CSVs. |
| `CTS_NO_INSERTION_DELAY` | `0` | Ignore sink insertion delay during tree construction when enabled. |
| `HETEROGENEOUS_3D` | platform-derived | Select heterogeneous tier behavior and buffer libraries. |

The remaining scheduler, delivery, refinement, and extraction controls are
documented next to their defaults in `cts_params.env`.

## Script guide

| File | Purpose |
| --- | --- |
| `cts_3d.tcl` | Top-level stage orchestration, refinement, reporting, and handoff publication. |
| `phase1_extract.tcl` | Balanced-tree construction and propagated-clock timing extraction in a child OpenROAD process. |
| `cts_params.env` | Shared scheduler, delivery, refinement, and extraction parameters. |
| `platform_config.tcl` | Tier-buffer selection and validation against the loaded LEF masters. |
| `policy_engine.tcl` | Optional design-structure measurement and policy selection. |
| `buffer_sizing.tcl` | Timing-edge and library-delay helpers for buffer sizing. |
| `buffer_sizing_iterative.tcl` | Iterative LP-based sizing with STA acceptance checks. |
| `debug_extract.tcl` | Per-sink, per-edge, topology, buffer, and summary CSV extraction. |
| `buffer_insertion.tcl` | Experimental relay-buffer insertion; disabled by default. |
| `clock_layer_assignment.tcl` | Experimental clock-layer assignment; disabled by default. |
| `run_3dcts.sh` | Command-line wrapper for the `ord-cts-3d` Make target. |

## Method to code

The OpenROAD implementation is under
`ORFS-Research/tools/OpenROAD/src/3dcts`. The following entry points are useful
when reading the method:

| Functionality | Entry point | File |
| --- | --- | --- |
| 3D H-tree construction | `HTreeBuilder::preSinkClustering()` and `HTreeBuilder::createClockSubNets()` | `src/HTreeBuilder.cpp` |
| Tier and skew-target data | `Cts3DDatabase` | `src/Cts3DDatabase.cpp` |
| Useful-skew scheduling | `CtsSkewLpSolver::solveTns()` | `src/CtsSkewLpSolver.cpp` |
| Timing graph extraction | `TritonCTS::extractFFGraphFromODB()` | `src/TritonCTS.cpp` |
| Delivery-bound estimation | `ClockLatencyEstimator::estimateAndWrite()` | `src/ClockLatencyEstimator.cpp` |
| Buffer-sizing optimization | `BufSizingLpSolver::solve()` | `src/BufSizingLpSolver.cpp` |
| Tap refinement | `TritonCTS::runCtrRefinement()` | `src/TritonCTS.cpp` |
| Tcl commands and C++ bindings | `clock_tree_synthesis_3d` and the `dcts::` commands | `src/TritonCTS.tcl`, `src/TritonCTS.i` |

For direct OpenROAD command documentation and a complete source map, see the
`src/3dcts/README.md` in the OpenROAD tree.
