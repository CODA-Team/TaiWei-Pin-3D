"""MMMC policy tests using Tcl stubs; no EDA license required."""
from pathlib import Path
import subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'scripts_cadence/mmmc_setup.tcl'
class RCPolicyTest(unittest.TestCase):
 def evaluate(self,mode,files):
  with tempfile.TemporaryDirectory() as d:
   sdc=Path(d)/'design.sdc';sdc.write_text('')
   qrc=Path(d)/'test.tch'
   if files:qrc.write_text('test fixture')
   tcl='''proc _get {name {default ""}} {if {[info exists ::env($name)] && $::env($name) ne ""} {return $::env($name)}; return $default}
proc create_library_set {args} {}
proc create_rc_corner {args} {puts "CORNER $args"}
proc create_delay_corner {args} {}
proc create_constraint_mode {args} {}
proc create_analysis_view {args} {}
set libworst fixture
set libbest fixture
'''+f'''set ::env(CDS_RC_MODE) {{{mode}}}
set qrc_max {{{qrc}}}
set qrc_min {{{qrc}}}
set sdc {{{sdc}}}
if {{[catch {{source {{{SCRIPT}}}}} message]}} {{puts stderr $message; exit 2}}
'''
   return subprocess.run(['tclsh'],input=tcl,text=True,capture_output=True)
 def test_missing_qrc_fails(self):
  r=self.evaluate('qrc',False);self.assertEqual(r.returncode,2);self.assertIn('Requested QRC',r.stderr);self.assertNotIn('CORNER',r.stdout)
 def test_explicit_lef_warns(self):
  r=self.evaluate('lef',False);self.assertEqual(r.returncode,0,r.stderr);self.assertIn('approximate LEF',r.stdout);self.assertNotIn('-qx_tech_file',r.stdout)
 def test_qrc_is_bound_to_both_corners(self):
  r=self.evaluate('qrc',True);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.count('-qx_tech_file'),2)
 def test_invalid_mode_fails(self):
  r=self.evaluate('typo',False);self.assertEqual(r.returncode,2);self.assertIn('must be qrc or lef',r.stderr)
if __name__=='__main__':unittest.main()
