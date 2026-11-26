-- EGI-106: attributed proposal -> canonical draft -> separately authorized publication.
BEGIN;
\ir helpers.sql
CREATE FUNCTION pg_temp.h(token text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(token,'UTF8')),'hex') $$;
CREATE ROLE egi_probe25 LOGIN IN ROLE egi_editorial;
SELECT access.bootstrap_admin('admin25','Community reviewer',pg_temp.h('inv25')) AS account \gset
SELECT count(*) AS initial_services FROM data.services \gset
SELECT count(*) AS initial_locations FROM data.locations \gset
SET LOCAL SESSION AUTHORIZATION egi_probe25;
SELECT access.accept_invitation(pg_temp.h('inv25'),'password','$argon2id$a',NULL,NULL,'JBSWY3DPEHPK3PXP');
SELECT access.open_session(:'account',pg_temp.h('s25'),'password',true);
SELECT access.verify_session(pg_temp.h('s25'));
SELECT editorial.register_community_source('{"name":"Contract community source","source_kind":"directory"}',gen_random_uuid())->>'source_id' AS source \gset
SELECT preparation.create_workspace(:'source','Contract acceptance',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Sportello telefonico pubblico 0612345678 Sede Via Test 1','UTF8'),'true',gen_random_uuid())->>'input_id' AS input \gset
SELECT preparation.create_items(:'ws',:'input',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS created \gset
SELECT :'created'::jsonb->'items'->0->>'item_id' AS item, :'created'::jsonb->'items'->0->>'version_id' AS version \gset
SELECT preparation.read_item(:'ws',:'item',NULL)->'version'->'payload' AS blank \gset
SELECT gen_random_uuid() AS citation, gen_random_uuid() AS desc_citation, gen_random_uuid() AS mode_citation, gen_random_uuid() AS phone_citation \gset
SELECT jsonb_set(jsonb_set(jsonb_set(:'blank'::jsonb,'{service}','{"name":"Sportello","description":"telefonico pubblico","delivery_mode":"telephone","contacts":[{"channel_type":"phone","value":"0612345678","is_public":true}]}'),'{outcome}','"confirmed"'),'{evidence}',
 (SELECT jsonb_agg(jsonb_build_object('id',id,'path',path,'input_id',:'input',
 'input_hash',preparation.read_input(:'ws',:'input')->>'sha256','kind','interpreted','span',jsonb_build_object('start',0,'end',length('Sportello telefonico pubblico 0612345678 Sede Via Test 1')),'quote','Sportello telefonico pubblico 0612345678 Sede Via Test 1')) FROM (VALUES (:'citation','/service/name'),(:'desc_citation','/service/description'),(:'mode_citation','/service/delivery_mode'),(:'phone_citation','/service/contacts/0')) AS loc(id,path))) AS filled \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'version','payload',:'filled'::jsonb)),gen_random_uuid()) AS saved \gset
SELECT :'saved'::jsonb->'items'->0->>'after' AS version \gset
SELECT preparation.submit_item(:'ws',:'item',:'version',gen_random_uuid())->>'contribution_id' AS contribution \gset
SELECT jsonb_build_object('schema_version',1,'expected_service_work',NULL,'expected_service_public',NULL,
 'service_operations',jsonb_build_array(jsonb_build_object('op','add','path','/name','value','Sportello','evidence_ids',jsonb_build_array(:'citation'))),
 'location',jsonb_build_object('kind','none'),'observations','[]'::jsonb,'reason','Selected source values') AS incomplete \gset
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',:'incomplete'),'22023','explicit_delivery_mode_required');
SELECT jsonb_set(:'incomplete'::jsonb,'{service_operations}',(:'incomplete'::jsonb->'service_operations')||jsonb_build_array(
 jsonb_build_object('op','add','path','/description','value','telefonico pubblico','evidence_ids',jsonb_build_array(:'desc_citation')),
 jsonb_build_object('op','add','path','/delivery_mode','value','telephone','evidence_ids',jsonb_build_array(:'mode_citation')),
 jsonb_build_object('op','add','path','/contacts','value',:'filled'::jsonb#>'{service,contacts}','evidence_ids',jsonb_build_array(:'phone_citation')))) AS decision \gset
SELECT editorial.accept_community_item(:'contribution',:'decision',gen_random_uuid()) AS accepted \gset
SELECT :'accepted'::jsonb->>'service_id' AS service, :'accepted'::jsonb->>'initial_revision_id' AS revision \gset
SELECT pg_temp.assert_true(editorial.accept_community_item(:'contribution',:'decision',gen_random_uuid())->>'initial_revision_id'=:'revision','acceptance replay uses same draft');
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',jsonb_set(:'decision'::jsonb,'{reason}','"Changed decision"')),'40001','community_acceptance_conflict');
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'contribution')->>'service_id' IS NULL,'snapshot reader remains bounded');
SELECT pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',:'revision','approved','Ready'),'23514','community_source_not_admitted');
SELECT pg_temp.expect_error(format('SELECT editorial.close_contribution(%L,%L,NULL,%L)',:'contribution','published',gen_random_uuid()),'23514','community_publication_required');
SELECT editorial.admit_community_source(:'source','Contract admission');
SELECT governance.review_revision(:'revision',NULL,'approved','Checked source') AS review \gset
SELECT governance.publish_revision(:'revision',:'review',NULL) AS publication \gset
SELECT editorial.close_community_item(:'contribution','published',NULL,:'publication');
-- Accepting a location and its service is atomic; their drafts remain separate.
SELECT preparation.create_items(:'ws',:'input',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid()) AS loc_created \gset
SELECT :'loc_created'::jsonb->'items'->0->>'item_id' AS loc_item, :'loc_created'::jsonb->'items'->0->>'version_id' AS loc_version \gset
SELECT gen_random_uuid() AS loc_name, gen_random_uuid() AS loc_address \gset
SELECT jsonb_set(jsonb_set(:'filled'::jsonb,'{location}',
 '{"kind":"new","body":{"name":"Sede","location_kind":"address","coordinate_state":"unknown","addresses":[{"address_kind":"physical","formatted":"Via Test 1","normalization_state":"raw"}]}}'),
 '{evidence}',(:'filled'::jsonb->'evidence')||(SELECT jsonb_agg(jsonb_build_object('id',id,'path',path,'input_id',:'input',
 'input_hash',preparation.read_input(:'ws',:'input')->>'sha256','kind','interpreted','span',jsonb_build_object('start',0,'end',length('Sportello telefonico pubblico 0612345678 Sede Via Test 1')),'quote','Sportello telefonico pubblico 0612345678 Sede Via Test 1'))
 FROM (VALUES (:'loc_name','/location/body/name'),(:'loc_address','/location/body/addresses/0')) AS loc(id,path))) AS with_location \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'loc_item','expected_version',:'loc_version','payload',:'with_location'::jsonb)),gen_random_uuid()) AS loc_saved \gset
SELECT :'loc_saved'::jsonb->'items'->0->>'after' AS loc_version \gset
SELECT preparation.submit_item(:'ws',:'loc_item',:'loc_version',gen_random_uuid())->>'contribution_id' AS loc_contribution \gset
SELECT jsonb_set(:'decision'::jsonb,'{location}',:'with_location'::jsonb->'location') AS loc_decision \gset
SELECT jsonb_set(:'loc_decision'::jsonb,'{service_operations,3,value,0,component_id}',editorial.revision_body(:'revision')#>'{contacts,0,component_id}') AS foreign_component_decision \gset
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'loc_contribution',:'foreign_component_decision'),'23514','component_owner_or_kind_mismatch');
SELECT editorial.accept_community_item(:'loc_contribution',:'loc_decision',gen_random_uuid()) AS loc_accepted \gset
SELECT pg_temp.assert_true(:'loc_accepted'::jsonb->>'location_revision_id' IS NOT NULL,'location draft created with service draft');
SELECT pg_temp.assert_true(editorial.revision_body((:'loc_accepted'::jsonb->>'initial_revision_id')::uuid)#>>'{place,location_id}' IS NOT NULL,'service explicitly linked to accepted location');
-- A later version updates the accepted logical service, preserving untouched data.
SELECT jsonb_set(jsonb_set(:'filled'::jsonb,'{service,name}','"Nome corretto"'),'{evidence}','[]') AS correction \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'version','payload',:'correction'::jsonb)),gen_random_uuid()) AS saved \gset
SELECT :'saved'::jsonb->'items'->0->>'after' AS corrected_version \gset
SELECT preparation.submit_item(:'ws',:'item',:'corrected_version',gen_random_uuid())->>'contribution_id' AS update_contribution \gset
SELECT jsonb_build_object('schema_version',1,'expected_service_work',:'revision','expected_service_public',:'revision',
 'service_operations',jsonb_build_array(jsonb_build_object('op','replace','path','/name','value','Nome corretto','evidence_ids','[]'::jsonb)),
 'location',jsonb_build_object('kind','none'),'observations','[]'::jsonb,'reason','Name correction') AS update_decision \gset
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'update_contribution',:'update_decision'),'22023','community_fact_needs_evidence_or_observation');
SELECT jsonb_set(:'update_decision'::jsonb,'{observations}','[{"paths":["/service/name"],"method":"phone_call","note":"Contract verification"}]') AS observed_decision \gset
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'update_contribution',jsonb_set(:'observed_decision'::jsonb,'{expected_service_work}','null')),'40001','community_snapshot_heads_changed');
SELECT editorial.accept_community_item(:'update_contribution',:'observed_decision',gen_random_uuid()) AS update_accepted \gset
SELECT pg_temp.assert_true(:'update_accepted'::jsonb->>'service_id'=:'service','new version retains canonical identity');
SELECT pg_temp.assert_true(editorial.revision_body((:'update_accepted'::jsonb->>'initial_revision_id')::uuid)->'contacts'=editorial.revision_body(:'revision')->'contacts','name correction preserves contacts and proof');
SELECT pg_temp.expect_error(format('SELECT editorial.close_community_item(%L,%L,NULL,%L)',:'update_contribution','published',:'publication'),'23514','community_publication_required');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM data.services)=:'initial_services'::int+2 AND (SELECT count(*) FROM data.locations)=:'initial_locations'::int+1,'failed coordinated acceptance leaves no entities or locations');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM editorial.community_resolutions WHERE contribution_id=:'contribution'),'one immutable resolution');
SELECT pg_temp.assert_true((SELECT count(*)=4 FROM editorial.community_evidence WHERE contribution_id=:'contribution'),'selected excerpt assertions');
SELECT pg_temp.assert_true((SELECT service_id=:'service' FROM editorial.community_resolutions WHERE contribution_id=:'contribution'),'attributed canonical identity');
SELECT pg_temp.assert_true((SELECT outcome='published' FROM editorial.contributions WHERE contribution_id=:'contribution'),'explicit closure after publication');
ROLLBACK;
