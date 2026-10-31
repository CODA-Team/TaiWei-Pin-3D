from collections import OrderedDict, defaultdict


SUPPORTED_DIRECTIONS = {"input", "output", "inout"}


def annotate_primary_alias_groups(entries):
    groups_by_bit = defaultdict(list)
    for entry in entries:
        direction = entry.get("direction")
        if direction not in SUPPORTED_DIRECTIONS:
            raise AssertionError(
                "Unsupported primary port direction {} for {}".format(
                    direction, entry.get("bit_label")
                )
            )
        bit = entry.get("bit")
        entry["alias_group_kind"] = "single"
        entry["canonical_bit_label"] = entry["bit_label"]
        if isinstance(bit, int):
            groups_by_bit[bit].append(entry)

    groups = []
    for bit, items in sorted(groups_by_bit.items()):
        if len(items) == 1:
            continue
        directions = {item["direction"] for item in items}
        labels = [item["bit_label"] for item in items]
        if "inout" in directions:
            raise AssertionError(
                "Inout primary bit must not alias another primary port: bit {} used by {}".format(
                    bit, labels
                )
            )
        if directions == {"output"}:
            canonical = items[0]
            kind = "PO_TO_PO"
        elif directions == {"input", "output"}:
            inputs = [item for item in items if item["direction"] == "input"]
            if len(inputs) != 1:
                raise AssertionError(
                    "PI-to-PO alias requires exactly one primary input: bit {} used by {}".format(
                        bit, labels
                    )
                )
            canonical = inputs[0]
            kind = "PI_TO_PO"
        else:
            raise AssertionError(
                "Unsupported primary bit alias directions {} for bit {} used by {}".format(
                    sorted(directions), bit, labels
                )
            )
        canonical_label = canonical["bit_label"]
        aliases = []
        for item in items:
            item["alias_group_kind"] = kind
            item["canonical_bit_label"] = canonical_label
            if item is not canonical:
                aliases.append(item["bit_label"])
        groups.append(
            OrderedDict(
                [
                    ("source_bit", bit),
                    ("kind", kind),
                    ("canonical_bit_label", canonical_label),
                    ("alias_bit_labels", aliases),
                ]
            )
        )
    return groups
