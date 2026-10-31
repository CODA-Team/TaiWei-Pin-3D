import sys
import unittest
from pathlib import Path


STAGE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STAGE_DIR))

from primary_port_contract import annotate_primary_alias_groups


def entry(label, direction, bit):
    return {"bit_label": label, "direction": direction, "bit": bit}


class PrimaryPortAliasContractTest(unittest.TestCase):
    def test_one_pi_may_drive_multiple_po_aliases(self):
        entries = [
            entry("clk_i", "input", 10),
            entry("clk_o0", "output", 10),
            entry("clk_o1", "output", 10),
            entry("clk_o2", "output", 10),
        ]
        groups = annotate_primary_alias_groups(entries)
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["kind"], "PI_TO_PO")
        self.assertEqual(groups[0]["canonical_bit_label"], "clk_i")
        self.assertEqual(groups[0]["alias_bit_labels"], ["clk_o0", "clk_o1", "clk_o2"])
        self.assertTrue(all(item["canonical_bit_label"] == "clk_i" for item in entries))

    def test_existing_po_alias_group_remains_supported(self):
        entries = [entry("y0", "output", 12), entry("y1", "output", 12)]
        groups = annotate_primary_alias_groups(entries)
        self.assertEqual(groups[0]["kind"], "PO_TO_PO")
        self.assertEqual(entries[1]["canonical_bit_label"], "y0")

    def test_multiple_pi_aliases_are_rejected(self):
        entries = [
            entry("a", "input", 4),
            entry("b", "input", 4),
            entry("y", "output", 4),
        ]
        with self.assertRaisesRegex(AssertionError, "exactly one primary input"):
            annotate_primary_alias_groups(entries)

    def test_inout_alias_is_rejected(self):
        entries = [entry("pad", "inout", 5), entry("pad_o", "output", 5)]
        with self.assertRaisesRegex(AssertionError, "must not alias"):
            annotate_primary_alias_groups(entries)

    def test_unaliased_inout_is_accepted(self):
        entries = [entry("pad", "inout", 5)]
        groups = annotate_primary_alias_groups(entries)
        self.assertEqual(groups, [])
        self.assertEqual(entries[0]["alias_group_kind"], "single")


if __name__ == "__main__":
    unittest.main()
