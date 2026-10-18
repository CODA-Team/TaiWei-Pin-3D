"""IO feedback handoff validation and collision-safe boundary assignment."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'scripts_openroad/io_feedback.tcl'


class IOFeedbackTests(unittest.TestCase):
    def run_tcl(self, body):
        script = 'source {' + str(HELPER) + '}\n' + body
        result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '', result.stderr)
        return result.stdout.strip()

    def test_colliding_targets_keep_order_spacing_and_bounds(self):
        output = self.run_tcl('''
set result [::pin3d_io_feedback::assign_slots {{a 0.99} {b 0.99} {c 0.99}} 10 1 2]
puts $result
''')
        self.assertEqual(output, '{a 5} {b 7} {c 9}')

    def test_edge_capacity_fails_instead_of_overlapping(self):
        self.assertEqual(self.run_tcl('''
puts [catch {::pin3d_io_feedback::assign_slots {{a 0} {b 0.3} {c 0.6} {d 1}} 4 1 1}]
'''), '1')

    def test_port_set_mismatch_and_duplicates_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'handoff.list'
            path.write_text('schema pin3d_io_feedback_v1\npin a left 0.5\n')
            self.assertEqual(self.run_tcl(f'puts [catch {{::pin3d_io_feedback::read_assignment {{{path}}} {{a b}}}}]'), '1')
            path.write_text('schema pin3d_io_feedback_v1\npin a left 0.5\npin a right 0.5\n')
            self.assertEqual(self.run_tcl(f'puts [catch {{::pin3d_io_feedback::read_assignment {{{path}}} {{a}}}}]'), '1')

    def test_bus_names_round_trip_as_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'handoff.list'
            path.write_text('schema pin3d_io_feedback_v1\npin {data[19]} left 0.5\n')
            self.assertEqual(self.run_tcl(f'puts [dict get [::pin3d_io_feedback::read_assignment {{{path}}} {{{{data[19]}}}}] {{data[19]}}]'), 'left 0.5')

    def test_negative_fraction_rejected(self):
        self.assertEqual(self.run_tcl('puts [catch {::pin3d_io_feedback::assign_slots {{a -0.1}} 10 1 1}]'), '1')


if __name__ == '__main__':
    unittest.main()
