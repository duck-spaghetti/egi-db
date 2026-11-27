"""Own database verification and keep native SQL distinct from Sqitch registry checks."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from devtools_source import source


def main(argv=None):
    """Run selected owning checks; pinned-tool/runtime gaps remain explicitly blocked."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("quick", "complete", "integration"), default="complete")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        source(root)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"schema_version": 1, "repository": "database", "profile": args.profile,
                          "status": "blocked", "reason": "Pinned developer tools unavailable: " + type(error).__name__}))
        return 2
    from devchecks.report import Check, exit_code, report
    from devchecks.resources import run_check as run, preflight, PrerequisiteError
    checks = []
    names = [line.split()[0] for line in (root / "sqitch.plan").read_text().splitlines() if line[:3].isdigit()]
    missing = [str(Path(phase) / (name + ".sql")) for name in names for phase in ("deploy", "verify", "revert")
               if not (root / phase / (name + ".sql")).is_file()]
    checks.append(Check("plan-triplets", "failed" if missing or not names else "passed", ",".join(missing)))
    if args.profile != "quick":
        try:
            capacity = preflight()
            checks.append(Check('resource-preflight', 'passed',
                                'WARNING below30 GiB: ' + str(capacity) if capacity['warning'] else str(capacity)))
        except (OSError, PrerequisiteError) as error:
            checks.append(Check('resource-preflight', 'blocked', str(error)))
            result = report('database', args.profile, root, checks)
            print(json.dumps(result, indent=2))
            return exit_code(result)
        native = run("native-plan-contracts", [sys.executable, root / "scripts/native_disposable.py"], root, timeout=600)
        if native.status == "passed":
            native.reason = "Actual isolated SQL/concurrency/revert/redeploy; .local/native-last.log"
        checks.append(native)
        sqitch = os.environ.get("EGI_SQITCH") or shutil.which("sqitch")
        probe = run("sqitch-prerequisite", [sqitch, "--version"], root) if sqitch else Check("sqitch-prerequisite", "blocked", "Set the selected EGI_SQITCH runtime")
        if probe.status != "passed":
            probe.status = "blocked"
            checks.append(probe)
        else:
            environment = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
            checks.append(run("sqitch-registry-lifecycle", [sys.executable, root / "scripts/sqitch_disposable.py"], root, timeout=600, environment=environment))
    result = report("database", args.profile, root, checks)
    print(json.dumps(result, indent=2) if args.json else f"database {args.profile}: {result['status']}")
    return exit_code(result)


if __name__ == "__main__":
    raise SystemExit(main())
