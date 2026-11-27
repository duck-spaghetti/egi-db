#!/bin/sh
# Two independent preparations compete for one installation-wide USD 10 balance.
set -eu
: "${PGHOST:?Explicit disposable PGHOST required}"
: "${PGDATABASE:?Explicit disposable PGDATABASE required}"
PSQL=${EGI_PSQL:-/Library/PostgreSQL/18/bin/psql}
case "$PGHOST:$PGDATABASE" in /private/tmp/egi-*:egi_contract|/private/tmp/egi.*:egi_contract) ;; *) echo 'Disposable egi_contract required' >&2; exit 1 ;; esac
"$PSQL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE egi_probe_budget_desk LOGIN IN ROLE egi_editorial;
CREATE ROLE egi_probe_budget_worker LOGIN IN ROLE egi_preparation_worker;
INSERT INTO governance.actors(display_name,database_role) VALUES('Budget fixture',NULL) RETURNING actor_id AS actor \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES(:'actor','prep-budget','moderator','active') RETURNING account_id AS account \gset
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
 VALUES(:'account',repeat('b',64),'oidc',true,clock_timestamp()+interval '1 day');
INSERT INTO sources.registry(code,name,source_kind) VALUES('budget-'||gen_random_uuid(),'Budget source','fixture') RETURNING source_id AS source \gset
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,
 cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('budget-fixture','{"fixture_only":true}',3000000,3000000,1000000,500000,1000000,clock_timestamp(),'fixture only');
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('budget-fixture',true);
INSERT INTO preparation.budget_periods(period_start) VALUES(date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date);
SET SESSION AUTHORIZATION egi_probe_budget_desk;
BEGIN;
SELECT access.verify_session(repeat('b',64));
SELECT preparation.create_workspace(:'source','Budget one',gen_random_uuid())->>'id' AS ws1 \gset
SELECT preparation.create_workspace(:'source','Budget two',gen_random_uuid())->>'id' AS ws2 \gset
SELECT preparation.put_input(:'ws1',1,'text',convert_to('First source text','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp1 \gset
SELECT preparation.put_input(:'ws2',1,'text',convert_to('Second source text','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp2 \gset
SELECT preparation.request_interpretation(:'ws1',:'inp1','extract_text',gen_random_uuid());
SELECT preparation.request_interpretation(:'ws2',:'inp2','extract_text',gen_random_uuid());
COMMIT;
SET SESSION AUTHORIZATION egi_probe_budget_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS first \gset
SELECT preparation.claim_job(gen_random_uuid()) AS second \gset
RESET SESSION AUTHORIZATION;
CREATE TABLE preparation.contract_budget_race(n integer PRIMARY KEY,job uuid,secret text);
INSERT INTO preparation.contract_budget_race VALUES(1,(:'first'::jsonb->>'job_id')::uuid,:'first'::jsonb->>'lease'),
 (2,(:'second'::jsonb->>'job_id')::uuid,:'second'::jsonb->>'lease');
GRANT SELECT ON preparation.contract_budget_race TO egi_probe_budget_worker;
SQL
EGI_BUDGET_TMP=$(mktemp -d /private/tmp/egi-budget-race.XXXXXX)
trap 'rm -f "$EGI_BUDGET_TMP/first" "$EGI_BUDGET_TMP/second"; rmdir "$EGI_BUDGET_TMP"' EXIT
"$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_BUDGET_TMP/first" 2>&1 <<'SQL' &
BEGIN;
SELECT 1 FROM preparation.budget_periods FOR UPDATE;
SELECT pg_advisory_xact_lock(1162303812,103);
SET SESSION AUTHORIZATION egi_probe_budget_worker;
SELECT preparation.start_dispatch(job,secret) FROM preparation.contract_budget_race WHERE n=1;
SELECT pg_sleep(2);
COMMIT;
SQL
EGI_BUDGET_FIRST=$!
EGI_BUDGET_ATTEMPTS=0
while [ "$("$PSQL" -X -At -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1162303812 AND objid=103 AND granted")" = 0 ]; do
 EGI_BUDGET_ATTEMPTS=$((EGI_BUDGET_ATTEMPTS+1))
 if [ "$EGI_BUDGET_ATTEMPTS" -gt 50 ]; then echo 'Budget lock not observed' >&2; exit 1; fi
 sleep 0.1
done
"$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_BUDGET_TMP/second" 2>&1 <<'SQL'
SET SESSION AUTHORIZATION egi_probe_budget_worker;
SELECT preparation.start_dispatch(job,secret) FROM preparation.contract_budget_race WHERE n=2;
SQL
wait "$EGI_BUDGET_FIRST"
if ! rg -q 'budget_exceeded' "$EGI_BUDGET_TMP/second"; then cat "$EGI_BUDGET_TMP/second"; exit 1; fi
"$PSQL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
\ir tests/contract/helpers.sql
SELECT pg_temp.assert_true((SELECT count(*) FROM preparation.jobs WHERE state='running')=1,'exactly one dispatch');
SELECT pg_temp.assert_true((SELECT reserved_microusd=6000000 AND committed_microusd=0 FROM preparation.budget_periods),'concurrent reservations respect USD 10 cap');
DROP TABLE preparation.contract_budget_race;
TRUNCATE preparation.workspaces,preparation.ai_configurations,preparation.budget_periods CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (SELECT actor_id FROM access.accounts WHERE login_name='prep-budget');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name='prep-budget');
WITH gone AS (DELETE FROM access.accounts WHERE login_name='prep-budget' RETURNING actor_id)
 DELETE FROM governance.actors WHERE actor_id IN (SELECT actor_id FROM gone);
DROP ROLE egi_probe_budget_desk,egi_probe_budget_worker;
SQL
printf '%s\n' 'Concurrent independent jobs: one USD 6 reservation, one budget refusal, no overspend.'
