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
CREATE ROLE egi_probe_preparation_retention LOGIN IN ROLE egi_retention;
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','History fixture',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Original text','UTF8'),'false',gen_random_uuid())->>'input_id' AS inp \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS card, :'created'::jsonb->'items'->0->>'version_id' AS v1 \gset
SELECT preparation.read_item(:'ws',:'card',NULL)->'version'->'payload' AS blank \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v1','payload',jsonb_set(:'blank'::jsonb,'{service,name}','"Edited"'))),gen_random_uuid()) AS saved \gset
SELECT :'saved'::jsonb->>'operation_id' AS edit_op \gset
SELECT gen_random_uuid() AS undo_key \gset
SELECT preparation.undo_operation(:'ws',:'edit_op',:'undo_key') AS undone \gset
SELECT :'undone'::jsonb->'items'->0->>'after' AS v3 \gset
SELECT pg_temp.assert_true(preparation.undo_operation(:'ws',:'edit_op',:'undo_key')=:'undone'::jsonb,'undo retry stable');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',NULL)->'version'->'payload'=:'blank'::jsonb,'compensating version restores content');
SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_history(:'ws',:'card',0,2)->'versions')=2
 AND (preparation.read_history(:'ws',:'card',0,2)->>'has_more')::boolean,'bounded history first page');
SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_history(:'ws',:'card',2,2)->'versions')=1,'history second page');
SELECT pg_temp.expect_error(format('SELECT preparation.read_history(%L,%L,0,101)',:'ws',:'card'),'22023','invalid_history_page');
SELECT pg_temp.expect_error(format('SELECT preparation.undo_operation(%L,%L,gen_random_uuid())',:'ws',:'edit_op'),'40001','undo_head_conflict');
SELECT preparation.set_grant(:'ws',:'reader','read',2,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_history(:'ws',:'card',0,100)->'versions')=3,'reader sees versions');
SELECT pg_temp.expect_error(format('SELECT preparation.undo_operation(%L,%L,gen_random_uuid())',:'ws',:'edit_op'),'42501','preparation_permission_denied');
SELECT pg_temp.expect_error(format('SELECT preparation.trash_workspace(%L,3,gen_random_uuid())',:'ws'),'42501','preparation_permission_denied');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT gen_random_uuid() AS trash_key \gset
SELECT preparation.trash_workspace(:'ws',3,:'trash_key') AS trashed \gset
SELECT pg_temp.assert_true(preparation.trash_workspace(:'ws',3,:'trash_key')=:'trashed'::jsonb,'trash receipt replays while trashed');
SELECT pg_temp.assert_true(preparation.list_workspaces(false)='[]' AND jsonb_array_length(preparation.list_workspaces(true))=1,'trash list filter');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v3','payload',:'blank'::jsonb))),'55000','preparation_inactive');
SELECT preparation.restore_workspace(:'ws',4,gen_random_uuid());
SELECT preparation.set_grant(:'ws',:'reader','edit',5,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v3','payload',jsonb_set(:'blank'::jsonb,'{outcome}','"trash"'))),gen_random_uuid()) AS item_trash \gset
SELECT :'item_trash'::jsonb->'items'->0->>'after' AS v4 \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v4','payload',:'blank'::jsonb)),gen_random_uuid()) AS restored_card \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'card',NULL)->'version'->>'outcome'='review','editor restores card during recovery window');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'restored_card'::jsonb->'items'->0->>'after','payload',jsonb_set(:'blank'::jsonb,'{outcome}','"trash"'))),gen_random_uuid()) AS trashed_again \gset
SELECT :'trashed_again'::jsonb->'items'->0->>'after' AS v4 \gset
SELECT pg_temp.expect_error(format('SELECT preparation.trash_workspace(%L,6,gen_random_uuid())',:'ws'),'42501','preparation_permission_denied');
COMMIT;
RESET SESSION AUTHORIZATION;
-- Controlled timestamps, never a caller-supplied production clock.
UPDATE preparation.items SET trashed_at=clock_timestamp()-interval '29 days' WHERE id=:'card';
SET SESSION AUTHORIZATION egi_probe_preparation_retention;
SELECT pg_temp.assert_true((preparation.purge_trash()->>'items')::integer=0,'29 day item retained');
RESET SESSION AUTHORIZATION;
UPDATE preparation.items SET trashed_at=clock_timestamp()-interval '30 days' WHERE id=:'card';
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'v4','payload',:'blank'::jsonb))),'55000','item_restore_expired');
SELECT pg_temp.expect_error('SELECT preparation.purge_trash()','42501');
COMMIT;
SET SESSION AUTHORIZATION egi_probe_preparation_retention;
SELECT pg_temp.assert_true((preparation.purge_trash()->>'items')::integer=1,'expired item purged');
SELECT pg_temp.expect_error('SELECT * FROM preparation.inputs','42501');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.inputs WHERE id=:'inp'),'current original remains for active preparation');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid());
SELECT preparation.trash_workspace(:'ws',6,gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
UPDATE preparation.workspaces SET trashed_at=clock_timestamp()-interval '30 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.restore_workspace(%L,7,gen_random_uuid())',:'ws'),'55000','preparation_restore_expired');
COMMIT;
SET SESSION AUTHORIZATION egi_probe_preparation_retention;
SELECT pg_temp.assert_true((preparation.purge_trash()->>'workspaces')::integer=1,'expired preparation purged');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.inputs WHERE workspace_id=:'ws')
 AND NOT EXISTS(SELECT FROM preparation.item_versions),'raw originals and private card derivatives removed');
SELECT pg_temp.assert_true((SELECT state='purged' AND title='Deleted' AND current_input_id IS NULL FROM preparation.workspaces WHERE id=:'ws'),'minimal inaccessible tombstone');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.read_workspace(%L)',:'ws'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.restore_workspace(%L,8,gen_random_uuid())',:'ws'),'P0002','preparation_not_found');
COMMIT;
RESET SESSION AUTHORIZATION;
TRUNCATE preparation.workspaces CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DROP ROLE egi_probe_preparation,egi_probe_preparation_retention;
