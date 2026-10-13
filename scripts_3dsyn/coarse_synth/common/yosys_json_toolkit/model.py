"""Typed in-memory model for Yosys JSON netlists.

The field names intentionally match the JSON structure used by Yosys so the toolkit stays easy to
cross-check against `read_json` / `write_json`.
"""

from copy import deepcopy
from typing import Any, Dict, List, Optional, Union

JsonBit = Union[int, str]
JsonMap = Dict[str, Any]


class Port(object):
    __slots__ = ("name", "direction", "bits", "offset", "upto", "signed", "extras")

    def __init__(self, name, direction, bits, offset=None, upto=None, signed=None, extras=None):
        self.name = name
        self.direction = direction
        self.bits = list(bits)
        self.offset = offset
        self.upto = upto
        self.signed = signed
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, name, data):
        known = {"direction", "bits", "offset", "upto", "signed"}
        return cls(
            name=name,
            direction=data["direction"],
            bits=list(data["bits"]),
            offset=data.get("offset"),
            upto=data.get("upto"),
            signed=data.get("signed"),
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {"direction": self.direction}
        if self.offset is not None:
            data["offset"] = self.offset
        if self.upto is not None:
            data["upto"] = self.upto
        if self.signed is not None:
            data["signed"] = self.signed
        data["bits"] = list(self.bits)
        data.update(deepcopy(self.extras))
        return data


class Cell(object):
    __slots__ = (
        "name",
        "hide_name",
        "type",
        "parameters",
        "attributes",
        "port_directions",
        "connections",
        "extras",
    )

    def __init__(
        self,
        name,
        hide_name,
        cell_type,
        parameters=None,
        attributes=None,
        port_directions=None,
        connections=None,
        extras=None,
    ):
        self.name = name
        self.hide_name = hide_name
        self.type = cell_type
        self.parameters = parameters or {}
        self.attributes = attributes or {}
        self.port_directions = port_directions or {}
        self.connections = connections or {}
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, name, data):
        known = {
            "hide_name",
            "type",
            "parameters",
            "attributes",
            "port_directions",
            "connections",
        }
        return cls(
            name=name,
            hide_name=data.get("hide_name"),
            cell_type=data["type"],
            parameters=deepcopy(data.get("parameters", {})),
            attributes=deepcopy(data.get("attributes", {})),
            port_directions=deepcopy(data.get("port_directions", {})),
            connections={key: list(value) for key, value in data.get("connections", {}).items()},
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {
            "hide_name": self.hide_name if self.hide_name is not None else 0,
            "type": self.type,
            "parameters": deepcopy(self.parameters),
            "attributes": deepcopy(self.attributes),
        }
        if self.port_directions:
            data["port_directions"] = deepcopy(self.port_directions)
        data["connections"] = {key: list(bits) for key, bits in self.connections.items()}
        data.update(deepcopy(self.extras))
        return data


class Netname(object):
    __slots__ = ("name", "hide_name", "bits", "attributes", "offset", "upto", "signed", "extras")

    def __init__(self, name, hide_name, bits, attributes=None, offset=None, upto=None, signed=None, extras=None):
        self.name = name
        self.hide_name = hide_name
        self.bits = list(bits)
        self.attributes = attributes or {}
        self.offset = offset
        self.upto = upto
        self.signed = signed
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, name, data):
        known = {"hide_name", "bits", "attributes", "offset", "upto", "signed"}
        return cls(
            name=name,
            hide_name=data.get("hide_name"),
            bits=list(data["bits"]),
            attributes=deepcopy(data.get("attributes", {})),
            offset=data.get("offset"),
            upto=data.get("upto"),
            signed=data.get("signed"),
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {"hide_name": self.hide_name if self.hide_name is not None else 0, "bits": list(self.bits)}
        if self.offset is not None:
            data["offset"] = self.offset
        if self.upto is not None:
            data["upto"] = self.upto
        if self.signed is not None:
            data["signed"] = self.signed
        data["attributes"] = deepcopy(self.attributes)
        data.update(deepcopy(self.extras))
        return data


class Memory(object):
    __slots__ = ("name", "hide_name", "attributes", "width", "start_offset", "size", "extras")

    def __init__(self, name, hide_name, attributes=None, width=None, start_offset=None, size=None, extras=None):
        self.name = name
        self.hide_name = hide_name
        self.attributes = attributes or {}
        self.width = width
        self.start_offset = start_offset
        self.size = size
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, name, data):
        known = {"hide_name", "attributes", "width", "start_offset", "size"}
        return cls(
            name=name,
            hide_name=data.get("hide_name"),
            attributes=deepcopy(data.get("attributes", {})),
            width=data.get("width"),
            start_offset=data.get("start_offset"),
            size=data.get("size"),
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {
            "hide_name": self.hide_name if self.hide_name is not None else 0,
            "attributes": deepcopy(self.attributes),
        }
        if self.width is not None:
            data["width"] = self.width
        if self.start_offset is not None:
            data["start_offset"] = self.start_offset
        if self.size is not None:
            data["size"] = self.size
        data.update(deepcopy(self.extras))
        return data


class Module(object):
    __slots__ = (
        "name",
        "attributes",
        "parameter_default_values",
        "ports",
        "cells",
        "memories",
        "netnames",
        "extras",
    )

    def __init__(
        self,
        name,
        attributes=None,
        parameter_default_values=None,
        ports=None,
        cells=None,
        memories=None,
        netnames=None,
        extras=None,
    ):
        self.name = name
        self.attributes = attributes or {}
        self.parameter_default_values = parameter_default_values or {}
        self.ports = ports or {}
        self.cells = cells or {}
        self.memories = memories or {}
        self.netnames = netnames or {}
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, name, data):
        known = {
            "attributes",
            "parameter_default_values",
            "ports",
            "cells",
            "memories",
            "netnames",
        }
        return cls(
            name=name,
            attributes=deepcopy(data.get("attributes", {})),
            parameter_default_values=deepcopy(data.get("parameter_default_values", {})),
            ports={key: Port.from_dict(key, value) for key, value in data.get("ports", {}).items()},
            cells={key: Cell.from_dict(key, value) for key, value in data.get("cells", {}).items()},
            memories={key: Memory.from_dict(key, value) for key, value in data.get("memories", {}).items()},
            netnames={key: Netname.from_dict(key, value) for key, value in data.get("netnames", {}).items()},
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {"attributes": deepcopy(self.attributes)}
        if self.parameter_default_values:
            data["parameter_default_values"] = deepcopy(self.parameter_default_values)
        data["ports"] = {key: port.to_dict() for key, port in self.ports.items()}
        data["cells"] = {key: cell.to_dict() for key, cell in self.cells.items()}
        if self.memories:
            data["memories"] = {key: memory.to_dict() for key, memory in self.memories.items()}
        data["netnames"] = {key: netname.to_dict() for key, netname in self.netnames.items()}
        data.update(deepcopy(self.extras))
        return data

    def copy(self):
        return deepcopy(self)


class Design(object):
    __slots__ = ("creator", "modules", "models", "extras")

    def __init__(self, creator=None, modules=None, models=None, extras=None):
        self.creator = creator
        self.modules = modules or {}
        self.models = models or {}
        self.extras = extras or {}

    @classmethod
    def from_dict(cls, data):
        known = {"creator", "modules", "models"}
        return cls(
            creator=data.get("creator"),
            modules={key: Module.from_dict(key, value) for key, value in data.get("modules", {}).items()},
            models=deepcopy(data.get("models", {})),
            extras={key: deepcopy(value) for key, value in data.items() if key not in known},
        )

    def to_dict(self):
        data = {}
        if self.creator is not None:
            data["creator"] = self.creator
        data["modules"] = {key: module.to_dict() for key, module in self.modules.items()}
        if self.models:
            data["models"] = deepcopy(self.models)
        data.update(deepcopy(self.extras))
        return data

    def copy(self):
        return deepcopy(self)

    def get_module(self, name):
        return self.modules[name]
