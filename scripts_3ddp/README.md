# True-3D Detailed Placement Stage

This directory connects OpenROAD's timing-driven 3D detailed placement (TDP)
module to the TaiWei placement handoff.  It is an explicit plugin stage and
does not replace or modify the original upper- and bottom-tier legalization
targets.

## Flow position

```text
ord-gp2lg
  <design>_3D.lg.def / <design>_3D.lg.v / 2_floorplan.sdc
                              |
                              v
                  ord-detail-place-3d
                              |
             +----------------+----------------+
             |                                 |
   upper/bottom timing repair       fresh OpenROAD process
   private pre_repair.def           HBT generation and TDP
                                               |
                                               v
                         3_place.def / 3_place.v / 3_place.sdc
                                               |
                                               v
                             ord-cts or ord-cts-3d
```

The repair and TDP phases intentionally use separate OpenROAD processes.  The
second process reloads `pre_repair.def`, so tier-specific repair masks and
timing state cannot leak into the global 3D optimization.

## Running the stage

Build and install an OpenROAD binary containing `src/3ddp`, then initialize
the TaiWei environment and run:

```bash
cd TaiWei-Integration/TaiWei-Pin-3D
source env.sh

make DESIGN_CONFIG=designs/asap7_3D/gcd/config.mk \
     FLOW_VARIANT=3ddp_test \
     ord-detail-place-3d
```

The selected variant must already contain the `ord-gp2lg` outputs.  After a
successful run, continue with either the original CTS stages or 3DCTS using
the same configuration and variant.

`ord-detail-place-3d` is not selected by an implementation variable and is not
inserted into the existing complete flow.  The original
`ord-legalize-upper` and `ord-legalize-bottom` commands remain unchanged.

## Inputs and outputs

The public input contract is:

```text
results/<platform>/<design>/<variant>/<design>_3D.lg.def
results/<platform>/<design>/<variant>/<design>_3D.lg.v
results/<platform>/<design>/<variant>/2_floorplan.sdc
```

The DEF and SDC are loaded by OpenROAD.  The Verilog handoff is checked for
presence as part of the complete upstream contract.  The stage publishes only
the standard placement outputs:

```text
results/<platform>/<design>/<variant>/3_place.def
results/<platform>/<design>/<variant>/3_place.v
results/<platform>/<design>/<variant>/3_place.sdc
```

Private state is isolated below:

```text
objects/<platform>/<design>/<variant>/3ddp/
├── pre_repair.def
└── hbt_array.json
```

Old public outputs are removed before repair starts.  New `3_place.*` files
are written only after TDP and its structural checks complete, preventing a
failed run from leaving a stale handoff for CTS.

## HBT guidance

`generate_hbt_array.py` derives the candidate array from the repaired DEF's
die area and DBU scale, the active technology LEF's `hb_layer` width and
resistance, and `CORE_MARGIN` from the selected design configuration.  The
default experimental edge-to-edge spacing remains `0.6 um`, matching the
source implementation.

The generated JSON guides TDP's inter-tier timing and allocation model.  It is
not a physical HBT database handoff and is not consumed by CTS or routing.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `DP_3D_MAX_DISPLACEMENT` | Maximum X/Y displacement in microns | `DPO_MAX_DISPLACEMENT` |
| `DP_3D_MARGIN` | Placement margin in microns | `CORE_MARGIN` |
| `HBT_MAX_CORE_UTILIZATION` | Maximum allowed candidate HBT utilization | `0.8` |

Supported technology pairings are `asap7_3D`, `nangate45_3D`,
`asap7_nangate45_3D`, and `nangate45_asap7_3D`.  Repository paths are derived
from TaiWei environment variables and the script location; no developer
workspace path is embedded in this adapter.

## Files

- `detail_place_3d_repair_stage.tcl` creates the private repaired DEF.
- `detail_place_3d_repair.tcl` preserves the source upper/bottom repair logic.
- `detail_place_3d.tcl` generates HBT guidance, runs TDP, checks the result,
  and publishes the standard handoff.
- `detail_place_3d_config.tcl` resolves platform settings and the private
  stage-path contract.
- `detail_place_3d_checks.tcl` checks inputs, outputs, instance counts, tier
  counts, and protected-instance locations.
- `detail_place_3d_post.tcl` refreshes parasitics and records cross-tier
  transition diagnostics without running another placement algorithm.
- `generate_hbt_array.py` creates the per-run HBT guidance model.

The OpenROAD implementation and Tcl command are documented in
`ORFS-Research/tools/OpenROAD/src/3ddp/README.md`.
