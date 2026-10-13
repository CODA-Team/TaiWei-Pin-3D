"""Validation helpers for the Yosys JSON model."""

from .model import Cell, Design, Memory, Module, Netname, Port

VALID_BIT_STRINGS = {"0", "1", "x", "z"}
VALID_DIRECTIONS = {"input", "output", "inout"}


class ValidationError(ValueError):
    """Raised when a design fails structural validation."""

    def __init__(self, errors):
        self.errors = errors
        ValueError.__init__(self, "\n".join(errors))


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_attr_map(name, value, errors):
    if not isinstance(value, dict):
        errors.append("{} must be a dictionary.".format(name))
        return
    for key, item in value.items():
        if not isinstance(key, str):
            errors.append("{} key {!r} must be a string.".format(name, key))
        if not isinstance(item, (str, int)) or isinstance(item, bool):
            errors.append("{}[{!r}] must be a string or integer.".format(name, key))


def _validate_bit(name, bit, errors):
    if _is_int(bit):
        return
    if isinstance(bit, str) and bit in VALID_BIT_STRINGS:
        return
    errors.append("{} contains invalid bit value {!r}.".format(name, bit))


def _validate_bits(name, bits, errors):
    if not isinstance(bits, list):
        errors.append("{} must be a list of bits.".format(name))
        return
    for index, bit in enumerate(bits):
        _validate_bit("{}[{}]".format(name, index), bit, errors)


def _validate_optional_int(name, value, errors):
    if value is not None and not _is_int(value):
        errors.append("{} must be an integer when present.".format(name))


def _validate_port(module_name, port, errors):
    prefix = "module {} port {}".format(module_name, port.name)
    if port.direction not in VALID_DIRECTIONS:
        errors.append("{} has invalid direction {!r}.".format(prefix, port.direction))
    _validate_bits("{} bits".format(prefix), port.bits, errors)
    _validate_optional_int("{} offset".format(prefix), port.offset, errors)
    _validate_optional_int("{} upto".format(prefix), port.upto, errors)
    _validate_optional_int("{} signed".format(prefix), port.signed, errors)


def _validate_cell(module_name, cell, errors):
    prefix = "module {} cell {}".format(module_name, cell.name)
    if not isinstance(cell.type, str):
        errors.append("{} type must be a string.".format(prefix))
    _validate_optional_int("{} hide_name".format(prefix), cell.hide_name, errors)
    _validate_attr_map("{} parameters".format(prefix), cell.parameters, errors)
    _validate_attr_map("{} attributes".format(prefix), cell.attributes, errors)
    if not isinstance(cell.port_directions, dict):
        errors.append("{} port_directions must be a dictionary.".format(prefix))
    else:
        for port_name, direction in cell.port_directions.items():
            if not isinstance(port_name, str):
                errors.append("{} port_directions key {!r} must be a string.".format(prefix, port_name))
            if direction not in VALID_DIRECTIONS:
                errors.append(
                    "{} port_directions[{!r}] has invalid direction {!r}.".format(prefix, port_name, direction)
                )
    if not isinstance(cell.connections, dict):
        errors.append("{} connections must be a dictionary.".format(prefix))
    else:
        for conn_name, bits in cell.connections.items():
            if not isinstance(conn_name, str):
                errors.append("{} connection key {!r} must be a string.".format(prefix, conn_name))
            _validate_bits("{} connection {}".format(prefix, conn_name), bits, errors)


def _validate_netname(module_name, netname, errors):
    prefix = "module {} netname {}".format(module_name, netname.name)
    _validate_optional_int("{} hide_name".format(prefix), netname.hide_name, errors)
    _validate_bits("{} bits".format(prefix), netname.bits, errors)
    _validate_optional_int("{} offset".format(prefix), netname.offset, errors)
    _validate_optional_int("{} upto".format(prefix), netname.upto, errors)
    _validate_optional_int("{} signed".format(prefix), netname.signed, errors)
    _validate_attr_map("{} attributes".format(prefix), netname.attributes, errors)


def _validate_memory(module_name, memory, errors):
    prefix = "module {} memory {}".format(module_name, memory.name)
    _validate_optional_int("{} hide_name".format(prefix), memory.hide_name, errors)
    _validate_optional_int("{} width".format(prefix), memory.width, errors)
    _validate_optional_int("{} start_offset".format(prefix), memory.start_offset, errors)
    _validate_optional_int("{} size".format(prefix), memory.size, errors)
    _validate_attr_map("{} attributes".format(prefix), memory.attributes, errors)


def _validate_module(module, errors):
    if not isinstance(module.name, str):
        errors.append("Module name must be a string.")
    _validate_attr_map("module {} attributes".format(module.name), module.attributes, errors)
    _validate_attr_map(
        "module {} parameter_default_values".format(module.name), module.parameter_default_values, errors
    )
    for port in module.ports.values():
        _validate_port(module.name, port, errors)
    for cell in module.cells.values():
        _validate_cell(module.name, cell, errors)
    for netname in module.netnames.values():
        _validate_netname(module.name, netname, errors)
    for memory in module.memories.values():
        _validate_memory(module.name, memory, errors)


def collect_design_errors(design):
    errors = []
    if design.creator is not None and not isinstance(design.creator, str):
        errors.append("design creator must be a string when present.")
    if not isinstance(design.modules, dict):
        errors.append("design modules must be a dictionary.")
        return errors
    for module_name, module in design.modules.items():
        if module_name != module.name:
            errors.append(
                "design module dictionary key {!r} does not match module name {!r}.".format(
                    module_name, module.name
                )
            )
        _validate_module(module, errors)
    if not isinstance(design.models, dict):
        errors.append("design models must be a dictionary when present.")
    return errors


def validate_design(design):
    errors = collect_design_errors(design)
    if errors:
        raise ValidationError(errors)
