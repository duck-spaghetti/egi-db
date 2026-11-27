"""Run the retained Sqitch registry contract sequence inside exact owned resources."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
from devtools_source import source

ROOT = Path(__file__).resolve().parents[1]
source(ROOT)
from devchecks.resources import OwnedCluster, ResourceRun, PrerequisiteError


def verify():
    """Preserve actual Sqitch deploy/verify/revert checks without shell-owned teardown."""
    binary = Path(os.environ.get('EGI_PG_BIN', '/Library/PostgreSQL/18/bin'))
    sqitch = os.environ.get('EGI_SQITCH') or shutil.which('sqitch')
    if not sqitch:
        raise PrerequisiteError('Set the selected EGI_SQITCH runtime')
    version = subprocess.check_output([binary / 'postgres', '--version'], text=True)
    if not version.startswith('postgres (PostgreSQL) 18.'):
        raise PrerequisiteError('PostgreSQL18 required')
    # Keep committed concurrency fixtures separate from clean structural reversion.
    for phase in ("contracts", "revert-redeploy"):
        with OwnedCluster(ROOT, binary, 65432, 'egi_contract') as cluster:
            environment = {**cluster.environment, 'EGI_VERIFY_PHASE': phase, 'EGI_SQITCH': str(sqitch), 'EGI_PSQL': str(binary / 'psql')}
            subprocess.run(['sh', ROOT / 'scripts/sqitch-contracts.sh'], cwd=ROOT,
                           env=environment, check=True, timeout=540)



if __name__ == '__main__':
    try:
        if ResourceRun.inherited():
            verify()
        else:
            with ResourceRun(ROOT).activate():
                verify()
    except PrerequisiteError as error:
        print(str(error))
        raise SystemExit(2)
