from collections import OrderedDict

from yosys_json_toolkit import BitAllocator, add_cell, add_netname


SUPPORTED_CONSTANTS = {"0", "1"}


def validate_tie_specs(tie_specs, leaf_cell_types):
    if set(tie_specs.keys()) != SUPPORTED_CONSTANTS:
        raise AssertionError(
            "Tie specifications must define exactly constants 0 and 1: {}".format(
                sorted(tie_specs.keys())
            )
        )
    normalized = OrderedDict()
    seen = set()
    for constant in ["0", "1"]:
        spec = tie_specs[constant]
        cell_type = spec.get("cell_type")
        output_pin = spec.get("output_pin")
        if not isinstance(cell_type, str) or not cell_type:
            raise AssertionError("Tie-cell type for constant {} must be non-empty".format(constant))
        if not isinstance(output_pin, str) or not output_pin:
            raise AssertionError("Tie-cell output pin for constant {} must be non-empty".format(constant))
        if cell_type not in leaf_cell_types:
            raise AssertionError(
                "Tie cell {} for constant {} is absent from the active Liberty cell set".format(
                    cell_type, constant
                )
            )
        identity = (cell_type, output_pin)
        if identity in seen:
            raise AssertionError("TIELO and TIEHI specifications must differ: {}".format(identity))
        seen.add(identity)
        normalized[constant] = OrderedDict(
            [("cell_type", cell_type), ("output_pin", output_pin)]
        )
    return normalized


def _unique_generated_name(module, prefix):
    index = 0
    while True:
        name = "{}{}".format(prefix, index)
        net_name = name + "_net"
        if (
            name not in module.cells
            and name not in module.netnames
            and net_name not in module.cells
            and net_name not in module.netnames
        ):
            return name
        index += 1


def _insert_tie(module, allocator, constant, spec):
    base_name = _unique_generated_name(module, "__syn3d_tie_{}_".format(constant))
    bit = allocator.allocate_one()
    net_name = base_name + "_net"
    add_netname(module, net_name, [bit], hide_name=0, attributes={})
    add_cell(
        module,
        base_name,
        spec["cell_type"],
        OrderedDict([(spec["output_pin"], [bit])]),
        hide_name=0,
        attributes=OrderedDict([("syn3d_inserted_tie", "1")]),
        port_directions=OrderedDict([(spec["output_pin"], "output")]),
    )
    return bit


def normalize_module_constants(module, leaf_cell_types, tie_specs):
    tie_specs = validate_tie_specs(tie_specs, leaf_cell_types)
    allocator = BitAllocator.after(module)
    counts = OrderedDict(
        [
            ("cell_input_0", 0),
            ("cell_input_1", 0),
            ("module_output_0", 0),
            ("module_output_1", 0),
        ]
    )

    for cell_name, cell in list(module.cells.items()):
        for pin_name, bits in cell.connections.items():
            for bit_index, bit in enumerate(list(bits)):
                if not isinstance(bit, str):
                    continue
                if bit not in SUPPORTED_CONSTANTS:
                    raise AssertionError(
                        "Unsupported direct constant on {}.{}.{}[{}]: {!r}".format(
                            module.name, cell_name, pin_name, bit_index, bit
                        )
                    )
                if cell.type not in leaf_cell_types:
                    raise AssertionError(
                        "Direct constant reaches non-leaf cell {}.{} of type {}".format(
                            module.name, cell_name, cell.type
                        )
                    )
                direction = cell.port_directions.get(pin_name)
                if direction != "input":
                    raise AssertionError(
                        "Direct constant is only legal on a leaf input pin before normalization; "
                        "got {}.{}.{} direction {!r}".format(
                            module.name, cell_name, pin_name, direction
                        )
                    )
                bits[bit_index] = _insert_tie(module, allocator, bit, tie_specs[bit])
                counts["cell_input_{}".format(bit)] += 1

    for port_name, port in module.ports.items():
        for bit_index, bit in enumerate(list(port.bits)):
            if not isinstance(bit, str):
                continue
            if bit not in SUPPORTED_CONSTANTS:
                raise AssertionError(
                    "Unsupported direct constant on {}.{}[{}]: {!r}".format(
                        module.name, port_name, bit_index, bit
                    )
                )
            if port.direction != "output":
                raise AssertionError(
                    "Direct module-port constant is only legal on an output before normalization; "
                    "got {}.{} direction {}".format(module.name, port_name, port.direction)
                )
            port_netname = module.netnames.get(port_name)
            if port_netname is None:
                raise AssertionError(
                    "Direct constant output {}.{} has no same-name netname".format(
                        module.name, port_name
                    )
                )
            if len(port_netname.bits) != len(port.bits) or port_netname.bits[bit_index] != bit:
                raise AssertionError(
                    "Direct constant output/netname mismatch on {}.{}[{}]: port={!r} netname={!r}".format(
                        module.name,
                        port_name,
                        bit_index,
                        port.bits,
                        port_netname.bits,
                    )
                )
            normalized_bit = _insert_tie(module, allocator, bit, tie_specs[bit])
            port.bits[bit_index] = normalized_bit
            port_netname.bits[bit_index] = normalized_bit
            counts["module_output_{}".format(bit)] += 1

    total = sum(counts.values())
    counts["inserted_tie_count"] = total
    return counts


def normalize_design_constants(design, module_configs):
    unknown = sorted(set(module_configs.keys()) - set(design.modules.keys()))
    if unknown:
        raise AssertionError("Constant-normalization modules are missing: {}".format(unknown))
    modules = OrderedDict()
    total = 0
    for module_name, config in module_configs.items():
        stats = normalize_module_constants(
            design.get_module(module_name),
            set(config["leaf_cell_types"]),
            config["tie_specs"],
        )
        modules[module_name] = stats
        total += stats["inserted_tie_count"]
    return OrderedDict(
        [
            ("module_count", len(modules)),
            ("inserted_tie_count", total),
            ("modules", modules),
        ]
    )
