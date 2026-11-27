"""Verify plan SQL and contracts on an owned PostgreSQL cluster without Sqitch claims."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def verify():
    """Deploy/verify/revert/redeploy and run discovered contracts on private sockets."""
    binary = Path(os.environ.get("EGI_PG_BIN", "/Library/PostgreSQL/18/bin"))
    version = subprocess.check_output([binary / "postgres", "--version"], text=True)
    if not version.startswith("postgres (PostgreSQL) 18."):
        raise RuntimeError("Selected PostgreSQL18 prerequisite unavailable")
    cluster = Path(tempfile.mkdtemp(prefix="egi-devcheck-", dir="/private/tmp"))
    data = cluster / "data"
    environment = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    environment.update(PGHOST=str(cluster), PGPORT="65432", PGDATABASE="egi_contract", EGI_PSQL=str(binary / "psql"))
    names = [line.split()[0] for line in (ROOT / "sqitch.plan").read_text().splitlines()
             if re.match(r"^[0-9]{3}_", line)]
    (ROOT / ".local").mkdir(exist_ok=True)
    try:
        with (ROOT / ".local/native-last.log").open("w") as log:
            def command(*args):
                """Execute only the selected binaries against this owned fixture environment."""
                subprocess.run([str(item) for item in args], env=environment, cwd=ROOT,
                               stdout=log, stderr=subprocess.STDOUT, timeout=180, check=True)

            command(binary / "initdb", "-D", data, "-A", "trust", "--no-locale", "--encoding=UTF8")
            with (data / "postgresql.conf").open("a") as config:
                config.write(f"\nlisten_addresses=''\nunix_socket_directories='{cluster}'\nport=65432\n")
            command(binary / "pg_ctl", "-D", data, "-l", cluster / "server.log", "-w", "start")
            command(binary / "createdb", "egi_contract")
            identity = subprocess.check_output([binary / "psql", "-XAt", "-c",
                "SELECT current_database()||'|'||current_setting('data_directory')||'|'||COALESCE(inet_server_addr()::text,'socket')"],
                env=environment, text=True).strip()
            if identity != "egi_contract|" + str(data) + "|socket":
                raise RuntimeError("Owned fixture identity mismatch")
            log.write(identity + "\n"); log.flush()

            def sql(path):
                """Apply one actual owning plan/contract file with failure-on-error."""
                command(binary / "psql", "-X", "-v", "ON_ERROR_STOP=1", "-f", path)

            def contracts():
                """Discover SQL and concurrent checks once, excluding the cleanup from test order."""
                sql(ROOT / "tests/contract/00-clean.sql")
                for path in sorted((ROOT / "tests/contract").glob("[0-9][0-9]-*.sql")):
                    if path.name != "00-clean.sql":
                        sql(path)
                for path in sorted((ROOT / "tests/contract").glob("[0-9][0-9]-*.sh")):
                    command("sh", path)

            for name in names:
                sql(ROOT / "deploy" / (name + ".sql"))
            for name in names:
                sql(ROOT / "verify" / (name + ".sql"))
            contracts()
            for name in reversed(names):
                sql(ROOT / "revert" / (name + ".sql"))
            for name in names:
                sql(ROOT / "deploy" / (name + ".sql"))
            for name in names:
                sql(ROOT / "verify" / (name + ".sql"))
            contracts()
            log.write("PASS isolated native SQL and discovered contracts/concurrency; not Sqitch registry evidence\n")
    finally:
        pid = data / "postmaster.pid"
        if pid.exists() and pid.read_text().splitlines()[1] == str(data):
            subprocess.run([binary / "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"],
                           capture_output=True, check=True, timeout=30)
        shutil.rmtree(cluster)


if __name__ == "__main__":
    verify()
