-- EGI-100: private preparation access matrix, retained bytes, CAS and replay.
-- Synthetic accounts and data only; each verified actor has its own transaction.
\ir helpers.sql
CREATE ROLE egi_probe_preparation LOGIN IN ROLE egi_editorial;
INSERT INTO sources.registry(code,name,source_kind) VALUES('probe-preparation-'||gen_random_uuid(),'Public test source','directory') RETURNING source_id AS src \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Preparation owner') RETURNING actor_id AS owner \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Preparation reader') RETURNING actor_id AS reader \gset
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Uninvited Admin') RETURNING actor_id AS admin \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES
 (:'owner','prep-owner','moderator','active'),(:'reader','prep-reader','moderator','active'),(:'admin','prep-admin','admin','active');
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
 SELECT account_id,encode(sha256(convert_to(login_name,'UTF8')),'hex'),'oidc',true,clock_timestamp()+interval '1 day'
 FROM access.accounts WHERE login_name LIKE 'prep-%';
CREATE ROLE egi_probe_jobs_worker LOGIN IN ROLE egi_preparation_worker;
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,
 cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('revocation-fixture','{"fixture_only":true}',1000,1000,1000000,500000,1000000,clock_timestamp(),'fixture only');
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('revocation-fixture',true);
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','Revocation fixture',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Sportello pubblico','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp \gset
SELECT preparation.set_grant(:'ws',:'reader','edit',2,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS job1 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_temp.expect_error('SELECT preparation.claim_job(gen_random_uuid())','22023','write_requires_read_committed');
ROLLBACK;
SELECT preparation.claim_job(gen_random_uuid()) AS claim1 \gset
SELECT :'claim1'::jsonb->>'lease' AS lease1 \gset
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader',NULL,3,gen_random_uuid());
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.assert_true(preparation.start_dispatch(:'job1',:'lease1')->>'state'='cancelled','revocation before dispatch cancels without reservation');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.budget_reservations),'no reserved cost before dispatch');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader','edit',4,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT gen_random_uuid() AS request_key \gset
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',:'request_key')->>'job_id' AS job2 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim2 \gset
SELECT :'claim2'::jsonb->>'lease' AS lease2 \gset
SELECT preparation.start_dispatch(:'job2',:'lease2')->>'dispatch_id' AS dispatch2 \gset
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader',NULL,5,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.read_job(%L,%L)',:'ws',:'job2'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.request_interpretation(%L,%L,%L,%L)',:'ws',:'inp','extract_text',:'request_key'),'P0002','preparation_not_found');
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT '{"input_tokens":2,"output_tokens":2,"cached_input_tokens":0}' AS usage \gset
SELECT pg_temp.assert_true(preparation.finish_job(:'job2',:'dispatch2',:'lease2','{}',:'usage')->>'state'='cancelled','revocation after dispatch blocks output while settling known usage');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS job3 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim3 \gset
SELECT :'claim3'::jsonb->>'lease' AS lease3 \gset
SELECT preparation.start_dispatch(:'job3',:'lease3')->>'dispatch_id' AS dispatch3 \gset
SELECT jsonb_build_object('schema_version',1,'input_id',:'inp','input_hash',:'claim3'::jsonb#>>'{eligible_payload,input_hash}',
 'config_version','revocation-fixture','state','complete','mapping',NULL,'diagnostics','[]'::jsonb,'candidates',jsonb_build_array(jsonb_build_object(
 'candidate_key','desk','service',jsonb_build_object('name','Sportello'),'location',jsonb_build_object('kind','none'),'diagnostics','[]'::jsonb,
 'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/service/name','input_id',:'inp',
 'input_hash',:'claim3'::jsonb#>>'{eligible_payload,input_hash}','kind','stated','span',jsonb_build_object('start',0,'end',9),'quote','Inventato'))))) AS false_result \gset
SELECT pg_temp.assert_true(preparation.finish_job(:'job3',:'dispatch3',:'lease3',:'false_result',:'usage')->>'state'='failed','fabricated quote never becomes a successful result');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT pg_temp.assert_true(preparation.read_job(:'ws',:'job3')->'output'='null'::jsonb,'invalid provider content not exposed as result');
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS job4 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim4 \gset
SELECT :'claim4'::jsonb->>'lease' AS lease4 \gset
SELECT preparation.start_dispatch(:'job4',:'lease4')->>'dispatch_id' AS dispatch4 \gset
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.cancel_job(:'ws',:'job4',gen_random_uuid());
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.fail_job(:'job4',:'lease4','provider_timeout',true);
RESET SESSION AUTHORIZATION;
UPDATE preparation.jobs SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id=:'job4';
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.assert_true(preparation.claim_job(gen_random_uuid()) IS NULL,'cancelled dispatch not requeued by lease recovery');
SELECT pg_temp.assert_true(NOT preparation.heartbeat_job(:'job4',:'lease4',:'dispatch4'),'heartbeat cannot resurrect cancellation');
SELECT pg_temp.assert_true(preparation.finish_job(:'job4',:'dispatch4',:'lease4','{}',:'usage')->>'state'='cancelled','late outcome preserves explicit cancellation');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT state='cancelled' AND output IS NULL AND cancelled_at IS NOT NULL FROM preparation.jobs WHERE id=:'job4'),'durable cancellation marker prevents resurrection');
SELECT pg_temp.assert_true((SELECT committed_microusd=12 AND reserved_microusd=0 FROM preparation.budget_periods),'invalid and cancelled outputs still accounted');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS job5 \gset
COMMIT;
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim5 \gset
SELECT :'claim5'::jsonb->>'lease' AS lease5 \gset
RESET SESSION AUTHORIZATION;
UPDATE access.accounts SET state='deactivated' WHERE actor_id=:'owner';
SET SESSION AUTHORIZATION egi_probe_jobs_worker;
SELECT pg_temp.assert_true(preparation.start_dispatch(:'job5',:'lease5')->>'state'='cancelled','deactivated owner blocks dispatch');
RESET SESSION AUTHORIZATION;
UPDATE access.accounts SET state='active' WHERE actor_id=:'owner';
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','Manual restricted material',gen_random_uuid())->>'id' AS private_ws \gset
SELECT preparation.put_input(:'private_ws',1,'text',convert_to('Restricted material','UTF8'),'false',gen_random_uuid())->>'input_id' AS private_inp \gset
SELECT pg_temp.expect_error(format('SELECT preparation.request_interpretation(%L,%L,%L,gen_random_uuid())',:'private_ws',:'private_inp','extract_text'),'22023','public_source_attestation_required');
SELECT preparation.create_items(:'private_ws',:'private_inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
TRUNCATE preparation.workspaces,preparation.ai_configurations,preparation.budget_periods CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DROP ROLE egi_probe_preparation,egi_probe_jobs_worker;
