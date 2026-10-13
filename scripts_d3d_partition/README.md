# Differentiable 3D partition stage

This directory connects the standalone CPU-only D3D Partitioner to TaiWei's
tier-partition handoff. It does not replace or modify TritonPart.

Use the explicit target:

```bash
make DESIGN_CONFIG=designs/asap7_3D/aes/config2d.mk \
     FLOW_VARIANT=d3d_partition_test \
     ord-tier-partition-d3d
```

The D3D stage consumes the ordinary 2D placement database, so it uses
`config2d.mk` and the base technology LEFs/tie-cell definitions.  As a 3D
frontend stage, its logs, objects, reports, and results are automatically
stored under the corresponding `<technology>_3D` experiment directory; users
do not need to set a separate work-platform option.

The original `ord-tier-partition` continues to run TritonPart. Neither target
falls back to the other.

The D3D stage reads the current variant's `2_2_floorplan_io.def`,
`2_2_floorplan_io.v`, and `2_floorplan.sdc`, together with the LEFs selected
by the current platform. Algorithm parameters and design-specific
D2D/DREAMPlace bin grids are loaded from:

```text
scripts_d3d_partition/config/openroad/<platform>/<design>.yaml
```

With `config2d.mk`, `PLATFORM=<technology>` selects the 2D inputs and
`3D_PLATFORM=<technology>_3D` selects the experiment directory.  The default
D3D config platform is therefore `<technology>`. Paths and the CPU device
setting are injected by the driver; they are not stored in the YAML.

The optional top-level `d2d` mapping overrides the four synchronized
`num_bins_x`/`num_bins_y` values in the generated runtime JSON. All four values
must be present, positive integers, and identical. A YAML without `d2d` uses
the shared CPU defaults.

Private runtime data is written below
`objects/<technology>_3D/<design>/<variant>/d3d_partition/run.*`. After checking
the complete DEF instance set and binary tier labels, the stage publishes:

```text
results/<technology>_3D/<design>/<variant>/partition.txt
reports/<technology>_3D/<design>/<variant>/d3d_partition_summary.json
logs/<technology>_3D/<design>/<variant>/2_d3d_partition.log
```

`partition.txt` is published last and uses the existing TaiWei convention:
tier `0` is upper and tier `1` is bottom. A failed run does not publish a new
handoff.

The default D3D environment and install paths are derived from the adjacent
ORFS-Research checkout. They can be overridden with
`D3D_PARTITION_ENV_PREFIX` and `D3D_PARTITION_PREFIX`. Use
`D3D_PARTITION_CONFIG` only when intentionally selecting another YAML.

`ord-check-tier-partition-d3d` validates the installed CPU environment without
changing design results. Installation remains an independent operation under
`ORFS-Research/tools/D3D-Partitioner/d3d-partition-driver`.
