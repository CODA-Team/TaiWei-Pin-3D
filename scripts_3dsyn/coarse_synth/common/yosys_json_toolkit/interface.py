"""Port-interface helpers for Yosys JSON netlists."""

from copy import deepcopy


SINGLE_BIT_VECTOR_ATTRIBUTE = "single_bit_vector"


def _normalized_int(value):
    return 0 if value is None else int(value)


def _yosys_boolean_attribute(value, attribute_name):
    if value is None:
        return False
    if isinstance(value, bool):
        raise ValueError("Yosys attribute {} must not be a Python boolean.".format(attribute_name))
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        bits = value.strip()
        if bits and all(bit in "01" for bit in bits):
            return "1" in bits
    raise ValueError("Invalid Yosys boolean attribute {}={!r}.".format(attribute_name, value))


def _checked_port_netname(module, port_name):
    if port_name not in module.ports:
        raise KeyError("Port {!r} does not exist in module {!r}.".format(port_name, module.name))
    if port_name not in module.netnames:
        raise ValueError(
            "Port {!r} in module {!r} has no same-name netname.".format(port_name, module.name)
        )

    port = module.ports[port_name]
    netname = module.netnames[port_name]
    if list(port.bits) != list(netname.bits):
        raise ValueError(
            "Port/netname {!r} in module {!r} have different bits: port={} netname={}.".format(
                port_name, module.name, port.bits, netname.bits
            )
        )
    for field_name in ("offset", "upto", "signed"):
        port_value = _normalized_int(getattr(port, field_name))
        netname_value = _normalized_int(getattr(netname, field_name))
        if port_value != netname_value:
            raise ValueError(
                "Port/netname {!r} in module {!r} have different {} values: port={} netname={}.".format(
                    port_name, module.name, field_name, port_value, netname_value
                )
            )
    return port, netname


def port_is_single_bit_vector(module, port_name):
    """Return whether a one-bit port was declared with an explicit range."""
    port, netname = _checked_port_netname(module, port_name)
    value = netname.attributes.get(SINGLE_BIT_VECTOR_ATTRIBUTE)
    is_single_bit_vector = _yosys_boolean_attribute(value, SINGLE_BIT_VECTOR_ATTRIBUTE)
    if is_single_bit_vector and len(port.bits) != 1:
        raise ValueError(
            "Port {!r} in module {!r} has single_bit_vector but width is {}.".format(
                port_name, module.name, len(port.bits)
            )
        )
    if len(port.bits) == 1 and not is_single_bit_vector:
        if _normalized_int(port.offset) != 0 or _normalized_int(port.upto) != 0:
            raise ValueError(
                "One-bit port {!r} in module {!r} has indexed shape metadata without single_bit_vector.".format(
                    port_name, module.name
                )
            )
    return is_single_bit_vector


def signal_bit_labels(name, bits, offset=None, upto=None, single_bit_vector=False):
    """Return logical labels for a Yosys signal in bit-list order."""
    width = len(bits)
    if width == 0:
        raise ValueError("Signal {!r} has zero width.".format(name))
    if single_bit_vector and width != 1:
        raise ValueError("Signal {!r} has single_bit_vector but width is {}.".format(name, width))
    if width == 1 and not single_bit_vector:
        if _normalized_int(offset) != 0 or _normalized_int(upto) != 0:
            raise ValueError(
                "One-bit signal {!r} has indexed shape metadata without single_bit_vector.".format(name)
            )
        return [(None, name)]

    logical_offset = _normalized_int(offset)
    logical_upto = _normalized_int(upto)
    labels = []
    for position in range(width):
        if logical_upto:
            logical_index = logical_offset + width - position - 1
        else:
            logical_index = logical_offset + position
        labels.append((logical_index, "{}[{}]".format(name, logical_index)))
    return labels


def netname_bit_labels(netname):
    """Return logical labels for one typed Yosys JSON netname."""
    value = netname.attributes.get(SINGLE_BIT_VECTOR_ATTRIBUTE)
    is_single_bit_vector = _yosys_boolean_attribute(value, SINGLE_BIT_VECTOR_ATTRIBUTE)
    return signal_bit_labels(
        netname.name,
        netname.bits,
        offset=netname.offset,
        upto=netname.upto,
        single_bit_vector=is_single_bit_vector,
    )


def port_bit_labels(module, port_name):
    """Return ``(logical_index, label)`` entries in Yosys bit-list order."""
    port, _netname = _checked_port_netname(module, port_name)
    is_single_bit_vector = port_is_single_bit_vector(module, port_name)
    return signal_bit_labels(
        port_name,
        port.bits,
        offset=port.offset,
        upto=port.upto,
        single_bit_vector=is_single_bit_vector,
    )


def port_shape(module, port_name):
    """Return the stable, bit-id-independent shape of one module port."""
    port, _netname = _checked_port_netname(module, port_name)
    return {
        "name": port_name,
        "direction": port.direction,
        "width": len(port.bits),
        "offset": _normalized_int(port.offset),
        "upto": _normalized_int(port.upto),
        "signed": _normalized_int(port.signed),
        "single_bit_vector": port_is_single_bit_vector(module, port_name),
        "bit_labels": [label for _index, label in port_bit_labels(module, port_name)],
    }


def module_port_shape_signature(module):
    """Return an ordered semantic interface signature for a module."""
    return [port_shape(module, port_name) for port_name in module.ports]


def copy_port_shape_metadata(source_module, destination_module, port_name):
    """Copy source declaration metadata while preserving destination bit IDs."""
    source_port, source_netname = _checked_port_netname(source_module, port_name)
    destination_port, destination_netname = _checked_port_netname(destination_module, port_name)
    if source_port.direction != destination_port.direction:
        raise ValueError(
            "Port direction mismatch for {}: source={} destination={}.".format(
                port_name, source_port.direction, destination_port.direction
            )
        )
    if len(source_port.bits) != len(destination_port.bits):
        raise ValueError(
            "Port width mismatch for {}: source={} destination={}.".format(
                port_name, len(source_port.bits), len(destination_port.bits)
            )
        )

    for field_name in ("offset", "upto", "signed"):
        value = deepcopy(getattr(source_port, field_name))
        setattr(destination_port, field_name, value)
        setattr(destination_netname, field_name, deepcopy(value))

    destination_netname.attributes.pop(SINGLE_BIT_VECTOR_ATTRIBUTE, None)
    if port_is_single_bit_vector(source_module, port_name):
        destination_netname.attributes[SINGLE_BIT_VECTOR_ATTRIBUTE] = deepcopy(
            source_netname.attributes[SINGLE_BIT_VECTOR_ATTRIBUTE]
        )
    return port_shape(destination_module, port_name)


def normalize_module_port_shapes(reference_module, destination_module):
    """Apply an authoritative interface shape after a tool round-trip."""
    reference_names = list(reference_module.ports)
    destination_names = list(destination_module.ports)
    if set(reference_names) != set(destination_names):
        raise ValueError(
            "Module port sets differ: reference_only={} destination_only={}.".format(
                sorted(set(reference_names) - set(destination_names)),
                sorted(set(destination_names) - set(reference_names)),
            )
        )

    changed = []
    for port_name in reference_names:
        destination_port, destination_netname = _checked_port_netname(destination_module, port_name)
        before = (
            destination_port.offset,
            destination_port.upto,
            destination_port.signed,
            deepcopy(destination_netname.attributes.get(SINGLE_BIT_VECTOR_ATTRIBUTE)),
        )
        copy_port_shape_metadata(reference_module, destination_module, port_name)
        after_port, after_netname = _checked_port_netname(destination_module, port_name)
        after = (
            after_port.offset,
            after_port.upto,
            after_port.signed,
            deepcopy(after_netname.attributes.get(SINGLE_BIT_VECTOR_ATTRIBUTE)),
        )
        if before != after:
            changed.append(port_name)
    if destination_names != reference_names:
        destination_module.ports = destination_module.ports.__class__(
            (name, destination_module.ports[name]) for name in reference_names
        )
    return changed
