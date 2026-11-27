#!/bin/sh
# SQL/registry contract sequence; invoked only with an owned cluster environment.
set -eu
"$EGI_SQITCH" --version
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -c "SELECT current_database(),current_setting('data_directory') AS data_directory,current_setting('port') AS port,inet_server_addr() AS tcp_address,version();"
"$EGI_SQITCH" deploy --to 003_governance --db-client "$EGI_PSQL" db:pg:egi_contract
for EGI_CHECK in tests/contract/01-foundation.sql tests/contract/02-evidence.sql tests/contract/03-canonical.sql tests/contract/04-publication.sql; do
  "$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f "$EGI_CHECK"
done
"$EGI_SQITCH" deploy --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" verify --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f tests/contract/00-clean.sql
case "${EGI_VERIFY_PHASE:?Owned verification phase required}" in
 contracts) ;;
 revert-redeploy)
"$EGI_SQITCH" revert -y --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" deploy --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_SQITCH" verify --db-client "$EGI_PSQL" db:pg:egi_contract
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f tests/contract/00-clean.sql
 ;;
 *) echo 'Unknown verification phase' >&2; exit 1 ;;
esac
for EGI_CHECK in tests/contract/[0-9][0-9]-*.sql; do
  [ "${EGI_CHECK##*/}" = "00-clean.sql" ] && continue
  [ -f "${EGI_CHECK%.sql}.sh" ] && continue
  "$EGI_PSQL" -X -v ON_ERROR_STOP=1 -f "$EGI_CHECK"
done
for EGI_CONCURRENT in tests/contract/[0-9][0-9]-*.sh; do
  sh "$EGI_CONCURRENT"
done
"$EGI_PSQL" -X -v ON_ERROR_STOP=1 -c "SELECT postgis_full_version();"
printf '%s\n' 'Checkpoint #10: fresh deploy, structural verify, SQL contracts, concurrency and revert/redeploy passed.'
