# Placement-informed IO feedback (experimental)

Set `PIN3D_IO_FEEDBACK=1` consistently for both the 2D `ord-io` /
`ord-tier-partition` stages and the later 3D flow. The default is disabled.

The enabled 2D flow runs the existing initial IO assignment and coarse global
placement, then repeats IO assignment using actual placed instance locations,
runs one incremental global placement, and updates placement parasitics. It
writes `RESULTS_DIR/io_feedback_assignment.list`, containing each signal port's
boundary side and normalized coordinate along that side. The partition entrypoint rebuilds placement parasitics in its own OpenROAD
process; `PIN3D_PARTITION_ESTIMATE_RC=1` provides the same estimation for a
control with feedback disabled. The partition target
already copies the results directory to the 3D platform directory, including
this handoff file.

The enabled 3D IO stage requires that handoff and the matching partition file.
It retains the boundary side and along-edge order, scales coordinates to the
new die dimensions, and maps each port to its partition-assigned tier's metal
layers. Slots use two routing pitches and a two-pitch corner margin. A
monotone, deterministic slot assignment resolves collisions introduced by die
shrinking, followed by `place_pin -force_to_die_boundary` track snapping.
Missing/duplicate ports, malformed records, insufficient edge capacity, or
post-snap spacing violations fail instead of falling back to the old placer.
`io_feedback_mapping.rpt` records intended and actual positions;
`io_pin_tiers.rpt` checks the assigned layers against the partition.

This first experiment uses geometry and connectivity, without a new slack or
cross-tier weighting objective. The incremental placement is not legalization;
normal downstream per-tier legalization and routing remain required. The XY
coordinates are mapped, not copied literally, because 2D and 3D dies differ.
This path is implemented for the OpenROAD `ord-io` → `ord-pre` →
`ord-3d-floorplan` → `ord-3d-io` pipeline; it does not change Cadence IO placement
or legacy PDN entrypoints that separately invoke `io_place.tcl`.

With the flag disabled, the original IO/placement operations are retained and
any stale feedback handoff in the 2D results directory is removed.

Checks without an EDA license:

```sh
python3 tests/unit/test_io_feedback.py
```

Use separate variants and identical input checkpoints, clock/IO constraints,
threads, routing settings, and RC policy for the control and enabled arms.
Final timing, hold, electrical checks, DRC, tier consistency, area and power
must be compared before enabling the feature by default.
