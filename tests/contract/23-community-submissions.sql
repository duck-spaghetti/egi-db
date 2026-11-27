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
CREATE ROLE egi_probe_community_retention LOGIN IN ROLE egi_retention;
CREATE ROLE egi_probe_community_intake LOGIN IN ROLE egi_intake;
SELECT count(*) AS services_before FROM data.services \gset
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','Private source selection',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Sportello'||chr(10)||'UNSENT SIBLING PRIVATE VALUE','UTF8'),'false',gen_random_uuid())->>'input_id' AS inp \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS card, :'created'::jsonb->'items'->0->>'version_id' AS blank_version \gset
SELECT preparation.read_item(:'ws',:'card',NULL)->'version'->'payload' AS blank \gset
SELECT jsonb_set(jsonb_set(jsonb_set(:'blank'::jsonb,'{service}','{"name":"Sportello"}'),'{outcome}','"confirmed"'),'{evidence}',
 jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/service/name','input_id',:'inp',
 'input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','kind','stated','span',jsonb_build_object('start',0,'end',9),'quote','Sportello'))) AS filled \gset
SELECT pg_temp.expect_error(format('SELECT preparation.submit_item(%L,%L,%L,gen_random_uuid())',:'ws',:'card',:'blank_version'),'55000','item_not_confirmed');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'blank_version','payload',:'filled'::jsonb)),gen_random_uuid()) AS saved \gset
SELECT :'saved'::jsonb->'items'->0->>'after' AS confirmed_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'confirmed_version',
 'payload',jsonb_set(:'filled'::jsonb,'{service,contacts}','[{"channel_type":"fax","value":"123"}]'))),gen_random_uuid()) AS bad_saved \gset
SELECT :'bad_saved'::jsonb->'items'->0->>'after' AS bad_version \gset
SELECT pg_temp.expect_error(format('SELECT preparation.submit_item(%L,%L,%L,gen_random_uuid())',:'ws',:'card',:'bad_version'),'22023','invalid_preparation_vocabulary');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'bad_version','payload',:'filled'::jsonb)),gen_random_uuid()) AS restored \gset
SELECT :'restored'::jsonb->'items'->0->>'after' AS confirmed_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'confirmed_version',
 'payload',jsonb_set(:'filled'::jsonb,'{service,organizations}',jsonb_build_array(jsonb_build_object('organization_id',gen_random_uuid(),'role_code','operator'))))),gen_random_uuid()) AS bad_reference \gset
SELECT :'bad_reference'::jsonb->'items'->0->>'after' AS bad_version \gset
SELECT pg_temp.expect_error(format('SELECT preparation.submit_item(%L,%L,%L,gen_random_uuid())',:'ws',:'card',:'bad_version'),'22023','unresolved_preparation_reference');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'bad_version','payload',:'filled'::jsonb)),gen_random_uuid()) AS restored \gset
SELECT :'restored'::jsonb->'items'->0->>'after' AS confirmed_version \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS sibling \gset
SELECT :'sibling'::jsonb->'items'->0->>'item_id' AS sibling_card, :'sibling'::jsonb->'items'->0->>'version_id' AS sibling_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'sibling_card','expected_version',:'sibling_version',
 'payload',jsonb_set(jsonb_set(:'blank'::jsonb,'{service}','{"name":"UNSENT SIBLING PRIVATE VALUE"}'),'{outcome}','"confirmed"'))),gen_random_uuid());
SELECT preparation.set_grant(:'ws',:'reader','read',2,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT pg_temp.expect_error(format('SELECT preparation.submit_item(%L,%L,%L,gen_random_uuid())',:'ws',:'card',:'confirmed_version'),'42501','preparation_permission_denied');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.set_grant(:'ws',:'reader','edit',3,gen_random_uuid());
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-reader','UTF8')),'hex'));
SELECT gen_random_uuid() AS submit_key \gset
SELECT preparation.submit_item(:'ws',:'card',:'confirmed_version',:'submit_key') AS sent \gset
SELECT :'sent'::jsonb->>'contribution_id' AS contribution \gset
SELECT pg_temp.assert_true(preparation.submit_item(:'ws',:'card',:'confirmed_version',:'submit_key')=:'sent'::jsonb,'same request replay');
SELECT pg_temp.assert_true(:'sent'::jsonb->>'submitted_by'=:'reader','editor can submit with own attribution');
SELECT pg_temp.assert_true(jsonb_array_length(:'sent'::jsonb->'diagnostics')>=2,'name-only card queues with completeness diagnostics');
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.submit_item(:'ws',:'card',:'confirmed_version',gen_random_uuid()) AS repeated \gset
SELECT pg_temp.assert_true(:'repeated'::jsonb->>'contribution_id'=:'contribution' AND :'repeated'::jsonb->>'submitted_by'=:'reader','other submitter reuses first contribution/actor');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'card','expected_version',:'confirmed_version',
 'payload',jsonb_set(jsonb_set(:'filled'::jsonb,'{service,name}','"Updated manual name"'),'{evidence}','[]'))),gen_random_uuid()) AS edited \gset
SELECT :'edited'::jsonb->'items'->0->>'after' AS next_version \gset
SELECT preparation.submit_item(:'ws',:'card',:'next_version',gen_random_uuid())->>'contribution_id' AS next_contribution \gset
COMMIT;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-admin','UTF8')),'hex'));
SELECT editorial.read_community_snapshot(:'contribution') AS copied \gset
SELECT pg_temp.assert_true(:'copied'::jsonb#>>'{snapshot,values,service,name}'='Sportello','submitted snapshot immutable after private edit');
SELECT pg_temp.assert_true(position('UNSENT SIBLING PRIVATE VALUE' IN :'copied')=0 AND position('Updated manual name' IN :'copied')=0,'moderator sees only selected card and excerpts');
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'next_contribution')#>>'{snapshot,parent_contribution_id}'=:'contribution','new version is a linked update');
SELECT pg_temp.expect_error(format('SELECT preparation.read_input(%L,%L)',:'ws',:'inp'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.read_history(%L,%L,0,100)',:'ws',:'card'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT editorial.close_contribution(%L,%L,NULL,%L)',:'contribution','published',gen_random_uuid()),'23514','community_publication_required');
SELECT editorial.close_contribution(:'contribution','rejected','Fixture closed',NULL);
COMMIT;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM data.services)=:'services_before','submission creates no canonical service');
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.events WHERE contribution_id=:'contribution' AND action='submitted')=1
 AND (SELECT actor_id=:'reader' FROM editorial.events WHERE contribution_id=:'contribution' AND action='submitted'),'one attributed submission event');
SELECT pg_temp.expect_error(format('UPDATE editorial.community_snapshots SET evidence=%L WHERE contribution_id=%L','[]',:'contribution'),'55000','immutable_record');
-- Community submissions do not consume anonymous visitor quota.
UPDATE editorial.intake_settings SET window_limit=1,daily_limit=1;
SET SESSION AUTHORIZATION egi_probe_community_intake;
SELECT pg_temp.assert_true(editorial.submit_contribution('new_service',NULL,NULL,NULL,NULL,false,'[{"field":"name","value":"Visitor fixture"}]',NULL)='stored','Community does not limit visitor intake');
SELECT pg_temp.assert_true(editorial.submit_contribution('new_service',NULL,NULL,NULL,NULL,false,'[{"field":"name","value":"Visitor fixture two"}]',NULL)='limited','visitor quota unchanged');
RESET SESSION AUTHORIZATION;
UPDATE editorial.intake_settings SET window_limit=30,daily_limit=300;
UPDATE editorial.contributions SET closed_at=clock_timestamp()-interval '31 days' WHERE contribution_id=:'contribution';
SET SESSION AUTHORIZATION egi_probe_community_retention;
SELECT editorial.purge_expired_contributions();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT values#>>'{service,name}'='Sportello' FROM editorial.community_snapshots WHERE contribution_id=:'contribution'),'visitor purge leaves submitted Community data intact');
SET SESSION AUTHORIZATION egi_probe_preparation;
BEGIN;
SELECT access.verify_session(encode(sha256(convert_to('prep-owner','UTF8')),'hex'));
SELECT preparation.trash_workspace(:'ws',4,gen_random_uuid());
COMMIT;
RESET SESSION AUTHORIZATION;
UPDATE preparation.workspaces SET trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe_community_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.inputs WHERE workspace_id=:'ws') AND
 (SELECT values#>>'{service,name}'='Sportello' FROM editorial.community_snapshots WHERE contribution_id=:'contribution'),'private purge leaves independent editorial snapshot');
TRUNCATE editorial.community_snapshots CASCADE;
DELETE FROM editorial.events;
DELETE FROM editorial.proposals;
DELETE FROM editorial.contributions;
TRUNCATE preparation.workspaces CASCADE;
DELETE FROM access.request_actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DELETE FROM access.sessions WHERE account_id IN (SELECT account_id FROM access.accounts WHERE login_name LIKE 'prep-%');
DELETE FROM access.accounts WHERE login_name LIKE 'prep-%';
DELETE FROM governance.actors WHERE actor_id IN (:'owner',:'reader',:'admin');
DROP ROLE egi_probe_preparation,egi_probe_community_retention,egi_probe_community_intake;
