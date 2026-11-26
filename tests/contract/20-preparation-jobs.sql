-- EGI-100: private preparation access matrix, retained bytes, CAS and replay.
-- Synthetic accounts and data only; each verified actor has its own transaction.
\ir helpers.sql
CREATE ROLE egi_probe_preparation LOGIN IN ROLE egi_editorial;
INSERT INTO sources.registry(code,name,source_kind) VALUES('probe-preparation-'||gen_random_uuid(),'Source contact 06 1234567','directory') RETURNING source_id AS src \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Preparation owner') RETURNING actor_id AS owner \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Preparation reader') RETURNING actor_id AS reader \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Uninvited Admin') RETURNING actor_id AS admin \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES
 (:'owner','prep-owner','moderator','active'),(:'reader','prep-reader','moderator','active'),(:'admin','prep-admin','admin','active');
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
 SELECT account_id,encode(sha256(convert_to(login_name,'UTF8')),'hex'),'oidc',true,clock_timestamp()+interval '1 day'
 FROM access.accounts WHERE login_name LIKE 'prep-%';
CREATE ROLE egi_probe_jobs_worker LOGIN IN ROLE egi_preparation_worker;
CREATE ROLE egi_probe_jobs_worker2 LOGIN IN ROLE egi_preparation_worker;
CREATE ROLE egi_probe_jobs_retention LOGIN IN ROLE egi_retention;
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,
 input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('fixture-no-provider','{"fixture_only":true}',3000000,3000000,1000000,500000,1000000,clock_timestamp(),'synthetic fixture, no provider');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','AI fixture',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Sportello 06'||chr(160)||'1234567 privato@example.invalid','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp \gset
SELECT pg_temp.expect_error(format('SELECT preparation.request_interpretation(%L,%L,%L,gen_random_uuid())',:'ws',:'inp','extract_text'),'55000','ai_not_configured');
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS card, :'created'::jsonb->'items'->0->>'version_id' AS v1 \gset
SELECT preparation.read_item(:'ws',:'card',NULL)->'version'->'payload' AS blank \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v1',
 'payload',jsonb_set(:'blank'::jsonb,'{service}',jsonb_build_object('contacts',jsonb_build_array(
 jsonb_build_object('channel_type','phone','value','06 1234567','is_public',false),
 jsonb_build_object('channel_type','email','value','privato@example.invalid','is_public',false)))))),gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('fixture-no-provider',true);
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT gen_random_uuid() AS job_key \gset
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',:'job_key')->>'job_id' AS job \gset
SELECT pg_temp.assert_true(preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id'=:'job','coalesce identical active work');
SELECT pg_temp.expect_error('SELECT preparation.claim_job(gen_random_uuid())','42501');
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.expect_error('SELECT * FROM preparation.inputs','42501');
SELECT pg_temp.expect_error('SELECT * FROM preparation.jobs','42501');
SELECT pg_temp.expect_error(format('SELECT preparation.read_input(%L,%L)',:'ws',:'inp'),'42501');
SELECT pg_temp.expect_error('SELECT governance.current_actor()','42501');
SELECT preparation.claim_job(gen_random_uuid()) AS claim1 \gset
SELECT :'claim1'::jsonb->>'lease' AS lease1 \gset
SELECT pg_temp.assert_true(position('1234567' IN :'claim1'::jsonb#>>'{eligible_payload,text}')=0
 AND position('privato@example.invalid' IN :'claim1'::jsonb#>>'{eligible_payload,text}')=0,'private phones including NBSP and email removed before worker sees payload');
SELECT pg_temp.assert_true(position('1234567' IN :'claim1'::jsonb#>>'{eligible_payload,source_metadata,name}')=0,'source metadata receives the same private-contact filtering');
SELECT pg_temp.assert_true(length(:'claim1'::jsonb#>>'{eligible_payload,text}')=length('Sportello 06'||chr(160)||'1234567 privato@example.invalid'),'redaction preserves code-point offsets');
SELECT pg_temp.assert_true(preparation.claim_job(gen_random_uuid()) IS NULL,'one worker holds the only lease');
RESET SESSION AUTHORIZATION;
UPDATE preparation.jobs SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id=:'job';
SET SESSION AUTHORIZATION egi_probe_jobs_worker2;
SELECT preparation.claim_job(gen_random_uuid()) AS claim2 \gset
SELECT :'claim2'::jsonb->>'lease' AS lease2 \gset
SELECT pg_temp.assert_true(:'claim2'::jsonb->>'job_id'=:'job','expired pre-dispatch lease safely reclaimed');
SELECT pg_temp.expect_error(format('SELECT preparation.start_dispatch(%L,%L)',:'job',:'lease1'),'42501','job_lease_invalid');
SELECT preparation.start_dispatch(:'job',:'lease2') AS started \gset
SELECT :'started'::jsonb->>'dispatch_id' AS dispatch \gset
SELECT pg_temp.assert_true((:'started'::jsonb->>'ceiling_microusd')::bigint=6000000,'worst-case token ceiling reserved');
SELECT pg_temp.assert_true(preparation.heartbeat_job(:'job',:'lease2',:'dispatch'),'current dispatch heartbeat');
SELECT pg_temp.expect_error(format('SELECT preparation.start_dispatch(%L,%L)',:'job',:'lease2'),'55000','job_not_dispatchable');
SELECT jsonb_build_object('schema_version',1,'input_id',:'inp','input_hash',:'claim2'::jsonb#>>'{eligible_payload,input_hash}',
 'config_version','fixture-no-provider','state','complete','mapping',NULL,'diagnostics','[]'::jsonb,'candidates',jsonb_build_array(jsonb_build_object(
 'candidate_key','desk','service',jsonb_build_object('name','Sportello'),'location',jsonb_build_object('kind','none'),
 'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/service/name','input_id',:'inp',
 'input_hash',:'claim2'::jsonb#>>'{eligible_payload,input_hash}','kind','stated','span',jsonb_build_object('start',0,'end',9),'quote','Sportello')),'diagnostics','[]'::jsonb))) AS result \gset
SELECT jsonb_set(:'result'::jsonb,'{candidates}',(:'result'::jsonb->'candidates')||jsonb_build_array(
 jsonb_build_object('candidate_key','desk-update','service',jsonb_build_object('name','Sportello','description','Sportello','original_language','it'),
 'location',jsonb_build_object('kind','none'),'diagnostics','[]'::jsonb,'evidence',
 (:'result'::jsonb#>'{candidates,0,evidence}')||jsonb_build_array(jsonb_set(jsonb_set(:'result'::jsonb#>'{candidates,0,evidence,0}',
 '{path}','"/service/description"'),'{id}',to_jsonb(gen_random_uuid())))))) AS result \gset
SELECT '{"input_tokens":100,"output_tokens":50,"cached_input_tokens":0}' AS usage \gset
SELECT pg_temp.assert_true(preparation.finish_job(:'job',:'dispatch',:'lease2',:'result',:'usage')->>'state'='succeeded','verified result succeeds');
SELECT pg_temp.assert_true((preparation.finish_job(:'job',:'dispatch',:'lease2',:'result',:'usage')->>'settled')::boolean,'completion replay');
SELECT pg_temp.expect_error(format('SELECT preparation.finish_job(%L,%L,%L,%L,%L)',:'job',:'dispatch',:'lease2',:'result','{"input_tokens":101,"output_tokens":50,"cached_input_tokens":0}'),'40001','job_completion_conflict');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT committed_microusd=150 AND reserved_microusd=0 FROM preparation.budget_periods),'known usage settled exactly once');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT pg_temp.assert_true(preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id'=:'job','successful unchanged input reused');
SELECT preparation.read_job(:'ws',:'job')->'candidate_ids'->>'desk' AS cid \gset
SELECT preparation.create_items(:'ws',:'inp',:'job',jsonb_build_array(jsonb_build_object('candidate_id',:'cid')),gen_random_uuid()) AS selection_result \gset
SELECT :'selection_result'::jsonb->'items'->0->>'item_id' AS selected_card, :'selection_result'::jsonb->'items'->0->>'version_id' AS selected_v1 \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'selected_card',NULL)#>>'{version,payload,service,name}'='Sportello','selected candidate becomes editable private card');
SELECT preparation.read_item(:'ws',:'selected_card',NULL)->'version'->'payload' AS selected_payload \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'selected_card','expected_version',:'selected_v1',
 'payload',jsonb_set(jsonb_set(jsonb_set(:'selected_payload'::jsonb,'{service,name}','"Manual correction"'),'{evidence}','[]'),
 '{field_origins}',jsonb_build_object('/service/name',jsonb_build_object('state','manual'),'/service/description',jsonb_build_object('state','cleared'))))),gen_random_uuid());
SELECT preparation.create_items(:'ws',:'inp',:'job',jsonb_build_array(jsonb_build_object('candidate_id',:'cid')),gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'selected_card',NULL)#>>'{version,payload,service,name}'='Manual correction','repeated candidate selection never overwrites later manual edits');
SELECT preparation.read_job(:'ws',:'job')->'candidate_ids'->>'desk-update' AS update_cid \gset
SELECT preparation.read_item(:'ws',:'selected_card',NULL)->'version'->>'id' AS selected_manual_version \gset
SELECT preparation.create_items(:'ws',:'inp',:'job',jsonb_build_array(jsonb_build_object('candidate_id',:'update_cid',
 'target_item_id',:'selected_card','expected_version',:'selected_manual_version')),gen_random_uuid()) AS updated_selection \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'selected_card',NULL)#>>'{version,payload,service,name}'='Manual correction'
 AND NOT (preparation.read_item(:'ws',:'selected_card',NULL)#>'{version,payload,service}') ? 'description'
 AND preparation.read_item(:'ws',:'selected_card',NULL)#>>'{version,payload,service,original_language}'='it','explicit update preserves manual and cleared fields, applies untouched fields');
SELECT pg_temp.assert_true(jsonb_array_length(:'updated_selection'::jsonb#>'{items,0,conflicts}')=2,'preserved fields returned as visible conflicts');
SELECT preparation.put_input(:'ws',2,'text',convert_to('Second input','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp2 \gset
SELECT preparation.request_interpretation(:'ws',:'inp2','extract_text',gen_random_uuid())->>'job_id' AS job2 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim3 \gset
SELECT :'claim3'::jsonb->>'lease' AS lease3 \gset
SELECT preparation.start_dispatch(:'job2',:'lease3')->>'dispatch_id' AS dispatch2 \gset
RESET SESSION AUTHORIZATION;
UPDATE preparation.jobs SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id=:'job2';
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.assert_true(preparation.claim_job(gen_random_uuid()) IS NULL,'post-dispatch expired lease becomes uncertain rather than requeued');
SELECT pg_temp.assert_true(preparation.fail_job(:'job2',:'lease3','provider_timeout',true)->>'state'='uncertain','ambiguous timeout remains uncertain');
SELECT pg_temp.assert_true(preparation.claim_job(gen_random_uuid()) IS NULL,'uncertain dispatch never automatically claimed again');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT reserved_microusd=6000000 AND committed_microusd=150 FROM preparation.budget_periods),'uncertain reservation retained');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.request_interpretation(:'ws',:'inp2','extract_text',gen_random_uuid())->>'job_id' AS job3 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim4 \gset
SELECT :'claim4'::jsonb->>'lease' AS lease4 \gset
SELECT pg_temp.assert_true(preparation.start_dispatch(:'job3',:'lease4')->>'code'='budget_exceeded','outstanding reservation prevents overspend');
RESET SESSION AUTHORIZATION;
INSERT INTO preparation.budget_periods(period_start,reserved_microusd)
 SELECT (date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')-interval '1 month')::date,6000000;
UPDATE preparation.budget_periods SET reserved_microusd=0 WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date;
UPDATE preparation.budget_reservations SET period_start=(date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')-interval '1 month')::date WHERE job_id=:'job2';
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.trash_workspace(:'ws',3,gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
UPDATE preparation.workspaces SET trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe_jobs_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.inputs WHERE workspace_id=:'ws') AND
 (SELECT eligible_payload IS NULL AND locator_map IS NULL AND output IS NULL AND input_id IS NULL FROM preparation.jobs WHERE id=:'job2'),'purged private derivatives removed without dropping billing job');
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.assert_true(preparation.finish_job(:'job2',:'dispatch2',:'lease3','{}',:'usage')->>'state'='cancelled','late result only settles usage after purge');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT sum(committed_microusd)=300 AND sum(reserved_microusd)=0 FROM preparation.budget_periods),'late known usage settled in original period');
SELECT pg_temp.assert_true((SELECT output IS NULL AND eligible_payload IS NULL FROM preparation.jobs WHERE id=:'job2'),'late result cannot recreate purged content');
TRUNCATE preparation.workspaces,preparation.ai_configurations,preparation.budget_periods CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DROP ROLE egi_probe_preparation,egi_probe_jobs_worker,egi_probe_jobs_worker2,egi_probe_jobs_retention;
