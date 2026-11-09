# Known Issues

## Cadence Macro Cases Can Crash With OpenROAD-Style Additional Layers

### Summary

In Cadence 3D flow, macro-containing designs can crash during `cds-place-upper`
when the technology/view stack includes the OpenROAD-style additional routing
layers such as `M2_add` / `M3_add`.

The current evidence points to an Innovus internal optimizer failure triggered
by the combination of:

- macro-containing designs
- `place_opt_design`-based upper placement
- OpenROAD-style additional-layer setup in the Cadence flow

This is currently treated as a flow compatibility issue, not a normal design
violation.

### Affected Scope

- Cadence flow
- macro-containing cases such as `swerv_wrapper`
- especially `nangate45_3D` mixed-view runs like `cds_ordtech`
- stage:
  - `cds-place-upper`

### Typical Symptoms

- repeated internal asserts in Innovus:
  - `coeTransform.hpp:2625:getTopoLaCount`
- final internal crash:
  - `Innovus terminated by internal (SEGV) error/signal`
- trailing worker-thread stacks stuck in `pthread_cond_wait`
  - this is a post-crash symptom, not the root cause

### Evidence

Relevant logs:

- [3_place_upper.upper-only.log](logs/nangate45_3D/swerv_wrapper/cds_ordtech/3_place_upper.upper-only.log)
- [3_place_upper.upper-only.log](logs/nangate45_3D/swerv_wrapper/cds_ordtech_nosplit/3_place_upper.upper-only.log)

Common indicators seen in both split and no-split runs:

- additional-layer routing setup is active:
  - `setDesignMode -topRoutingLayer M3_add`
- additional-layer pitch warnings appear:
  - generated pitch mismatch on `M2_add`
- extra tech inconsistency warning appears:
  - `IMPRM-132 Missing VIARULE GENERATE definition between M19/M20`
- later, the optimizer crashes in the same internal topo path:
  - `getTopoLaCount`
  - `coeSetupOptimizer`
  - `rdaOptDesignCL::run`

The same signature appears in both:

- `cds_ordtech`
- `cds_ordtech_nosplit`

So this issue is not currently attributed only to split-buffer insertion.

### Current Interpretation

The current working interpretation is:

- pure `split_net` is not the primary root cause
- the main trigger is the Cadence upper placement optimization flow running on
  a macro-containing design under the OpenROAD-style additional-layer setup
- this likely exposes an Innovus internal bug or unsupported flow combination

### Current Workaround

Until this is fully fixed, avoid using the OpenROAD-style additional-layer
setup for Cadence macro cases in `place-upper`, or reduce the stage to a safer
placement mode.

Practical mitigations:

- avoid the additional-layer tech/view mix for macro cases
- avoid `place_opt_design` on the affected macro cases when possible
- prefer a simpler `place_design`-style upper placement for debug

### Notes

- This issue has only been clearly reproduced on macro-containing Cadence
  cases so far.
- Non-macro cases may still run with the same additional-layer setup.
- If this issue is revisited later, compare against:
  - macro-free Cadence cases
  - the same macro case without additional layers
  - the same macro case with reduced placement optimization effort

## Cadence Legacy Route Can Create Large DRC Regressions After `routeDesign`

### Summary

In the Cadence legacy route flow, applying:

- `apply_tier_policy [cts_owner_tier] -fixlib 1 -allow_net $effective_allow_net`

after `routeDesign`, and then running:

- `optDesign -postRoute -outDir $REPORTS_DIR -prefix route_legacy`

can introduce a large DRC regression.

This is currently treated as a flow issue in the legacy route sequence, not as
a normal expectation of the route stage.

### Affected Scope

- Cadence flow
- legacy single-stage route:
  - `cds-route`
- script:
  - [innovus_3d_route_legacy.tcl](scripts_cadence/innovus_3d_route_legacy.tcl)

### Symptom

The route stage completes, but final DRC is much worse than the pure route
stage expectation.

Observed example:

- [final_summary.txt](logs/asap7_3D/swerv_wrapper/cadence_route_legacy_cmp/final_summary.txt)
  - `DRC Violations = 50466`

The corresponding route log shows that the legacy flow explicitly runs
owner-tier postRoute optimization after `routeDesign`:

- [5_route.log](logs/asap7_3D/swerv_wrapper/cadence_route_legacy_cmp/5_route.log)
  - `Running optDesign -postRoute ...`

### Current Interpretation

The suspected mechanism is:

- `routeDesign` finishes on one routed topology
- `apply_tier_policy` is then re-applied after route
- this changes optimization legality / allowed cell usage / row policy late in
  the flow
- `optDesign -postRoute` then perturbs the routed design under a different
  policy than the one used during the actual route stage

This late policy switch is currently considered unsafe for DRC stability.

### Current Workaround

Prefer either:

- pure route-only flow for cleaner routing behavior
- or staged postRoute flow with explicit receive/owner separation

Avoid using the legacy postRoute step as the baseline for DRC-sensitive
comparison until this interaction is better controlled.

## Split-Buffer Tier Selection Can Overload the Expensive Tier in Heterogeneous Designs

### Summary

The old split-net tier selection policy was too narrow for heterogeneous
upper/bottom technology stacks:

- Cadence previously selected the split-buffer tier mainly by heavier fanout.
- OpenROAD previously selected the split-buffer tier mainly by opposite-of-driver
  placement.

Both policies can be wrong in heterogeneous designs. Heavy-fanout-only can push
many buffers into the physically more expensive or already highly utilized tier,
for example the 45nm side in an ASAP7/Nangate45 stack. Opposite-of-driver-only is
more stable, but it ignores utilization stress and can still insert buffers into
a tier that has little area margin.

### Current Fix

Both Cadence and OpenROAD split-net implementations now use the same lightweight
cost function:

```text
score(t) = w_util * util_penalty(t) + w_hbt * hbt_penalty(t) + w_area * buffer_area_penalty(t)
```

Defaults:

- `u_safe = 0.60`
- `alpha = 12.0`
- `w_util = 1.0`
- `w_hbt = 2.5`
- `w_area = 400.0`
- high-util forbid threshold = `0.80`
- near-tie threshold = `5%`

The utilization term is a single-threshold exponential penalty, so utilization
above `0.60` is penalized nonlinearly and `0.80+` becomes much more expensive
than a linear fanout-only rule would imply.

The HBT term uses a proxy named `estimated_extra_hbt`:

- if `buffer_tier != driver_tier`, `estimated_extra_hbt = 1`
- if `buffer_tier == driver_tier`, `estimated_extra_hbt = retained_opposite_tier_sink_count`

This value is only a split-decision cost proxy. It is not the actual routed HBT
count and should not be used as a final physical HBT metric.

The area term uses the chosen split buffer master area normalized by the current
core area:

- `buffer_area_penalty = chosen_buffer_area / core_area`

This intentionally makes the area term more visible on very small designs,
where a few added buffers can perturb density much more strongly than on large
designs.

### Remaining Limitations

- Tier utilization is global and approximate; it is computed once per split run
  from tier-classified instance/master area divided by core area.
- The new area term is still lightweight; it does not predict final routed
  congestion or final routed HBT count. It only scores the inserted split
  buffer area against the current core area.
- The policy intentionally does not use local bin congestion, routing demand, or
  routed HBT estimates.
- Buffer master selection and split verification remain governed by the existing
  flow rules.
- This improves split-buffer tier selection quality, but it does not claim to
  predict final routed HBT count or final DRC behavior.

## OpenROAD ariane133 Has CTS and Pin-Access Blockers

Historical note: `ariane133` has been removed from the `pesudo-3d` case
collection. The observations below describe earlier runs and are retained
for reference; they are not part of this branch's current regression set.

### Summary

The OpenROAD 3D flow currently has unresolved `ariane133` blockers that should
be tracked separately from the Cadence issues:

- `nangate45_3D/ariane133` fails in `ord-cts`
- `asap7_nangate45_3D/ariane133` fails in `ord-cts`
- `asap7_3D/ariane133` can reach route but fails during GRT / detailed-router
  pin access

These are treated as known OpenROAD flow blockers for the SRAM/macro-heavy
`ariane133` design.

### Affected Scope

- OpenROAD flow
- `ariane133`
- technologies:
  - `nangate45_3D`
  - `asap7_nangate45_3D`
  - `asap7_3D`

### Observed CTS Failure

The 45nm and heterogeneous ariane133 OpenROAD runs fail at `ord-cts`.

Observed logs:

- [nangate45_3D ariane133 run log](run_logs/nangate45_3D/ord/run/ariane133_run.log)
  - `make: *** [Makefile:447: ord-cts] Error 11`
  - `clk_i_regs` has about `19940` register sinks
  - CTS creates about `3562` clock buffers / clock nets before failing
- [asap7_nangate45_3D ariane133 run log](run_logs/asap7_nangate45_3D/ord/run/ariane133_run.log)
  - `make: *** [Makefile:447: ord-cts] Error 11`
  - `clk_i_regs` has about `19851` register sinks
  - CTS creates about `5122` clock buffers / clock nets before failing

Current interpretation:

- this is likely a CTS robustness / scaling / placement-legality issue in the
  OpenROAD 3D flow for ariane133
- it should not be diagnosed as a split-net-only issue without additional
  evidence
- the 45nm and mixed-tech cases should not be used as valid final OpenROAD
  ariane133 results until this CTS blocker is fixed

### Observed GRT / Pin-Access Failure

The 7nm ariane133 OpenROAD run can fail later during global route / detailed
router pin access.

Observed log:

- [asap7_3D ariane133 GRT log](logs/asap7_3D/ariane133/openroad/5_1_grt.log)
  - `DRT-0073 No access point`
  - failures are reported on SRAM pins such as `rd_out[15]`
  - affected SRAM views include `sram_asap7_16x256_1rw_upper` and corresponding
    bottom-tier views
  - the stage exits at `Error: global_route.tcl, 103 DRT-0073`

Current interpretation:

- this points to a macro/SRAM LEF pin-access or route-access geometry issue for
  the ASAP7 ariane133 macro views
- it is not expected to be solved by changing only the high-level global route
  command
- the next debug target should be the SRAM macro pin shape / access-layer setup
  in the 7nm upper and bottom LEF views

### Current Status

These OpenROAD ariane133 results should be treated as blocked:

- `nangate45_3D/ariane133`: CTS blocker
- `asap7_nangate45_3D/ariane133`: CTS blocker
- `asap7_3D/ariane133`: GRT / DRT pin-access blocker

Recommended next steps:

- isolate CTS behavior on the 45nm and heterogeneous ariane133 runs
- inspect SRAM macro pin-access geometry for the 7nm ariane133 run
- keep these failures separate from Cadence placement/route issues and from the
  split-net cost-model tuning work
