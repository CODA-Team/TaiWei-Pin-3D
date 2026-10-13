"""Load the TaiWei heterogeneous cell map into one canonical schema."""

import json
from collections import OrderedDict


def load_cell_map(path):
    with open(path) as fp:
        raw = json.load(fp)
    cells = raw.get("cells")
    assert isinstance(cells, dict) and cells, "map.json missing non-empty cells dictionary"

    normalized_cells = OrderedDict()
    for base_name, raw_entry in cells.items():
        assert isinstance(raw_entry, dict), "Invalid map.json entry for {}".format(base_name)
        bottom = raw_entry.get("bottom")
        upper = raw_entry.get("upper")
        assert isinstance(bottom, dict) and bottom.get("macro"), "Missing bottom macro for {}".format(base_name)
        assert isinstance(upper, dict) and upper.get("macro"), "Missing upper macro for {}".format(base_name)

        raw_base = raw_entry.get("base", base_name)
        if isinstance(raw_base, dict):
            assert raw_base.get("macro") == base_name, "Base macro mismatch for {}".format(base_name)
        else:
            assert raw_base == base_name, "Base name mismatch for {}".format(base_name)

        pin_map = raw_entry.get("pin_map")
        if pin_map is None:
            pin_map = upper.get("pin_map")
            bottom_pin_map = bottom.get("pin_map")
            assert isinstance(bottom_pin_map, dict), "Missing bottom pin_map for {}".format(base_name)
            signal_bottom_map = {
                pin: mapped
                for pin, mapped in bottom_pin_map.items()
                if pin not in {"VDD", "VSS", "VDDIO", "VSSIO"}
            }
            assert all(pin == mapped for pin, mapped in signal_bottom_map.items()), (
                "Bottom pin_map must preserve base pin names for {}".format(base_name)
            )
        assert isinstance(pin_map, dict), "Missing upper pin_map for {}".format(base_name)

        normalized_cells[base_name] = OrderedDict(
            [
                ("base", base_name),
                ("bottom", bottom),
                ("upper", upper),
                ("pin_map", pin_map),
            ]
        )

    normalized = OrderedDict(raw)
    normalized["cells"] = normalized_cells
    return normalized
