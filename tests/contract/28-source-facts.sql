-- EGI-114: literal facts survive versions, selective moderation and private purge.
\ir helpers.sql
BEGIN;
CREATE ROLE egi_probe_facts LOGIN IN ROLE egi_editorial;
CREATE ROLE egi_probe_facts_retention LOGIN IN ROLE egi_retention;
INSERT INTO sources.registry(code,name,source_kind) VALUES('facts-'||gen_random_uuid(),'Literal fact fixture','manual') RETURNING source_id AS src \gset
INSERT INTO governance.actors(display_name) VALUES('Fact owner') RETURNING actor_id AS owner \gset
INSERT INTO governance.actors(display_name) VALUES('Fact outsider') RETURNING actor_id AS outsider \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES(:'owner','facts-owner','moderator','active'),(:'outsider','facts-outsider','admin','active');
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
 SELECT account_id,encode(sha256(convert_to(login_name,'UTF8')),'hex'),'oidc',true,clock_timestamp()+interval '1 day' FROM access.accounts WHERE login_name LIKE 'facts-%';
SET SESSION AUTHORIZATION egi_probe_facts;
SELECT pg_temp.expect_error('SELECT * FROM preparation.fact_identities','42501');
SELECT pg_temp.expect_error('SELECT preparation.validate_source_facts(NULL,NULL)','42501');
SELECT access.verify_session(encode(sha256(convert_to('facts-owner','UTF8')),'hex'));
SELECT preparation.create_workspace(:'src','Unresolved names',gen_random_uuid())->>'id' AS ws \gset
SELECT 'Associazione Alfa'||chr(13)||chr(10)||'Mensa'||chr(10)||'PRIVATE UNSENT SIBLING' AS source_text \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to(:'source_text','UTF8'),'false',gen_random_uuid())->>'input_id' AS inp \gset
SELECT encode(sha256(convert_to(:'source_text','UTF8')),'hex') AS input_hash \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS created \gset
SELECT :'created'::jsonb->>'item_id' AS item,:'created'::jsonb->>'version_id' AS blank_version \gset
SELECT preparation.read_item(:'ws',:'item',NULL)->'version'->'payload'||'{"service":{"name":"Mensa"},"outcome":"confirmed"}'::jsonb AS v1 \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'blank_version','payload',:'v1'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS first_version \gset
SELECT preparation.submit_item(:'ws',:'item',:'first_version',gen_random_uuid())->>'contribution_id' AS old_submission \gset
SELECT editorial.read_community_snapshot(:'old_submission')->'snapshot' AS old_snapshot \gset
SELECT gen_random_uuid() AS org_fact,gen_random_uuid() AS category_fact,gen_random_uuid() AS org_evidence,gen_random_uuid() AS category_evidence \gset
SELECT :'v1'::jsonb||jsonb_build_object('schema_version',2,'source_facts',jsonb_build_array(
 jsonb_build_object('fact_id',:'org_fact','subject','service','kind','organization_name','source_value','Associazione Alfa','value','Associazione Alfa'),
 jsonb_build_object('fact_id',:'category_fact','subject','service','kind','category_label','source_value','Mensa','value','Mensa')),
 'resolutions','[]'::jsonb,'evidence',jsonb_build_array(
 jsonb_build_object('id',:'org_evidence','path','/source_facts/0/source_value','kind','stated','input_id',:'inp','input_hash',:'input_hash','quote','Associazione Alfa','span',jsonb_build_object('start',0,'end',17)),
 jsonb_build_object('id',:'category_evidence','path','/source_facts/1/source_value','kind','stated','input_id',:'inp','input_hash',:'input_hash','quote','Mensa','span',jsonb_build_object('start',19,'end',24)))) AS v2 \gset
SELECT gen_random_uuid() AS upgrade_key \gset
SELECT jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'first_version','payload',:'v2'::jsonb)) AS upgrade_changes \gset
SELECT preparation.save_items(:'ws',:'upgrade_changes',:'upgrade_key') AS upgraded \gset
SELECT pg_temp.assert_true(preparation.save_items(:'ws',:'upgrade_changes',:'upgrade_key')=:'upgraded'::jsonb,'same v2 upgrade receipt');
SELECT :'upgraded'::jsonb->'items'->0->>'after' AS v2_version \gset
SELECT pg_temp.assert_true((preparation.read_item(:'ws',:'item',NULL)#>'{version,payload,source_facts,0}')=(:'v2'::jsonb#>'{source_facts,0}'),'unresolved literal survives reopen');
SELECT preparation.undo_operation(:'ws',(:'upgraded'::jsonb->>'operation_id')::uuid,gen_random_uuid())->'items'->0->>'after' AS upgrade_undo_version \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,schema_version}'='2' AND preparation.read_item(:'ws',:'item',NULL)#>'{version,payload,source_facts}'='[]'::jsonb,'undo upgrade appends v2 compensation, never downgrades');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'upgrade_undo_version','payload',:'v2'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS v2_version \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'v1'::jsonb))),'22023','item_schema_downgrade');
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'first_version','payload',:'v2'::jsonb))),'40001','item_version_conflict');
SELECT jsonb_set(:'v2'::jsonb,'{source_facts,1,fact_id}',to_jsonb(:'org_fact'::text)) AS duplicate \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'duplicate'::jsonb))),'22023','duplicate_source_fact_id');
SELECT jsonb_set(:'v2'::jsonb,'{source_facts,0,organization_id}',to_jsonb(gen_random_uuid())) AS invented \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'invented'::jsonb))),'22023');
SELECT jsonb_set(:'v2'::jsonb,'{evidence,0,quote}','"Invented quote"') AS invalid_quote \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'invalid_quote'::jsonb))),'22023','source_fact_evidence_mismatch');
SELECT jsonb_set(:'v2'::jsonb,'{resolutions}',jsonb_build_array(jsonb_build_object('fact_id',:'org_fact','state','confirmed','context','{}'::jsonb,'candidates','[]'::jsonb,'selected',jsonb_build_object('organization_id',gen_random_uuid())))) AS fake_resolution \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'fake_resolution'::jsonb))),'22023','reference_resolution_not_available');
SELECT jsonb_set(jsonb_set(jsonb_set(:'v2'::jsonb,'{source_facts,0,source_value}','"Alfa"'),'{source_facts,0,value}','"Alfa"'),'{evidence,0,id}',to_jsonb(gen_random_uuid())) AS changed_identity \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'changed_identity'::jsonb))),'22023','source_fact_identity_conflict');
SELECT jsonb_set(:'v2'::jsonb,'{source_facts,0,value}','"Corrected name"') AS corrected \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'corrected'::jsonb))),'22023','source_fact_manual_origin_required');
SELECT jsonb_set(:'corrected'::jsonb,'{field_origins}','{"/source_facts/0/value":{"state":"manual"}}') AS corrected \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'v2_version','payload',:'corrected'::jsonb)),gen_random_uuid()) AS correction \gset
SELECT :'correction'::jsonb->'items'->0->>'after' AS corrected_version \gset
SELECT preparation.undo_operation(:'ws',(:'correction'::jsonb->>'operation_id')::uuid,gen_random_uuid())->'items'->0->>'after' AS undo_version \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,source_facts,0,value}'='Associazione Alfa','undo restores value without changing literal identity');
SELECT jsonb_set(jsonb_set(jsonb_set(:'v2'::jsonb,'{source_facts}',jsonb_build_array(:'v2'::jsonb#>'{source_facts,1}',:'v2'::jsonb#>'{source_facts,0}')),
 '{evidence,0,path}','"/source_facts/1/source_value"'),'{evidence,1,path}','"/source_facts/0/source_value"') AS reordered \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'undo_version','payload',:'reordered'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS reordered_version \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS sibling \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'sibling'::jsonb->>'item_id','expected_version',:'sibling'::jsonb->>'version_id','payload',:'v2'::jsonb))),'22023','source_fact_identity_conflict');
SELECT preparation.submit_item(:'ws',:'item',:'reordered_version',gen_random_uuid())->>'contribution_id' AS submission \gset
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'old_submission')->'snapshot'=:'old_snapshot'::jsonb,'v1 submission never rewritten');
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'submission')#>>'{snapshot,values,source_facts,1,source_value}'='Associazione Alfa','moderation retains unresolved organization');
SELECT pg_temp.assert_true(position('PRIVATE UNSENT SIBLING' IN editorial.read_community_snapshot(:'submission')::text)=0,'no raw input or unsent sibling copied');
SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_history(:'ws',:'item')->'versions')=8,'append-only upgrade/correction/undo/reorder history');
\if :{?measure_facts}
RESET SESSION AUTHORIZATION;
CREATE FUNCTION pg_temp.measure_fact_saves(wid uuid,item uuid,payload jsonb,iterations integer) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE expected uuid; n integer; started timestamptz:=clock_timestamp();
BEGIN
 expected:=(preparation.read_item(wid,item,NULL)#>>'{version,id}')::uuid;
 FOR n IN 1..iterations LOOP
  expected:=(preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',expected,'payload',payload)),gen_random_uuid())#>>'{items,0,after}')::uuid;
 END LOOP;
 RETURN extract(epoch FROM clock_timestamp()-started)*1000/iterations;
END $$;
SET SESSION AUTHORIZATION egi_probe_facts;
SELECT pg_temp.measure_fact_saves(:'ws',(:'sibling'::jsonb->>'item_id')::uuid,:'v1'::jsonb,20) AS v1_mean_ms,
 pg_temp.measure_fact_saves(:'ws',:'item',:'reordered'::jsonb,20) AS two_fact_mean_ms;
SELECT jsonb_set(jsonb_set(:'reordered'::jsonb,'{source_facts}',(SELECT jsonb_agg(jsonb_set(:'reordered'::jsonb#>'{source_facts,0}','{fact_id}',to_jsonb(gen_random_uuid()))) FROM generate_series(1,1000))),
 '{evidence}',(SELECT jsonb_agg(jsonb_set(jsonb_set(:'reordered'::jsonb#>'{evidence,1}','{id}',to_jsonb(gen_random_uuid())),'{path}',to_jsonb('/source_facts/'||n||'/source_value'))) FROM generate_series(0,999) n)) AS maximum_facts \gset
SELECT pg_temp.measure_fact_saves(:'ws',:'item',:'maximum_facts'::jsonb,1) AS thousand_fact_ms;
\endif
SELECT preparation.trash_workspace(:'ws',2,gen_random_uuid());
RESET SESSION AUTHORIZATION;
UPDATE preparation.workspaces SET trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe_facts_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.inputs WHERE workspace_id=:'ws'),'private input purged');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.fact_identities WHERE item_id=:'item'),'private identity register purged');
SET SESSION AUTHORIZATION egi_probe_facts;
SELECT pg_temp.expect_error(format('SELECT preparation.read_workspace(%L)',:'ws'),'P0002');
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'submission')#>>'{snapshot,values,source_facts,1,source_value}'='Associazione Alfa','snapshot survives private deletion and can be moderated');
RESET SESSION AUTHORIZATION;
\if :{?keep_facts}
COMMIT;
\else
ROLLBACK;
\endif
