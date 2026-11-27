#!/bin/sh
# Two verified people submit one immutable item version; attribution stays first.
set -eu
: "${PGHOST:?Explicit disposable PGHOST required}"
: "${PGDATABASE:?Explicit disposable PGDATABASE required}"
PSQL=${EGI_PSQL:-/Library/PostgreSQL/18/bin/psql}
case "$PGHOST:$PGDATABASE" in /private/tmp/egi-*:egi_contract|/private/tmp/egi.*:egi_contract) ;; *) echo 'Disposable egi_contract required' >&2; exit 1 ;; esac
"$PSQL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE egi_probe_submission_desk LOGIN IN ROLE egi_editorial;
INSERT INTO governance.actors(display_name,database_role) VALUES('Submission owner',NULL) RETURNING actor_id AS owner \gset
INSERT INTO governance.actors(display_name,database_role) VALUES('Submission editor',NULL) RETURNING actor_id AS editor \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES(:'owner','prep-submit-owner','moderator','active'),(:'editor','prep-submit-editor','moderator','active');
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
 SELECT account_id,CASE WHEN actor_id=:'owner' THEN repeat('c',64) ELSE repeat('d',64) END,'oidc',true,clock_timestamp()+interval '1 day'
 FROM access.accounts WHERE actor_id IN (:'owner',:'editor');
INSERT INTO sources.registry(code,name,source_kind) VALUES('submission-'||gen_random_uuid(),'Submission source','fixture') RETURNING source_id AS source \gset
SET SESSION AUTHORIZATION egi_probe_submission_desk;
BEGIN;
SELECT access.verify_session(repeat('c',64));
SELECT preparation.create_workspace(:'source','Shared preparation',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Sportello','UTF8'),'false',gen_random_uuid())->>'input_id' AS inp \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS item, :'created'::jsonb->'items'->0->>'version_id' AS blank \gset
SELECT preparation.read_item(:'ws',:'item',NULL)->'version'->'payload' AS payload \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'blank',
 'payload',jsonb_set(jsonb_set(:'payload'::jsonb,'{service}','{"name":"Sportello"}'),'{outcome}','"confirmed"')||
 jsonb_build_object('schema_version',2,'source_facts',jsonb_build_array(jsonb_build_object('fact_id',gen_random_uuid(),'subject','service','kind','category_label','source_value','Sportello','value','Sportello')),
 'resolutions','[]'::jsonb,'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value','input_id',:'inp',
 'input_hash',encode(sha256(convert_to('Sportello','UTF8')),'hex'),'kind','stated','quote','Sportello','span',jsonb_build_object('start',0,'end',9)))))),gen_random_uuid()) AS saved \gset
SELECT :'saved'::jsonb->'items'->0->>'after' AS expected \gset
SELECT preparation.set_grant(:'ws',:'editor','edit',2,gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
CREATE TABLE preparation.contract_submission_race(workspace uuid,item uuid,expected uuid,owner uuid);
INSERT INTO preparation.contract_submission_race VALUES(:'ws',:'item',:'expected',:'owner');
GRANT SELECT ON preparation.contract_submission_race TO egi_probe_submission_desk;
SQL
EGI_SUBMIT_TMP=$(mktemp -d /private/tmp/egi-submit-race.XXXXXX)
trap 'rm -f "$EGI_SUBMIT_TMP/first" "$EGI_SUBMIT_TMP/second"; rmdir "$EGI_SUBMIT_TMP"' EXIT
"$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_SUBMIT_TMP/first" 2>&1 <<'SQL' &
SET SESSION AUTHORIZATION egi_probe_submission_desk;
BEGIN;
SELECT access.verify_session(repeat('c',64));
SELECT preparation.submit_item(workspace,item,expected,gen_random_uuid()) FROM preparation.contract_submission_race;
SELECT pg_advisory_xact_lock(1162303812,105);
SELECT pg_sleep(2);
COMMIT;
SQL
EGI_SUBMIT_FIRST=$!
EGI_SUBMIT_ATTEMPTS=0
while [ "$("$PSQL" -X -At -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1162303812 AND objid=105 AND granted")" = 0 ]; do
 EGI_SUBMIT_ATTEMPTS=$((EGI_SUBMIT_ATTEMPTS+1))
 if [ "$EGI_SUBMIT_ATTEMPTS" -gt 50 ]; then echo 'Submission lock not observed' >&2; exit 1; fi
 sleep 0.1
done
"$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_SUBMIT_TMP/second" 2>&1 <<'SQL'
SET SESSION AUTHORIZATION egi_probe_submission_desk;
BEGIN;
SELECT access.verify_session(repeat('d',64));
SELECT preparation.submit_item(workspace,item,expected,gen_random_uuid()) FROM preparation.contract_submission_race;
COMMIT;
SQL
wait "$EGI_SUBMIT_FIRST"
if ! rg -q 'already_submitted' "$EGI_SUBMIT_TMP/second"; then cat "$EGI_SUBMIT_TMP/second"; exit 1; fi
# Now both editors save the same v2 head: only the first corrected fact may win.
"$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_SUBMIT_TMP/first" 2>&1 <<'SQL' &
SET SESSION AUTHORIZATION egi_probe_submission_desk;
BEGIN;
SELECT access.verify_session(repeat('c',64));
SELECT preparation.save_items(workspace,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',expected,'payload',
 jsonb_set(jsonb_set(preparation.read_item(workspace,item,NULL)#>'{version,payload}','{source_facts,0,value}','"First correction"'),
 '{field_origins}','{"/source_facts/0/value":{"state":"manual"}}'))),gen_random_uuid()) FROM preparation.contract_submission_race;
SELECT pg_advisory_xact_lock(1162303812,106);
SELECT pg_sleep(2);
COMMIT;
SQL
EGI_SUBMIT_FIRST=$!
EGI_SUBMIT_ATTEMPTS=0
while [ "$("$PSQL" -X -At -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1162303812 AND objid=106 AND granted")" = 0 ]; do
 EGI_SUBMIT_ATTEMPTS=$((EGI_SUBMIT_ATTEMPTS+1))
 if [ "$EGI_SUBMIT_ATTEMPTS" -gt 50 ]; then echo 'Fact save lock not observed' >&2; exit 1; fi
 sleep 0.1
done
if "$PSQL" -X -At -v ON_ERROR_STOP=1 >"$EGI_SUBMIT_TMP/second" 2>&1 <<'SQL'
SET SESSION AUTHORIZATION egi_probe_submission_desk;
BEGIN;
SELECT access.verify_session(repeat('d',64));
SELECT preparation.save_items(workspace,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',expected,'payload',
 jsonb_set(jsonb_set(preparation.read_item(workspace,item,NULL)#>'{version,payload}','{source_facts,0,value}','"Second correction"'),
 '{field_origins}','{"/source_facts/0/value":{"state":"manual"}}'))),gen_random_uuid()) FROM preparation.contract_submission_race;
COMMIT;
SQL
then echo 'Concurrent stale v2 save unexpectedly succeeded' >&2; exit 1; fi
wait "$EGI_SUBMIT_FIRST"
if ! rg -q 'item_version_conflict' "$EGI_SUBMIT_TMP/second"; then cat "$EGI_SUBMIT_TMP/second"; exit 1; fi
"$PSQL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
\ir tests/contract/helpers.sql
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.community_snapshots)=1,'one snapshot under concurrent submission');
SELECT pg_temp.assert_true((SELECT submitted_by=(SELECT owner FROM preparation.contract_submission_race) FROM editorial.community_snapshots),'first actor preserved');
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.events WHERE action='submitted')=1,'one submitted event');
SELECT pg_temp.assert_true((SELECT values#>>'{source_facts,0,value}'='Sportello' FROM editorial.community_snapshots),'immutable v2 snapshot keeps original fact');
SELECT pg_temp.assert_true((SELECT payload#>>'{source_facts,0,value}'='First correction' FROM preparation.item_versions v JOIN preparation.items i ON i.current_version_id=v.id),'stale v2 editor cannot overwrite first correction');
DROP TABLE preparation.contract_submission_race;
TRUNCATE editorial.community_snapshots CASCADE;
DELETE FROM editorial.events;
DELETE FROM editorial.proposals;
DELETE FROM editorial.contributions;
TRUNCATE preparation.workspaces CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (SELECT actor_id FROM access.accounts WHERE login_name LIKE 'prep-submit-%');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-submit-%');
WITH gone AS (DELETE FROM access.accounts WHERE login_name LIKE 'prep-submit-%' RETURNING actor_id)
 DELETE FROM governance.actors WHERE actor_id IN (SELECT actor_id FROM gone);
DROP ROLE egi_probe_submission_desk;
SQL
printf '%s\n' 'Concurrent submitters received one immutable contribution with first submitter attribution.'
