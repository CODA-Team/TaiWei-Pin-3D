# Nangate45 3D RC evaluation policy

The bundled models support research comparisons, not calibrated 3D signoff.
There is no validated `NG45.tch` in this platform. The bundled `typical.captable`
is a 2D table and must not be silently applied to the mirrored 3D layer stack.

## Configuration

- `CDS_RC_MODE=lef` explicitly initializes approximate native RC corners. This is
  the Nangate45 3D default for intermediate Cadence stages and is logged as such.
- `CDS_RC_MODE=qrc QRC_FILE=/validated/model.tch` binds that file to both RC
  corners. Missing files fail instead of silently falling back to LEF RC.
- `CDS_FINAL_RC_MODE=spef` is the Nangate45 3D default: final Innovus evaluation
  imports `RESULTS_DIR/6_final.spef` into both corners. Run `ord-final` first.
  A missing SPEF, or one older than its routed DEF/netlist inputs, fails.
  `CDS_FINAL_SPEF` can explicitly select another SPEF; the caller must ensure
  it belongs to the same physical design. Timestamp checks do not prove identity.
- `CDS_FINAL_RC_MODE=native` explicitly selects native extraction. Its accuracy
  depends on `CDS_RC_MODE`; native LEF extraction may assign default via values.
- `CDS_SI_AWARE=0|1` explicitly controls final Innovus SI analysis; the default is
  `1`. Do not claim physical improvement by switching SI off or changing models.
- `PIN3D_REQUIRE_RCX_LAYER_MATCH=1` checks the OpenRCX `LayerCount` against the
  loaded database routing-layer count before final artifacts are written.
  Despite its filename, `NangateOpenCellLibrary.tech21.lef` contains **19 routing
  layers**, and matches `NangateOpenCellLibrary.tech.rcx_patterns.rules`.
  The separate 21-layer rules file does not match this LEF.

Final evaluation logs include `extraction_config.txt` and
`openrcx_config.txt`. These identify model sources and analysis settings; they
are not evidence of foundry calibration. Common SPEF does not force timing
engines to agree: waveform, coupling, OCV and other settings can still differ.

## Preserving experiment controls

Run the same DEF/netlist through the old and new evaluation policies before
optimizing. Use a separate `WORK_HOME` per experiment. Keep clock period,
external IO delays and placement checkpoint fixed. Report setup/hold, DRC,
ERC, cell area and model/SI policy separately. Parameterize setup repair with
`SETUP_SLACK_MARGIN` rather than changing the clock or removing IO constraints.
After netlist or physical changes, reroute and regenerate SPEF.

Policy tests (no EDA license):

```sh
python3 tests/unit/test_rc_policy.py
```
