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
SET SESSION AUTHORIZATION egi_probe_preparation;
SELECT pg_temp.expect_error('SELECT preparation.list_workspaces(false)','42501','session_required');
SELECT pg_temp.expect_error('SELECT * FROM preparation.inputs','42501');
SELECT pg_temp.expect_error('SELECT preparation.actor()','42501');
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT gen_random_uuid() AS create_key \gset
SELECT preparation.create_workspace(:'src','My preparation',:'create_key')->>'id' AS ws \gset
SELECT pg_temp.assert_true(preparation.create_workspace(:'src','My preparation',:'create_key')->>'id'=:'ws','create replay');
SELECT pg_temp.expect_error(format('SELECT preparation.create_workspace(%L,%L,%L)',:'src','Changed title',:'create_key'),'40001','request_key_conflict');
SELECT preparation.create_workspace(:'src','Other preparation',gen_random_uuid())->>'id' AS other_ws \gset
SELECT gen_random_uuid() AS input_key \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to(chr(65279)||'Sportello 🧭'||chr(13)||chr(10)||'Roma','UTF8'),'true',:'input_key')->>'input_id' AS inp \gset
SELECT pg_temp.assert_true(preparation.put_input(:'ws',1,'text',convert_to(chr(65279)||'Sportello 🧭'||chr(13)||chr(10)||'Roma','UTF8'),'true',:'input_key')->>'input_id'=:'inp','input replay before expected revision check');
SELECT pg_temp.assert_true(decode(preparation.read_input(:'ws',:'inp')->>'original_base64','base64')=
 convert_to(chr(65279)||'Sportello 🧭'||chr(13)||chr(10)||'Roma','UTF8'),'exact BOM/UTF8/CRLF bytes round trip');
SELECT pg_temp.expect_error(format('SELECT preparation.put_input(%L,1,%L,convert_to(%L,%L),%L,gen_random_uuid())',:'ws','text','Other text','UTF8','false'),'40001','metadata_conflict');
SELECT gen_random_uuid() AS card_key \gset
SELECT gen_random_uuid() AS creation_key \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',:'creation_key')),:'card_key') AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS card, :'created'::jsonb->'items'->0->>'version_id' AS v1 \gset
SELECT pg_temp.assert_true(preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',:'creation_key')),gen_random_uuid())=:'created'::jsonb,'stable manual creation key beyond request key');
SELECT pg_temp.expect_error(format('SELECT preparation.read_input(%L,%L)',:'other_ws',:'inp'),'P0002','input_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.read_item(%L,%L,NULL)',:'other_ws',:'card'),'P0002','item_not_found');
SELECT preparation.read_item(:'ws',:'card',NULL)->'version'->'payload' AS blank \gset
SELECT jsonb_set(jsonb_set(:'blank'::jsonb,'{service}',jsonb_build_object('name','Sportello 🧭','delivery_mode','telephone',
 'contacts',jsonb_build_array(jsonb_build_object('channel_type','phone','value','061234','is_public',true)))),
 '{evidence}',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/service/name','input_id',:'inp',
 'input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','kind','stated','span',jsonb_build_object('start',0,'end',11),'quote','Sportello 🧭'))) AS filled \gset
SELECT gen_random_uuid() AS save_key \gset
SELECT jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v1','payload',:'filled'::jsonb)) AS changes \gset
SELECT preparation.save_items(:'ws',:'changes',:'save_key') AS saved \gset
SELECT :'saved'::jsonb->'items'->0->>'after' AS v2 \gset
SELECT pg_temp.assert_true(preparation.save_items(:'ws',:'changes',:'save_key')=:'saved'::jsonb,'save replay');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',:'v1')->'version'->'payload'=:'blank'::jsonb,'old version retained');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',NULL)->'version'->'payload'=:'filled'::jsonb,'complete editable payload retained');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',:'changes'),'40001','item_version_conflict');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(
 jsonb_build_object('item_id',:'card','expected_version',:'v2','payload',jsonb_set(:'filled'::jsonb,'{evidence,0,quote}','"wrong"')))),'22023','evidence_quote_mismatch');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(
 jsonb_build_object('item_id',:'card','expected_version',:'v2','payload',jsonb_set(:'filled'::jsonb,'{service,typo}','"wrong"')))),'22023','invalid_preparation_shape');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(
 jsonb_build_object('item_id',:'card','expected_version',:'v2','payload',:'blank'::jsonb),
 jsonb_build_object('item_id',gen_random_uuid(),'expected_version',:'v1','payload',:'blank'::jsonb))),'P0002','item_not_found');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',NULL)->'version'->>'id'=:'v2','bulk failure rolls back every card');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(
 jsonb_build_object('item_id',:'card','expected_version',:'v2','payload',jsonb_set(:'filled'::jsonb,'{service,name}','"Changed without removing citation"')))),'22023','citation_value_conflict');
SELECT pg_temp.expect_error(format('SELECT preparation.put_input(%L,2,%L,convert_to(repeat(%L,50001),%L),%L,gen_random_uuid())',:'ws','text','a','UTF8','false'),'22023','text_too_large');
SELECT pg_temp.expect_error(format('SELECT preparation.put_input(%L,2,%L,decode(%L,%L),%L,gen_random_uuid())',:'ws','text','ff','hex','false'),'22021');
SELECT preparation.set_grant(:'ws',:'reader','read',2,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-admin','UTF8')),'hex'));
SELECT pg_temp.assert_true(preparation.list_workspaces(false)='[]','uninvited Admin list empty');
SELECT pg_temp.expect_error(format('SELECT preparation.read_workspace(%L)',:'ws'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.read_input(%L,%L)',:'ws',:'inp'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.read_item(%L,%L,%L)',:'ws',:'card',:'v1'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,%L)',:'ws',:'changes',:'save_key'),'P0002','preparation_not_found');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.assert_true(jsonb_array_length(preparation.list_workspaces(false))=1,'shared workspace listed');
SELECT pg_temp.assert_true(preparation.read_workspace(:'ws')->>'permission'='read','read grant');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',NULL)->'version'->'payload'=:'filled'::jsonb,'reader sees complete card');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',:'changes'),'42501','preparation_permission_denied');
SELECT pg_temp.expect_error(format('SELECT preparation.set_grant(%L,%L,%L,3,gen_random_uuid())',:'ws',:'admin','read'),'42501','preparation_permission_denied');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader','edit',3,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v2','payload',jsonb_set(jsonb_set(:'filled'::jsonb,'{service,name}','"Edited"'),'{evidence}','[]'))),gen_random_uuid());
SELECT pg_temp.expect_error(format('SELECT preparation.set_grant(%L,%L,%L,4,gen_random_uuid())',:'ws',:'admin','read'),'42501','preparation_permission_denied');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader',NULL,4,gen_random_uuid());
SELECT preparation.set_grant(:'other_ws',:'reader','edit',1,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.read_workspace(%L)',:'ws'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.read_item(%L,%L,%L)',:'ws',:'card',:'v1'),'P0002','preparation_not_found');
COMMIT;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.expect_error(format('UPDATE preparation.inputs SET original_bytes=convert_to(%L,%L) WHERE id=%L','changed','UTF8',:'inp'),'55000','preparation_immutable');
SELECT pg_temp.expect_error(format('DELETE FROM preparation.item_versions WHERE id=%L',:'v1'),'55000','preparation_immutable');
-- Owner deactivation freezes edits, including those by previously invited people.
UPDATE access.accounts SET state='deactivated' WHERE actor_id=:'owner';
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.assert_true(jsonb_array_length(preparation.list_workspaces(false))=1,'only explicitly shared preparation remains readable');
SELECT pg_temp.expect_error(format('SELECT preparation.put_input(%L,2,%L,convert_to(%L,%L),%L,gen_random_uuid())',:'other_ws','text','frozen','UTF8','false'),'55000','preparation_inactive');
COMMIT;
RESET SESSION AUTHORIZATION;
-- Test cleanup only. Application/retention roles have no TRUNCATE privilege.
TRUNCATE preparation.workspaces CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
-- The registered source is immutable retained fixture metadata, as in contract 14.
DROP ROLE egi_probe_preparation;
