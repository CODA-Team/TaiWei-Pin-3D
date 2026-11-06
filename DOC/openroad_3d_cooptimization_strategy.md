# OpenROAD 3D Co-Optimization Strategy

> On `native-3d`, the default launcher uses 3D-Syn, TDP detailed placement
> and 3DCTS. See [the current launcher guide](../test/README.md) for the
> default sequence and resume targets. The staged legalization/CTS sections
> below document the retained baseline targets and shared tier-policy
> mechanisms; those baseline stages are not the default native pipeline.

## Scope

This document describes the current OpenROAD 3D commercial-style flow implemented in this repository. It is intentionally code-aligned:

- public flow targets come from [Makefile](Makefile)
- stage handoff contracts come from [handoff_manager.tcl](scripts_openroad/handoff_manager.tcl)
- tier and allow-net policy come from [placement_utils.tcl](scripts_openroad/placement_utils.tcl) and [placement_tier_metrics_policy.tcl](scripts_openroad/placement_tier_metrics_policy.tcl)
- launchers come from [test/openroad/ORD_3D_NEW_FLOW.sh](test/openroad/ORD_3D_NEW_FLOW.sh) and [test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh](test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh)

The goal is to make the OpenROAD flow structurally parallel to the Cadence flow:

- explicit stage-by-stage handoff management
- explicit split-net stage
- explicit allow-net / dont-touch-net tier policy
- staged preCTS optimization
- split summary and final summary generation

This strategy document is intentionally implementation-oriented, but it should stay free of run-specific output-directory paths or ad hoc experiment links. Reproducible entry points live under [test/README.md](test/README.md). For adding new OpenROAD Research commands as real staged flow steps, see [openroad_developer_guide.md](DOC/openroad_developer_guide.md).

## Public Flow Entry

The OpenROAD launcher is:

- [ORD_3D_NEW_FLOW.sh](test/openroad/ORD_3D_NEW_FLOW.sh)

It accepts:

- `enablement`
- `flow_variant`
- `use_flow=openroad`
- `design_nickname`

Important environment switches:

- `PIN3D_ALLOW_NET_FLOW=on|off`
- `PIN3D_SPLIT_NET_FLOW=on|off`
- `TIER_ALLOW_NET=upper-only|bottom-only|all`
- `REUSE_2DPART_FROM_VARIANT=<variant>`
- `START_FROM=<stage>`
- `OUTER_ITERATIONS=<N>`

The default 3D stage order is:

```text
ord-pre
ord-3d-floorplan
ord-3d-io
ord-3d-split-net
ord-place-macro-upper
ord-place-macro-bottom
ord-3d-pdn-only
  -> ord-3d-pdn-only-bottom
  -> ord-3d-pdn-only-upper
ord-place-init
ord-place-init-upper
ord-place-init-bottom
OUTER_ITERATIONS times:
  ord-place-upper
  ord-place-bottom
ord-gp2lg
ord-legalize-upper
ord-legalize-bottom
ord-cts
ord-cts-post
ord-route
ord-final
```

`ord-3d-flow-2dpart` remains the 2D bootstrap wrapper:

- `ord-synth`
- `ord-preplace`
- `ord-tier-partition`

## Script Structure

Several heavy Tcl files have been split into lighter entry files plus sourced helper implementations. The public stage targets are unchanged; only internal file organization changed.

Current split pairs:

- [placement_utils.tcl](scripts_openroad/placement_utils.tcl) -> [placement_tier_metrics_policy.tcl](scripts_openroad/placement_tier_metrics_policy.tcl)
- [split_net.tcl](scripts_openroad/split_net.tcl) -> [split_net_impl.tcl](scripts_openroad/split_net_impl.tcl)
- [io_place.tcl](scripts_openroad/io_place.tcl) -> [io_place_helpers.tcl](scripts_openroad/io_place_helpers.tcl)
- [tier_partition.tcl](scripts_openroad/tier_partition.tcl) -> [tier_partition_helpers.tcl](scripts_openroad/tier_partition_helpers.tcl)

Each entry file remains the canonical stage-facing interface. The helper file is sourced only if the needed proc set has not already been loaded.

Recent `gcd` smoke checks validated the helper split/source chain:

- `placement_utils -> placement_tier_metrics_policy`
- `split_net -> split_net_impl`
- `io_place -> io_place_helpers`
- `tier_partition -> tier_partition_helpers`

Those checks were only used to confirm that the split helper structure still loads and reaches the expected OpenROAD stages. The strategy document intentionally does not embed run-specific log or report paths.

## Handoff Management

OpenROAD stage handoffs are centralized in:

- [handoff_manager.tcl](scripts_openroad/handoff_manager.tcl)

Each rebuilt stage follows the same front-matter structure:

1. `# Core setup`
2. `# Environment directories`
3. `# Stage handoff`
4. `# Additional setup`

Each rebuilt stage:

- resolves input/output files with `handoff_stage_paths`
- binds canonical stage variables with `handoff_bind_stage_io`
- logs the resolved files with `handoff_log_paths`
- writes outputs with `handoff_write_stage_outputs`
- writes a manifest under `results/.../handoffs/<stage>.tcl`

Canonical OpenROAD 3D handoff sequence:

| Stage | Input | Output |
|---|---|---|
| `ord-3d-floorplan` | `${DESIGN}_3D.fp.v`, `1_synth.sdc` | `2_3_floorplan_3d.def/.v`, `1_synth.sdc` |
| `ord-3d-io` | `2_3_floorplan_3d.def/.v`, `1_synth.sdc` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` |
| `ord-3d-split-net` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` | updated `2_4_floorplan_io.def/.v`, `1_synth.sdc` |
| `ord-place-macro-upper` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` | `2_5_place_macro_upper.def/.v`, `1_synth.sdc` |
| `ord-place-macro-bottom` | `2_5_place_macro_upper.def/.v`, `1_synth.sdc` | `2_5_place_macro_bottom.def/.v`, `1_synth.sdc` |
| `ord-3d-pdn-only-bottom` | `2_5_place_macro_bottom.def/.v`, `1_synth.sdc` | `2_6_floorplan_pdn_bottom.def/.v`, `1_synth.sdc` |
| `ord-3d-pdn-only-upper` | `2_6_floorplan_pdn_bottom.def/.v`, `1_synth.sdc` | `2_6_floorplan_pdn.def/.v`, alias `2_floorplan.def/.v/.sdc` |
| `ord-place-init` | `2_floorplan.def/.v/.sdc` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` |
| `ord-place-init-upper` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-init-bottom` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-upper` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-bottom` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-gp2lg` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` |
| `ord-legalize-upper` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` | same handoff updated in place, alias `3_place.def/.v/.sdc` |
| `ord-legalize-bottom` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` | same handoff updated in place, alias `3_place.def/.v/.sdc` |
| `ord-cts` | `3_place.def/.v/.sdc` | `4_0_cts.def/.v/.sdc/.odb` |
| `ord-cts-post` | `4_0_cts.def/.v/.sdc/.odb` | `4_cts.def/.v/.sdc/.odb` |
| `ord-route` | `4_cts.def/.v/.sdc` | `5_1_grt.odb/.sdc` then `5_route.def/.v/.sdc/.odb` |
| `ord-final` | `5_route.def/.v/.sdc` | `6_final.odb/.def/.v/.sdc`, `final_summary.txt` |

## LEF View Strategy

The OpenROAD Makefile uses the same LEF-view concept as the Cadence flow.

| LEF view | Meaning |
|---|---|
| `LEF_FILES_SPLIT` | Full 3D LEF visibility for front-end 3D construction and split-net |
| `LEF_FILES_BOTTOM_COVER` | Bottom tier is protected; upper tier is the active optimization side |
| `LEF_FILES_UPPER_COVER` | Upper tier is protected; bottom tier is the active optimization side |
| `LEF_FILES_CTS_OWNER` | Owner-tier tree construction view |
| `LEF_FILES_CTS_RECEIVE` | Receive-tier clock repair/optimization view |
| `LEF_FILES` | Full LEF visibility for route and final report |

Applied by stage:

| Target | LEF view |
|---|---|
| `ord-3d-floorplan` | `LEF_FILES_SPLIT` |
| `ord-3d-io` | `LEF_FILES_SPLIT` |
| `ord-3d-split-net` | `LEF_FILES_SPLIT` |
| `ord-place-macro-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-macro-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-3d-pdn-only-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-3d-pdn-only-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-place-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-gp2lg` | handoff copy only |
| `ord-legalize-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-legalize-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-cts` | `LEF_FILES_CTS_OWNER` |
| `ord-cts-post` | `LEF_FILES_CTS_RECEIVE` |
| `ord-route` | `LEF_FILES` |
| `ord-final` | `LEF_FILES` |

## Tier Strategy and Allow-Net Control

The OpenROAD tier policy is implemented in:

- [placement_utils.tcl](scripts_openroad/placement_utils.tcl)
- [placement_tier_metrics_policy.tcl](scripts_openroad/placement_tier_metrics_policy.tcl)

It provides four pieces of control:

- library-side `set_dont_use`
- per-net `set_dont_touch` / `unset_dont_touch`
- row/site rebuild after tier switch
- split-topology protection hooks

### Low-level net classes

The physical classifier in OpenROAD still uses the same four structural classes:

- `upper_only`
- `bottom_only`
- `mixed`
- `unknown`

The public knobs are:

- `PIN3D_ALLOW_NET_FLOW=on|off`
- `TIER_ALLOW_NET=upper-only|bottom-only|all`

Resolution rule:

- `PIN3D_ALLOW_NET_FLOW=off` forces effective allow-net to `all`
- otherwise `TIER_ALLOW_NET` is honored

Meaning of the raw mask:

- `upper-only`: unlock `upper_only` and `mixed`, lock `bottom_only` and `unknown`
- `bottom-only`: unlock `bottom_only` and `mixed`, lock `upper_only` and `unknown`
- `all`: unlock `upper_only`, `bottom_only`, and `mixed`, lock `unknown`

### Current co-optimization policy

The current OpenROAD strategy does **not** try to solve 3D optimization by globally locking all `mixed` nets. That was rejected because it hurts timing, blocks DRV repair, and defeats the point of split-net optimization.

Instead the flow uses three practical optimization families:

- `clock nets`
- `split-managed data nets`
- `regular data nets`

Policy:

- `clock nets` are exempted from tier locking during `ord-cts` and `ord-cts-post` via `-skip_clock_nets 1`
- `regular data nets` are still left available to the tool under the normal owner-tier mask
- `split-managed data nets` are tracked and reported explicitly; repair is not automatic after every active stage

This keeps normal mixed-net optimization available while still measuring whether the intended split topology survives later optimization.

### Stage-level policy

| Target family | Tier policy |
|---|---|
| macro / PDN / route / final | `allow_net all` |
| `ord-place-upper` | `upper-only` |
| `ord-place-bottom` | `bottom-only` |
| `ord-legalize-upper` | `upper-only` |
| `ord-legalize-bottom` | `bottom-only` |
| `ord-cts` | owner-tier tree construction, derived from `CTS_LAYER`, with clock-net exemption |
| `ord-cts-post` | receive-tier clock repair/optimization, derived as the opposite of `CTS_LAYER`, with clock-net exemption |

`apply_tier_policy` rebuilds rows by default after switching tier context. This is the intended behavior for OpenROAD 3D stages, including macro placement, split PDN, CTS, route, and final reporting, because follow-pin rails and tier-site consistency depend on the rebuilt row pattern.

The current active optimization stages do not rely on blanket split-buffer `dont_touch`. The intended preservation mechanism is now the split topology itself plus stage-side reporting, not automatic Tcl repair after each stage.

## Split-Net Strategy

Split-net is now a real public stage:

- `ord-3d-split-net`
- script: [split_net_stage.tcl](scripts_openroad/split_net_stage.tcl)
- algorithm helper: [split_net.tcl](scripts_openroad/split_net.tcl) and [split_net_impl.tcl](scripts_openroad/split_net_impl.tcl)

Behavior:

- input and output are both `2_4_floorplan_io.def/.v`
- the stage edits the post-IO handoff in place
- `PIN3D_SPLIT_NET_FLOW=off` converts the stage into pass-through mode
- the pass inserts an ordinary tier-local `BUF*`, not a special 1-input/2-output splitter cell

### Split intent

For a mixed data net, the intended topology is:

- original net keeps the driver, retained sinks, and split-buffer input
- branch net is driven only by the split-buffer output
- moved sinks are isolated behind that branch net

This is the same high-level intent as the Cadence flow: convert one uncontrolled mixed fanout into one controlled split boundary plus tier-local fanout on the moved side.

### Split manifest

Successful split actions are written into:

- `pin3d_split_manifest.list`

Each record includes:

- `original_net`
- `branch_net`
- `split_inst`
- `buffer_master`
- `driver_tier`
- `buffer_tier`
- `retained_tier`
- `driver_pin`
- `moved_sinks`
- `retained_sinks`
- cost-decision fields such as `score_upper`, `score_bottom`, `util_upper`, `util_bottom`, `estimated_extra_hbt_upper`, and `estimated_extra_hbt_bottom`

The manifest is the contract for later analysis stages. After `split_net`, later stages are allowed to insert same-tier local buffers around the split point, but the reports continue to check whether the moved and retained sink partitions stayed meaningful.

### Buffer placement and cell choice

Current split selection is cost-driven:

- a split candidate is defined by `mixed_fanout`, not by raw structural cross-tier presence
- the mixed-fanout classifier ignores driver tier and ignores `__PIN3DSPLITBUF__` pins
- the pass evaluates placing the split buffer on `upper` and on `bottom`
- if the buffer is placed on `upper`, upper sinks move to the branch net and bottom sinks remain on the original net
- if the buffer is placed on `bottom`, bottom sinks move to the branch net and upper sinks remain on the original net
- unsupported top-level sink rewrites remain infeasible choices
- if both candidate choices are illegal, the net is skipped deterministically

The score is:

```text
score(t) = w_util * util_penalty(t) + w_hbt * hbt_penalty(t) + w_area * buffer_area_penalty(t)
```

Default parameters:

- `u_safe = 0.60`
- `alpha = 12.0`
- `w_util = 1.0`
- `w_hbt = 2.5`
- `w_area = 400.0`
- high-util forbid threshold = `0.80`
- near-tie threshold = `5%`

The utilization term uses a single-threshold exponential penalty:

```text
util_penalty(u) = 0                                  when u <= u_safe
util_penalty(u) = exp(alpha * (u - u_safe)) - 1      when u > u_safe
```

The HBT term is a split-decision proxy only:

- if `buffer_tier != driver_tier`, `estimated_extra_hbt = 1`
- if `buffer_tier == driver_tier`, `estimated_extra_hbt = retained_opposite_tier_sink_count`
- `hbt_penalty = log2(1 + estimated_extra_hbt)`

The area term uses the chosen split buffer master area normalized by the
current core area:

- `buffer_area_penalty = chosen_buffer_area / core_area`

The area term is intentionally simple and uses the chosen split buffer master
only:

- `buffer_area_penalty = chosen_buffer_area / core_area`

This makes the area term more visible on very small designs, where a few extra
buffers can perturb tier density materially even if the absolute cell count is
small.

This is not the actual routed HBT count. It exists only to rank the two legal split choices cheaply before routing.

The full score is:

```text
score(t) = w_util * util_penalty(t) + w_hbt * hbt_penalty(t) + w_area * buffer_area_penalty(t)
```

Tie handling is deterministic. When the two scores differ by less than `5%`, the pass breaks the tie by lower utilization penalty, then lower `estimated_extra_hbt`, then lower area penalty, then opposite-of-driver tier, then lexical fallback to `upper`.

The tier utilization model is intentionally lightweight. OpenROAD estimates global tier utilization once per split run from tier-classified master area divided by the current core area, then reuses that value for all candidate nets. The area term reuses the same core area and the chosen candidate buffer master area. No local bin congestion or route-stage geometry is used.

Buffer master choice:

- ordinary tier-local `BUF*`
- exactly one signal input and one signal output
- excludes non-buffer / unusable masters
- sized by moved sink count using `PIN3D_SPLIT_FANOUT_PER_DRIVE`
- picks the smallest legal drive that satisfies the estimated moved-branch load

### Immediate verification

Each inserted split is validated immediately inside the split stage:

- buffer input must remain on the original net
- buffer output must drive the branch net
- moved sinks must end up on the branch net
- retained sinks must stay off the branch net
- driver must stay on the original net
- original net must be `mixed_fanout`-pure after the split
- branch net must be `mixed_fanout`-pure after the split

If that local verification fails, the split action is rolled back and reported as a failed split.

### Reports

The split stage currently emits:

- `split_net.summary.rpt`
- `split_net.actions.rpt`
- `split_net.before.nets`
- `split_net.after.nets`
- `split_net.cross_tier.summary.rpt`
- `split_net.mixed_fanout.summary.rpt`
- `split_net.split.before.rpt`
- `split_net.split.after.rpt`
- `split_net.split.summary.rpt`
- `split_net.cross_tier.delta.rpt`

### Current scope and boundaries

- top-level term driven nets are still skipped and reported as `top_level_term_driver_not_supported`
- top-level sink rewire is still out of scope and reported as `top_level_sink_rewire_not_supported`
- clock nets are skipped by the split pass
- reporting terminology is normalized to `upper` / `bottom`

## Split Diagnostics

The current OpenROAD 3D flow does not auto-repair split topology after every active stage. Instead it keeps explicit stage-side diagnostics so later optimization can be judged against the split intent.

Stage reports used for this debug loop are:

- `<stage>.split.summary.rpt`
- `<stage>.cross_tier.delta.rpt`
- `<stage>.cross_tier.summary.rpt`
- `<stage>.mixed_fanout.summary.rpt`
- `<stage>.clock.cross_tier.summary.rpt` for CTS stages

The attribution report distinguishes:

- added clock-related cross-tier nets
- added data-related cross-tier nets
- split-related vs non-split-related additions

This is the current mechanism used to answer whether a stage:

- deleted split buffers
- recreated uncontrolled mixed data nets
- or only added expected CTS clock-tree branches

## Stage-by-Stage Target Map

| Target | Main script | Main commands | Purpose |
|---|---|---|---|
| `ord-pre` | `generate_3d_views.py` | view rewrite from partition + map | Create 3D DEF/netlist view from 2D preplace result |
| `ord-3d-floorplan` | `floorplan_3d.tcl` | `initialize_floorplan`, `make_tracks` | Build the initial 3D floorplan from the split netlist view |
| `ord-3d-io` | `io_place_3d.tcl` -> `io_place.tcl` -> `io_place_helpers.tcl` | `set_io_pin_constraint`, `place_pins` | Deterministic perimeter IO placement |
| `ord-3d-split-net` | `split_net_stage.tcl` -> `split_net.tcl` -> `split_net_impl.tcl` | `extract_cross_tier_nets`, `extract_mixed_fanout_nets`, `::tier_split_or2::run` | Reduce upper/bottom mixed fanout before macro placement |
| `ord-place-macro-upper` | `place_macro_upper.tcl` | `apply_tier_policy upper`, macro placement helper | Place upper macros while bottom tier is cover |
| `ord-place-macro-bottom` | `place_macro_bottom.tcl` | `apply_tier_policy bottom`, macro placement helper | Place bottom macros while upper tier is cover |
| `ord-3d-pdn-only-bottom` | `pdn_only_bottom.tcl` | handoff preservation + tier policy | Publish a bottom-side PDN checkpoint handoff |
| `ord-3d-pdn-only-upper` | `pdn_only_upper.tcl` | `pdngen`, `POST_PDN_TCL` | Final PDN pass and publish canonical `2_floorplan.*` |
| `ord-place-init` | `place_init.tcl` | `global_placement` | Bootstrap global placement on the 3D floorplan |
| `ord-place-init-upper` | `place_init_upper.tcl` | `global_placement` | Upper-focused init refinement |
| `ord-place-init-bottom` | `place_init_bottom.tcl` | `global_placement` | Bottom-focused init refinement |
| `ord-place-upper` | `place_upper.tcl` | `fastroute_setup`, `global_placement` | Upper tier preCTS optimization loop |
| `ord-place-bottom` | `place_bottom.tcl` | `fastroute_setup`, `global_placement` | Bottom tier preCTS optimization loop |
| `ord-gp2lg` | `handoff_copy_gp2lg.tcl` | handoff copy only | Freeze the staged tmp handoff into the legalize handoff |
| `ord-legalize-upper` | `opt_lg_upper.tcl` | `detailed_placement`, `opt_design` helper | Upper-side legalization and preCTS clean-up |
| `ord-legalize-bottom` | `opt_lg_bottom.tcl` | `detailed_placement`, `opt_design` helper | Bottom-side legalization and preCTS clean-up |
| `ord-cts` | `cts.tcl` -> `cts_stage_common.tcl` | optional `repair_clock_inverters`, `clock_tree_synthesis`, optional owner `repair_clock_nets`, optional owner repair | Build clocks on the owner tier while the receive tier is fixed |
| `ord-cts-post` | `cts_post.tcl` -> `cts_stage_common.tcl` | `repair_clock_nets`, `repair_timing_helper` | Receive-tier post-CTS optimization while the owner tier is fixed |
| `ord-route` | `global_route.tcl`, `detail_route.tcl` | `global_route`, `detailed_route`, `repair_timing_helper` | Route the design and preserve `5_route.sdc` |
| `ord-final` | `final_report.tcl` | `global_connect`, `deleteRoutingObstructions`, `report_metrics`, `report_wire_length` | Publish `6_final.*` and final summary |

## Optimization Strategy

The current OpenROAD co-optimization strategy has five practical layers.

### 1. Structural co-optimization through staged handoff

The flow carries explicit 3D handoffs through:

- 3D floorplan
- deterministic IO
- split-net
- macro placement
- split PDN
- staged preCTS placement
- CTS and post-CTS repair
- route and final report

This makes each stage restartable, debuggable, and measurable with stage-local cross-tier reports.

### 2. Split first, then reduce mixed fanout

`ord-3d-split-net` runs before macro placement and before the staged placement loop. The purpose is not to freeze all mixed nets; it is to convert uncontrolled mixed fanout into tier-pure fanout partitions as early as possible.

The current flow therefore uses this sequence:

- insert split buffers
- record the split in the manifest
- verify that original and branch nets are `mixed_fanout`-pure
- let later stages optimize normally
- report whether later stages recreate mixed fanout

This preserves co-optimization capability while still making the fanout rebound visible.

### 3. Tier-aware masking with clock-tree exemption

The owner-tier masks still come from `apply_tier_policy`, but the important current rule is:

- do not globally disable `mixed` nets
- always exempt the clock-tree footprint during `ord-cts` and `ord-cts-post`

This keeps DRV and timing repair viable while avoiding the earlier CTS crash in which derived clock nets were left locked.

### 4. Staged CTS instead of flat CTS

The current OpenROAD flow now mirrors the Cadence CTS architecture more closely:

- `ord-cts` is the owner-tier tree construction stage and runs `clock_tree_synthesis`
- `ord-cts-post` is the receive-tier clock repair/optimization stage and does not rebuild a new clock tree
- the non-active tier is fixed with placement status `FIRM`
- clock nets remain exempt from tier locking

`F2F_CTS_MODE=single_trunk_handoff` should be read as the name of this staged owner/receive CTS policy. In the current OpenROAD scripts it is not a behavioral switch, and `F2F_CTS_HANDOFFS_PER_DOMAIN` is not used to enforce an exact number of physical handoff points per clock domain.

Current defaults:

- `ord-place-upper` / `ord-place-bottom`: timing-driven placement remains on
- `ord-legalize-upper` / `ord-legalize-bottom`: `OPENROAD_OPT_LG_ENABLE_REPAIR_DESIGN=0` by default
- `ord-cts`: `OPENROAD_CTS_OWNER_REPAIR_TIMING=0` by default, so owner-tree builds clocks without immediately doing full owner-side data `repair_timing`
- `ord-cts`: `OPENROAD_CTS_REPAIR_CLOCK_INVERTERS=0` by default in the staged 3D flow; this can be re-enabled explicitly, but on `asap7_nangate45_3D/ibex` it reduced clock cross-tier growth from `+175` to `+111`
- `ord-cts`: `OPENROAD_CTS_OWNER_REPAIR_CLOCK_NETS=0` by default, so owner-tree does not run an extra explicit `repair_clock_nets` after `clock_tree_synthesis`
- `ord-cts`: `SKIP_PIN_SWAP=1`
- `ord-cts-post`: `repair_clock_nets` runs, and post-CTS data `repair_timing` is enabled by default with `SKIP_CTS_POST_REPAIR_TIMING=0`

This is deliberate. The flow is currently biased toward keeping owner-tree CTS contained and shifting most data recovery to the receive stage.

### 5. Current debug focus: data cross-tier vs clock cross-tier

The current reporting separates:

- total cross-tier nets
- clock-only cross-tier nets
- data-related vs clock-related additions
- split-related vs non-split-related additions

This matters because the current behavior is different by stage:

- `split_net` reduces `mixed_fanout` aggressively even when structural cross-tier remains
- `place/legalize` are now measured against `mixed_fanout` rebound, not just raw structural crossings
- the remaining large increase at CTS is currently dominated by new clock-tree branches, not by collapse of the split-managed data topology

### Current observed behavior

On the current canonical OpenROAD debug cases:

- `asap7_nangate45_3D/ibex` split-only now completes in about `8s`, splits `223` candidate nets, and reduces structural cross-tier count from `547` to `324`

### Performance notes

The split stage was recently rewritten for runtime efficiency. Current acceleration points are:

- cached master lookup
- cached tier-local buffer candidate lists
- cached unique-name allocation
- prebuilt net / instance caches
- memoized tier classification
- lightweight immediate split verification
- no full-database `CELL_TIER` / `PIN_TIER` dump by default

These optimizations are now part of the intended OpenROAD split strategy, not a temporary debug workaround.

## Test and Experiment Scripts

OpenROAD test entry points under `test/openroad`:

- [ORD_3D_NEW_FLOW.sh](test/openroad/ORD_3D_NEW_FLOW.sh)
- [ORD_3D_ALLOW_NET_MATRIX.sh](test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh)
- [README.sh](test/openroad/README.sh)

The default matrix currently targets `gcd` first:

- `asap7_3D:gcd`
- `asap7_nangate45_3D:gcd`
- `nangate45_3D:gcd`

with the two comparison modes:

- `allownet:on:on`
- `noallownet:off:off`

The extractor writes CSV rows from the split-stage summary artifact and the final summary artifact.

## Current Verification Notes

Current smoke validation of the split Tcl structure shows:

- `ord-3d-split-net` still reaches the full split pass and emits split diagnostics plus the split manifest
- `io_place.tcl` still produces deterministic IO placement outputs
- `tier_partition.tcl` still enters the TritonPart UB sweep and emits the sweep plan artifacts

These checks were intentionally stopped once the relevant source chains had been exercised. They were not intended as final QoR experiments, and the concrete run artifacts are intentionally not referenced here.

## Current Boundaries

This first rebuilt OpenROAD flow intentionally does not yet do everything the Cadence flow does.

Current boundaries:

- CTS and route remain public `ord-cts`, `ord-cts-post`, `ord-route` targets
- HB-via metrics are not added to the OpenROAD CSV yet
- top-level term-driven split-net support is still out of scope in v1
- top-level sink rewire is still out of scope in v1
- post-CTS data `repair_timing` is enabled by default with `SKIP_CTS_POST_REPAIR_TIMING=0`
- the new IO logic mirrors the Cadence structure, but remains constrained by OpenROAD `set_io_pin_constraint` / `place_pins`

That said, the major flow architecture is now parallel to the commercial Cadence flow:

- same public stage shape
- same handoff discipline
- same allow-net and split-flow switches
- same staged preCTS philosophy
- same launcher and extraction pattern
