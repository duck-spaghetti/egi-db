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
with patch('devchecks.resources.preflight',side_effect=PrerequisiteError('controlled below15 GiB')):
    raise SystemExit(main(['--profile','complete','--json']))
'''
        before = set(Path('/private/tmp').glob('egi-resource-*'))
        result = subprocess.run([sys.executable, '-c', code], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual([x['name'] for x in report['checks']], ['plan-triplets', 'resource-preflight'])
        self.assertEqual(set(Path('/private/tmp').glob('egi-resource-*')) - before, set())

    def test_missing_provider_is_blocked(self):
        """An absent identified checkout never falls back to an unverified module."""
        result = subprocess.run([sys.executable, ROOT / 'scripts/check.py', '--profile', 'quick', '--json'],
                                cwd=ROOT, env={**os.environ, 'EGI_DEVTOOLS_SOURCE': '/private/tmp/egi-provider-not-present'},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['status'], 'blocked')

    def test_hook_git_environment_cannot_redirect_provider(self):
        """Inherited Git hook variables cannot make pin verification read another repository."""
        actual = subprocess.check_output(['git','rev-parse','--absolute-git-dir'],cwd=ROOT,text=True).strip()
        result = subprocess.run([sys.executable, ROOT/'scripts/check.py','--profile','quick','--json'],
                                cwd=ROOT,env={**os.environ,'GIT_DIR':actual},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
