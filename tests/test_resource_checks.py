"""Exercise blocked resource prerequisites through the public database check command."""
from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceCheckTests(unittest.TestCase):
    """Check that resource and provider prerequisites cannot be reported as passing."""

    def test_low_space_blocks_before_allocating(self):
        """The public native profile reports blocked without creating a run or cluster."""
        code = '''from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0,'scripts')
from devtools_source import source
source(Path.cwd())
from devchecks.resources import PrerequisiteError
import importlib.util
spec=importlib.util.spec_from_file_location('database_checks',Path.cwd()/'scripts/check.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
main=m.main
with patch('devchecks.resources.preflight',side_effect=PrerequisiteError('controlled below15 GiB')), patch('devchecks.resources.ResourceRun.__init__',side_effect=AssertionError('must not allocate')):
    raise SystemExit(main(['--profile','complete','--json']))
'''
        result = subprocess.run([sys.executable, '-c', code], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual([x['name'] for x in report['checks']], ['plan-triplets', 'resource-preflight'])

    def test_missing_provider_is_blocked(self):
        """An absent identified checkout never falls back to an unverified module."""
        result = subprocess.run([sys.executable, ROOT / 'scripts/check.py', '--profile', 'quick', '--json'],
                                cwd=ROOT, env={**os.environ, 'EGI_DEVTOOLS_SOURCE': '/private/tmp/egi-provider-not-present'},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['status'], 'blocked')

    def test_shutdown_failure_cannot_pass_the_owning_profile(self):
        """A failed supervised stage stays failed at the command consumed by CI."""
        code = '''from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0,'scripts')
from devtools_source import source
source(Path.cwd())
from devchecks.report import Check
import importlib.util
spec=importlib.util.spec_from_file_location('database_checks',Path.cwd()/'scripts/check.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def stage(name,*args,**kwargs):
    return Check(name,'failed' if name=='native-plan-contracts' else 'passed','controlled shutdown failure')
with patch('devchecks.resources.run_check',side_effect=stage):
    raise SystemExit(m.main(['--profile','complete','--json']))
'''
        result = subprocess.run([sys.executable, '-c', code], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(any(item['name'] == 'native-plan-contracts' and item['status'] == 'failed'
                            for item in report['checks']))

    def test_hook_git_environment_cannot_redirect_provider(self):
        """Inherited Git hook variables cannot make pin verification read another repository."""
        actual = subprocess.check_output(['git','rev-parse','--absolute-git-dir'],cwd=ROOT,text=True).strip()
        result = subprocess.run([sys.executable, ROOT/'scripts/check.py','--profile','quick','--json'],
                                cwd=ROOT,env={**os.environ,'GIT_DIR':actual},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
