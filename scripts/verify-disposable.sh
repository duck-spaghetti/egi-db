#!/bin/sh
# Reproduce integrated #10 acceptance on a newly created disposable cluster.
set -eu
EGI_PG_BIN=${EGI_PG_BIN:-/Library/PostgreSQL/18/bin}
EGI_SQITCH=${EGI_SQITCH:-sqitch}
command -v "$EGI_SQITCH" >/dev/null || { echo 'Set EGI_SQITCH to the installed Sqitch executable' >&2; exit 1; }
case "$("$EGI_PG_BIN/postgres" --version)" in
  'postgres (PostgreSQL) 18.'*) ;;
  *) echo 'PostgreSQL 18 is required for this checkpoint' >&2; exit 1 ;;
esac
EGI_CLUSTER=$(mktemp -d /private/tmp/egi-contract.XXXXXX)
EGI_STARTED=0
cleanup() {
  if [ "$EGI_STARTED" = 1 ]; then "$EGI_PG_BIN/pg_ctl" -D "$EGI_CLUSTER/data" -m fast -w stop >/dev/null; fi
  case "$EGI_CLUSTER" in /private/tmp/egi-contract.*) rm -rf "$EGI_CLUSTER" ;; esac
}
trap cleanup EXIT HUP INT TERM
"$EGI_PG_BIN/initdb" -D "$EGI_CLUSTER/data" -A trust --no-locale --encoding=UTF8 >/dev/null
printf "\nlisten_addresses = ''\nunix_socket_directories = '%s'\nport = 65432\n" "$EGI_CLUSTER" >>"$EGI_CLUSTER/data/postgresql.conf"
"$EGI_PG_BIN/pg_ctl" -D "$EGI_CLUSTER/data" -l "$EGI_CLUSTER/server.log" -w start >/dev/null
EGI_STARTED=1
export PGHOST="$EGI_CLUSTER" PGPORT=65432 PGDATABASE=egi_contract
export EGI_PSQL="$EGI_PG_BIN/psql"
"$EGI_PG_BIN/createdb" "$PGDATABASE"
"$EGI_SQITCH" --version
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -c "SELECT current_database(),current_setting('data_directory') AS data_directory,current_setting('port') AS port,inet_server_addr() AS tcp_address,version();"
"$EGI_SQITCH" deploy --to 003_governance --db-client "$EGI_PSQL" db:pg:egi_contract
for EGI_CHECK in tests/contract/01-foundation.sql tests/contract/02-evidence.sql tests/contract/03-canonical.sql tests/contract/04-publication.sql; do
  "$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f "$EGI_CHECK"
done
"$EGI_SQITCH" deploy --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" verify --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f tests/contract/00-clean.sql
for EGI_CHECK in tests/contract/01-foundation.sql tests/contract/02-evidence.sql tests/contract/03-canonical.sql tests/contract/04-publication.sql tests/contract/05-hours.sql tests/contract/06-calendar.sql tests/contract/07-taxonomy.sql tests/contract/08-translations.sql tests/contract/09-directory.sql tests/contract/10-integrated.sql tests/contract/11-sync.sql tests/contract/12-hardening.sql tests/contract/13-access.sql tests/contract/14-editorial.sql tests/contract/15-revision-body.sql tests/contract/16-editorial-observations.sql tests/contract/17-preparations.sql tests/contract/18-preparation-history.sql tests/contract/19-community-sources.sql; do
  "$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f "$EGI_CHECK"
done
sh tests/contract/05-concurrency.sh
"$EGI_SQITCH" revert -y --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" deploy --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" verify --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f tests/contract/00-clean.sql
for EGI_CHECK in tests/contract/01-foundation.sql tests/contract/02-evidence.sql tests/contract/03-canonical.sql tests/contract/04-publication.sql tests/contract/05-hours.sql tests/contract/06-calendar.sql tests/contract/07-taxonomy.sql tests/contract/08-translations.sql tests/contract/09-directory.sql tests/contract/10-integrated.sql tests/contract/11-sync.sql tests/contract/12-hardening.sql tests/contract/13-access.sql tests/contract/14-editorial.sql tests/contract/15-revision-body.sql tests/contract/16-editorial-observations.sql tests/contract/17-preparations.sql tests/contract/18-preparation-history.sql tests/contract/19-community-sources.sql; do
  "$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f "$EGI_CHECK"
done
sh tests/contract/05-concurrency.sh
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -c "SELECT postgis_full_version();"
printf '%s\n' 'Checkpoint #10: fresh deploy, structural verify, SQL contracts, concurrency and revert/redeploy passed.'
