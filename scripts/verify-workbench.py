#!/usr/bin/env python3
"""Run native workbench contracts using an explicitly pinned resource owner.

No runtime dependency: this development check imports only verified tooling bytes
from the selected immutable checkout. Every command is bounded and every cluster
belongs to the active ResourceRun.
"""
import argparse
import hashlib
import importlib
import os
from pathlib import Path
import subprocess
import sys


def main():
    """Verify the external pin and run bounded native checks in owned resources."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--through", default="030_preparation_interpretations")
    parser.add_argument("--fixture", action="append", default=[])
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    tools = args.tools.resolve()
    head = subprocess.run(["git", "-C", str(tools), "rev-parse", "HEAD"], check=True,
                          capture_output=True, text=True, timeout=10).stdout.strip()
    if head != args.revision:
        raise RuntimeError("Resource checkout revision does not match pin")
    for relative in ("scripts/devchecks/__init__.py", "scripts/devchecks/resources.py",
                     "scripts/devchecks/report.py"):
        committed = subprocess.run(["git", "-C", str(tools), "show", f"{head}:{relative}"],
                                   check=True, capture_output=True, timeout=10).stdout
        actual = (tools / relative).read_bytes()
        if actual != committed:
            raise RuntimeError(f"Resource tooling differs from pin: {relative}")
        print(relative, hashlib.sha256(actual).hexdigest(), flush=True)
    sys.path.insert(0, str(tools / "scripts"))
    resources = importlib.import_module("devchecks.resources")
    pg = Path(os.environ.get("EGI_PG_BIN", "/Library/PostgreSQL/18/bin"))
    sqitch = os.environ["EGI_SQITCH"]
    subprocess.run([sqitch, "--version"], check=True, timeout=10)
    with resources.ResourceRun(repository).activate():
        with resources.OwnedCluster(repository, pg, database="egi_workbench") as cluster:
            environment = {**cluster.environment, "EGI_PSQL": str(pg / "psql")}

            def check(name, command):
                """Run one bounded stage and preserve its observed failure output."""
                result = resources.run_check(name, command, repository, timeout=180,
                                             environment=environment)
                print(name, result.status, result.reason, flush=True)
                if result.status != "passed":
                    raise RuntimeError(f"Native check failed: {name}")

            base = [sqitch, "--db-client", str(pg / "psql")]
            check("deploy", [*base, "deploy", "--to", args.through, "db:pg:egi_workbench"])
            check("verify", [*base, "verify", "--to", args.through, "db:pg:egi_workbench"])
            for fixture in args.fixture:
                check(fixture, [pg / "psql", "-X", "-v", "ON_ERROR_STOP=1", "-f", fixture])
            check("revert", [*base, "revert", "-y", "--to", "029_preparation_resolution_undo", "db:pg:egi_workbench"])
            check("redeploy", [*base, "deploy", "--to", args.through, "db:pg:egi_workbench"])
            check("reverify", [*base, "verify", "--to", args.through, "db:pg:egi_workbench"])
    print("Owned resource teardown passed", flush=True)


if __name__ == "__main__":
    main()
