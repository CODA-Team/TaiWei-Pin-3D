"""Dependency-free HBT RC model used by per-tier synthesis."""

from collections import OrderedDict


SUPPORTED_MODES = {"scale", "direct"}


# Values are taken from the corresponding Liberty input pin and intentionally
# match the ABC driver selected in flow_config.py for each tier.
D2D_BUFFER_BASELINES = {
    "asap7_3D": {
        "upper": OrderedDict(
            [
                ("buffer_cell", "BUFx2_ASAP7_75t_R_upper"),
                ("input_pin", "A"),
                ("output_pin", "Y"),
                ("cin_fF", 0.577042),
                ("drive_res_kohm", 1.5705555555555557),
            ]
        ),
        "bottom": OrderedDict(
            [
                ("buffer_cell", "BUFx2_ASAP7_75t_R_bottom"),
                ("input_pin", "A"),
                ("output_pin", "Y"),
                ("cin_fF", 0.577042),
                ("drive_res_kohm", 1.5705555555555557),
            ]
        ),
    },
    "asap7_nangate45_3D": {
        "upper": OrderedDict(
            [
                ("buffer_cell", "BUFx2_ASAP7_75t_R_upper"),
                ("input_pin", "A"),
                ("output_pin", "Y"),
                ("cin_fF", 0.577042),
                ("drive_res_kohm", 1.5705555555555557),
            ]
        ),
        "bottom": OrderedDict(
            [
                ("buffer_cell", "BUF_X1_bottom"),
                ("input_pin", "A"),
                ("output_pin", "Z"),
                ("cin_fF", 0.974659),
                ("drive_res_kohm", 2.4897144358725964),
            ]
        ),
    },
    "nangate45_3D": {
        "upper": OrderedDict(
            [
                ("buffer_cell", "BUF_X1_upper"),
                ("input_pin", "A"),
                ("output_pin", "Z"),
                ("cin_fF", 0.974659),
                ("drive_res_kohm", 2.4897144358725964),
            ]
        ),
        "bottom": OrderedDict(
            [
                ("buffer_cell", "BUF_X1_bottom"),
                ("input_pin", "A"),
                ("output_pin", "Z"),
                ("cin_fF", 0.974659),
                ("drive_res_kohm", 2.4897144358725964),
            ]
        ),
    },
}


def _copy_baselines(library, abc_driver_by_tier):
    assert library in D2D_BUFFER_BASELINES, "Missing D2D capacitance baseline for {}".format(library)
    baselines = OrderedDict()
    for tier in ("upper", "bottom"):
        baseline = OrderedDict(D2D_BUFFER_BASELINES[library][tier])
        expected_driver = abc_driver_by_tier[tier]
        assert baseline["buffer_cell"] == expected_driver, (
            "{} {} D2D baseline cell {} != flow_config ABC driver {}".format(
                library, tier, baseline["buffer_cell"], expected_driver
            )
        )
        baselines[tier] = baseline
    return baselines


def _all_channels(wrapper_plan):
    channels = []
    for channel in wrapper_plan["data_d2d_channels"]:
        channels.append(("data_d2d", channel))
    for channel in wrapper_plan["clock"]["clock_d2d_channels"]:
        channels.append(("clock_d2d", channel))
    return channels


def _nonnegative(value, label):
    parsed = float(value)
    if parsed < 0.0:
        raise ValueError("{} must be non-negative, got {}".format(label, parsed))
    return parsed


def resolve_hbt_config(env):
    """Resolve and validate the public HBT environment interface."""

    mode = str(env.get("SYN3D_HBT_MODEL_MODE", "scale")).strip().lower()
    if mode not in SUPPORTED_MODES:
        raise ValueError("Unsupported SYN3D_HBT_MODEL_MODE: {}".format(mode))

    if mode == "scale":
        if env.get("SYN3D_HBT_R_OHM") not in (None, "") or env.get("SYN3D_HBT_C_FF") not in (None, ""):
            raise ValueError("Direct R/C values require SYN3D_HBT_MODEL_MODE=direct")
        return OrderedDict(
            [
                ("mode", mode),
                ("r_scale", _nonnegative(env.get("SYN3D_HBT_R_SCALE", "0"), "SYN3D_HBT_R_SCALE")),
                ("c_scale", _nonnegative(env.get("SYN3D_HBT_C_SCALE", "0.25"), "SYN3D_HBT_C_SCALE")),
            ]
        )

    r_raw = env.get("SYN3D_HBT_R_OHM")
    c_raw = env.get("SYN3D_HBT_C_FF")
    if r_raw in (None, "") or c_raw in (None, ""):
        raise ValueError("direct mode requires SYN3D_HBT_R_OHM and SYN3D_HBT_C_FF")
    return OrderedDict(
        [
            ("mode", mode),
            ("r_ohm", _nonnegative(r_raw, "SYN3D_HBT_R_OHM")),
            ("c_fF", _nonnegative(c_raw, "SYN3D_HBT_C_FF")),
        ]
    )


def build_hbt_model(wrapper_plan, library, config, abc_driver_by_tier):
    """Build per-D2D-net R/C values from a validated public configuration."""

    mode = config["mode"]
    assert mode in SUPPORTED_MODES
    baselines = _copy_baselines(library, abc_driver_by_tier)
    entries = []
    seen_names = set()

    for channel_kind, channel in _all_channels(wrapper_plan):
        net_name = channel["d2d_name"]
        assert net_name not in seen_names, "Duplicate D2D net name: {}".format(net_name)
        seen_names.add(net_name)
        producer_tier = channel["producer_tier"]
        consumer_tier = channel["consumer_tier"]
        assert producer_tier in baselines, "Unsupported producer tier: {}".format(producer_tier)
        assert consumer_tier in baselines, "Unsupported consumer tier: {}".format(consumer_tier)
        assert producer_tier != consumer_tier, "D2D net must cross tiers: {}".format(channel)

        producer_base = baselines[producer_tier]
        consumer_base = baselines[consumer_tier]
        if mode == "scale":
            applied_res_kohm = producer_base["drive_res_kohm"] * config["r_scale"]
            applied_cap_fF = consumer_base["cin_fF"] * config["c_scale"]
        else:
            applied_res_kohm = config["r_ohm"] / 1000.0
            applied_cap_fF = config["c_fF"]

        entries.append(
            OrderedDict(
                [
                    ("net_name", net_name),
                    ("channel_kind", channel_kind),
                    ("producer_tier", producer_tier),
                    ("consumer_tier", consumer_tier),
                    ("producer_buffer_cell", producer_base["buffer_cell"]),
                    ("consumer_buffer_cell", consumer_base["buffer_cell"]),
                    ("base_drive_res_kohm", producer_base["drive_res_kohm"]),
                    ("base_sink_cap_fF", consumer_base["cin_fF"]),
                    ("applied_res_kohm", applied_res_kohm),
                    ("applied_res_ohm", applied_res_kohm * 1000.0),
                    ("applied_cap_fF", applied_cap_fF),
                ]
            )
        )

    enabled = any(entry["applied_res_kohm"] > 0.0 or entry["applied_cap_fF"] > 0.0 for entry in entries)
    return OrderedDict(
        [
            ("status", "enabled" if enabled else "disabled"),
            ("model_mode", mode),
            ("configuration", OrderedDict(config)),
            ("library", library),
            ("baselines", baselines),
            ("entry_count", len(entries)),
            ("entries", entries),
        ]
    )


def _tcl_quote(value):
    return "{" + str(value).replace("}", "\\}") + "}"


def _format_number(value):
    text = "{:.12g}".format(float(value))
    return "0" if text == "-0" else text


def render_hbt_tcl(model):
    """Render Genus constraints; resistance is in kOhm and capacitance in fF."""

    lines = [
        "# Generated by 3D-Syn per-tier synthesis",
        'puts "SYN3D_HBT_STATUS={}"'.format(model["status"]),
        'puts "SYN3D_HBT_MODEL_MODE={}"'.format(model["model_mode"]),
        "set syn3d_hbt_name_count 0",
        "set syn3d_hbt_object_count 0",
    ]
    for entry in model["entries"]:
        if entry["applied_res_kohm"] == 0.0 and entry["applied_cap_fF"] == 0.0:
            continue
        lines.extend(
            [
                "",
                "# {net} {producer}->{consumer} {kind}; consumer={cell} Cin={base}fF".format(
                    net=entry["net_name"],
                    producer=entry["producer_tier"],
                    consumer=entry["consumer_tier"],
                    kind=entry["channel_kind"],
                    cell=entry["consumer_buffer_cell"],
                    base=_format_number(entry["base_sink_cap_fF"]),
                ),
                "set syn3d_hbt_nets [get_nets -quiet {}]".format(_tcl_quote(entry["net_name"])),
                'if {[llength $syn3d_hbt_nets] != 1} { error "Expected exactly one d2d net for %s, got [llength $syn3d_hbt_nets]" }'
                % entry["net_name"],
                "set syn3d_hbt_net_name [get_db $syn3d_hbt_nets .name]",
            ]
        )
        if entry["applied_res_kohm"] > 0.0:
            lines.append(
                "set_resistance {} $syn3d_hbt_net_name".format(
                    _format_number(entry["applied_res_kohm"])
                )
            )
        if entry["applied_cap_fF"] > 0.0:
            lines.append(
                "set_load -wire_load {} $syn3d_hbt_net_name".format(
                    _format_number(entry["applied_cap_fF"])
                )
            )
        lines.extend(
            [
                "incr syn3d_hbt_name_count",
                "incr syn3d_hbt_object_count [llength $syn3d_hbt_nets]",
                "puts {}".format(
                    _tcl_quote(
                        "SYN3D_HBT_NET={net} MODEL={mode} PRODUCER={producer} CONSUMER={consumer} "
                        "R_KOHM={res} C_FF={cap}".format(
                            net=entry["net_name"],
                            mode=model["model_mode"],
                            producer=entry["producer_tier"],
                            consumer=entry["consumer_tier"],
                            res=_format_number(entry["applied_res_kohm"]),
                            cap=_format_number(entry["applied_cap_fF"]),
                        )
                    )
                ),
            ]
        )
    lines.extend(
        [
            'puts "SYN3D_HBT_ENTRY_COUNT=$syn3d_hbt_name_count"',
            'puts "SYN3D_HBT_OBJECT_COUNT=$syn3d_hbt_object_count"',
        ]
    )
    return "\n".join(lines) + "\n"
