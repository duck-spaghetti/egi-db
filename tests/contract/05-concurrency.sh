#!/bin/sh
# Use only the caller's explicit dedicated test target. PostgreSQL must be 18.
set -eu
: "${PGHOST:?Explicit disposable PGHOST required}"
: "${PGDATABASE:?Explicit disposable PGDATABASE required}"
PSQL=${EGI_PSQL:-/Library/PostgreSQL/18/bin/psql}
if [ "$PGDATABASE" != egi_contract ]; then
  echo 'Refusing concurrency fixture outside egi_contract' >&2; exit 1
fi
"$PSQL" -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
\ir tests/contract/fixtures.sql
SELECT pg_temp.save('service','{"name":"Concurrent baseline","description":"Concurrency fixture","delivery_mode":"telephone","contacts":[{"channel_type":"phone","value":"fixture phone"}]}') AS base
\gset
SELECT entity_id AS entity FROM governance.entity_revisions WHERE revision_id=:'base'
\gset
CREATE TABLE governance.contract_concurrency_fixture AS SELECT :'entity'::uuid AS entity,:'base'::uuid AS base;
COMMIT;
SQL
EGI_TMP=$(mktemp -d /private/tmp/egi-concurrency.XXXXXX)
trap 'rm -f "$EGI_TMP/first" "$EGI_TMP/second"; rmdir "$EGI_TMP"' EXIT
# First transaction holds the EGI mutation lock while the second approaches the same base.
"$PSQL" -X -v ON_ERROR_STOP=1 >"$EGI_TMP/first" 2>&1 <<'SQL' &
BEGIN;
SELECT pg_advisory_xact_lock(1162303812,1);
SELECT governance.save_revision('service',entity,base,NULL,'{"name":"First concurrent update","delivery_mode":"telephone"}','Concurrent fixture A') FROM governance.contract_concurrency_fixture;
SELECT pg_sleep(2);
COMMIT;
SQL
EGI_FIRST=$!
# Wait for the lock to become visible, not for a guessed startup delay.
EGI_ATTEMPTS=0
while [ "$("$PSQL" -X -At -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1162303812 AND objid=1 AND granted")" = 0 ]; do
  EGI_ATTEMPTS=$((EGI_ATTEMPTS+1))
  if [ "$EGI_ATTEMPTS" -gt 50 ]; then echo 'Mutation lock not observed' >&2; exit 1; fi
  sleep 0.1
done
if "$PSQL" -X -v ON_ERROR_STOP=1 >"$EGI_TMP/second" 2>&1 <<'SQL'
\set VERBOSITY verbose
SELECT governance.save_revision('service',entity,base,NULL,'{"name":"Stale concurrent update","delivery_mode":"telephone"}','Concurrent fixture B') FROM governance.contract_concurrency_fixture;
SQL
then echo 'Expected concurrent stale-base failure' >&2; exit 1; fi
wait "$EGI_FIRST"
if ! rg -q '40001: stale_base' "$EGI_TMP/second"; then cat "$EGI_TMP/second"; exit 1; fi
"$PSQL" -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DO $$ BEGIN
 IF (SELECT count(*) FROM governance.entity_revisions WHERE entity_id=(SELECT entity FROM governance.contract_concurrency_fixture))<>2 THEN RAISE EXCEPTION 'concurrent_revision_count'; END IF;
END $$;
DROP TABLE governance.contract_concurrency_fixture;
ROLLBACK;
SQL
printf '%s\n' 'Concurrent stale-base update rejected with 40001; exactly one new revision retained.'
