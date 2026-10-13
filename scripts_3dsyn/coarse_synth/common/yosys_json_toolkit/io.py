"""JSON I/O helpers for the Yosys JSON model."""

import json
from pathlib import Path
from typing import TextIO, Union

from .model import Design


class JsonFormatError(ValueError):
    """Raised when the top-level JSON shape is not suitable for a Yosys design."""


PathLike = Union[str, Path]


def loads_design(text):
    data = json.loads(text)
    if not isinstance(data, dict):
        raise JsonFormatError("Yosys JSON root must be a dictionary.")
    if "modules" not in data or not isinstance(data["modules"], dict):
        raise JsonFormatError("Yosys JSON must contain a 'modules' dictionary.")
    return Design.from_dict(data)


def load_design(path):
    return loads_design(Path(path).read_text())


def load_design_fp(fp):
    data = json.load(fp)
    if not isinstance(data, dict):
        raise JsonFormatError("Yosys JSON root must be a dictionary.")
    if "modules" not in data or not isinstance(data["modules"], dict):
        raise JsonFormatError("Yosys JSON must contain a 'modules' dictionary.")
    return Design.from_dict(data)


def dumps_design(design, indent=2):
    return json.dumps(design.to_dict(), indent=indent)


def dump_design(design, path, indent=2):
    Path(path).write_text(dumps_design(design, indent=indent) + "\n")


def dump_design_fp(design, fp, indent=2):
    json.dump(design.to_dict(), fp, indent=indent)
    fp.write("\n")
