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
SELECT count(*) AS captures_before FROM sources.captures \gset
SELECT count(*) AS publications_before FROM governance.publications \gset
SELECT to_jsonb(s) AS intake_before FROM editorial.intake_settings s \gset
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT gen_random_uuid() AS rkey \gset
SELECT editorial.register_community_source('{"name":"Public source","source_kind":"directory","homepage":"https://example.invalid/source"}',:'rkey')->>'source_id' AS source \gset
SELECT pg_temp.assert_true(editorial.register_community_source('{"source_kind":"directory","name":"Public source","homepage":"https://example.invalid/source"}',:'rkey')->>'source_id'=:'source','source request replay');
SELECT pg_temp.expect_error(format('SELECT editorial.register_community_source(%L,%L)','{"name":"Changed source","source_kind":"directory"}',:'rkey'),'40001','request_key_conflict');
SELECT pg_temp.expect_error($$SELECT editorial.register_community_source('{"name":"Source","source_kind":"directory","raw_text":"private input"}',gen_random_uuid())$$,'22023','invalid_source_metadata');
SELECT pg_temp.expect_error($$SELECT editorial.register_community_source('{"name":null,"source_kind":"directory"}',gen_random_uuid())$$,'22023','invalid_source_metadata');
SELECT pg_temp.expect_error($$SELECT editorial.register_community_source('{"name":"Source","source_kind":"directory","code":"injected"}',gen_random_uuid())$$,'22023','invalid_source_metadata');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM governance.community_source_admissions WHERE source_id=:'source'),'registration is not admission');
SELECT pg_temp.expect_error(format('SELECT editorial.admit_community_source(%L,%L)',:'source','Allowed by moderator'),'42501','admin_required');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-admin','UTF8')),'hex'));
SELECT editorial.admit_community_source(:'source','Reviewed source metadata') AS admission \gset
SELECT pg_temp.assert_true(editorial.admit_community_source(:'source','Repeated request preserves original')=:'admission'::jsonb,'admission replay retains immutable decision');
SELECT pg_temp.expect_error(format('SELECT editorial.admit_community_source(%L,%L)',gen_random_uuid(),'Unknown source'),'P0002','source_not_found');
SELECT pg_temp.expect_error(format('SELECT editorial.admit_community_source(%L,%L)',:'source',' '),'22023','source_admission_reason_required');
SELECT pg_temp.expect_error(format('DELETE FROM governance.community_source_admissions WHERE source_id=%L',:'source'),'42501');
COMMIT;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT code='community-'||source_id::text AND license IS NULL FROM sources.registry WHERE source_id=:'source'),'server-allocated code and no invented license');
SELECT pg_temp.assert_true((SELECT count(*) FROM sources.captures)=:'captures_before' AND
 (SELECT count(*) FROM governance.publications)=:'publications_before' AND
 (SELECT to_jsonb(s) FROM editorial.intake_settings s)=:'intake_before'::jsonb,'registration/admission preserve captures, publications and visitor settings');
SELECT pg_temp.expect_error(format('UPDATE governance.community_source_admissions SET reason=%L WHERE source_id=%L','Changed',:'source'),'55000','immutable_record');
SELECT pg_temp.expect_error(format('DELETE FROM editorial.community_source_requests WHERE request_key=%L',:'rkey'),'55000','immutable_record');
TRUNCATE editorial.community_source_requests,governance.community_source_admissions;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DROP ROLE egi_probe_preparation;
