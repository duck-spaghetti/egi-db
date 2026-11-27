-- Native private group lineage, bounded partial receipts and compensation.
SET TIME ZONE 'Etc/GMT+12';
SET egi.reference_expiry='on';
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
CREATE FUNCTION pg_temp.group_frame(wid uuid,iid uuid,n integer) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE members jsonb:='[]'; r jsonb; v jsonb; p jsonb; f uuid; k integer; saved jsonb;
BEGIN
 FOR k IN 1..n LOOP
  r:=preparation.create_items(wid,iid,NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0;
  v:=preparation.read_item(wid,(r->>'item_id')::uuid,NULL)->'version'; f:=gen_random_uuid();
  p:=(v->'payload')||jsonb_build_object('schema_version',2,'service',jsonb_build_object('name','Mensa'),'outcome','confirmed',
   'field_origins',jsonb_build_object('/source_facts/0/source_value',jsonb_build_object('state','manual'),'/source_facts/0/value',jsonb_build_object('state','manual')),
   'source_facts',jsonb_build_array(jsonb_build_object('fact_id',f,'subject','service','kind','category_label','source_value','Mensa','value','Mensa')),'resolutions','[]'::jsonb,
   'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value','kind','stated','input_id',iid,
    'input_hash',preparation.read_input(wid,iid)->>'sha256','quote','Mensa','span',jsonb_build_object('start',18,'end',23))));
  saved:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',r->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
  members:=members||jsonb_build_array(jsonb_build_object('item_id',r->>'item_id','expected_version',saved#>>'{items,0,after}','basis_kind','source_fact','basis_id',f));
 END LOOP;
 RETURN members;
END $$;
CREATE FUNCTION pg_temp.change_group_member(wid uuid,m jsonb,cleared boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb; p jsonb; r jsonb;
BEGIN
 v:=preparation.read_item(wid,(m->>'item_id')::uuid,NULL)->'version'; p:=v->'payload';
 IF cleared THEN p:=p#-'{source_facts,0,value}'; ELSE p:=jsonb_set(p,'{source_facts,0,value}','"Custom decision"'); END IF;
 p:=jsonb_set(p,'{field_origins}',(p->'field_origins')||jsonb_build_object('/source_facts/0/value',jsonb_build_object('state',CASE WHEN cleared THEN 'cleared' ELSE 'manual' END)));
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',m->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
 RETURN jsonb_set(m,'{expected_version}',r#>'{items,0,after}');
END $$;
CREATE FUNCTION pg_temp.check_interpreted_group(wid uuid,source_member jsonb,context jsonb,target jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v jsonb; p jsonb; r jsonb; m jsonb; basis jsonb; interpretation jsonb; receipt jsonb;
 eid uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid(); gid uuid:=gen_random_uuid(); gv uuid:=gen_random_uuid();
BEGIN
 v:=preparation.read_item(wid,(source_member->>'item_id')::uuid,NULL)->'version'; p:=v->'payload';
 p:=jsonb_set(p,'{service,description}','"Mensa"');
 p:=jsonb_set(p,'{evidence}',(p->'evidence')||jsonb_build_array(jsonb_build_object('id',eid,'path','/service/description','kind','stated','input_id',v->>'input_id',
  'input_hash',preparation.read_input(wid,(v->>'input_id')::uuid)->>'sha256','quote','Mensa','span',jsonb_build_object('start',18,'end',23))));
 PERFORM preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',source_member->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
 v:=preparation.read_item(wid,(source_member->>'item_id')::uuid,NULL)->'version'; p:=v->'payload';
 basis:=jsonb_build_object('item_version',v->>'id','field_path','/service/description','value_digest',encode(sha256(convert_to((p#>'{service,description}')::text,'UTF8')),'hex'),'evidence_ids',jsonb_build_array(eid));
 interpretation:=jsonb_build_object('interpretation_id',iid,'basis',basis,'context',context,'candidates',jsonb_build_array(jsonb_build_object('target',target,'reason','Reviewed description interpretation','support_evidence_ids',jsonb_build_array(eid))),
  'state','proposed','selected',NULL,'method','manual','job_id',NULL);
 p:=p||jsonb_build_object('schema_version',3,'interpreted_classifications',jsonb_build_array(interpretation),'interpretation_hypotheses','[]'::jsonb);
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',source_member->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
 m:=jsonb_build_object('item_id',source_member->>'item_id','expected_version',r#>'{items,0,after}','basis_kind','interpreted_classification','basis_id',iid);
 PERFORM preparation.save_group(wid,NULL,jsonb_build_object('group_id',gid,'version',gv,'parent_versions','[]'::jsonb,'preparation_id',wid,'context',context,'members',jsonb_build_array(m),
  'mapping',target,'state','accepted','method','manual','proposal_id',NULL),gen_random_uuid());
 receipt:=preparation.apply_group(wid,jsonb_build_object('group_id',gid,'expected_group_version',gv,'selection',jsonb_build_array(m),'request_key',gen_random_uuid()));
 PERFORM pg_temp.assert_true(receipt#>>'{items,0,status}'='applied','explicitly materialized description interpretation can receive group mapping');
 p:=preparation.read_item(wid,(m->>'item_id')::uuid,NULL)#>'{version,payload}';
 PERFORM pg_temp.assert_true(p#>>'{interpreted_classifications,0,state}'='confirmed' AND jsonb_array_length(p->'source_facts')=1 AND p#>>'{source_facts,0,source_value}'='Mensa','interpreted group preserves literal source facts and attribution boundary');
 r:=preparation.undo_group(wid,(receipt->>'operation_id')::uuid,gen_random_uuid());
 PERFORM pg_temp.assert_true(r#>>'{items,0,status}'='applied' AND preparation.read_item(wid,(m->>'item_id')::uuid,NULL)#>>'{version,payload,outcome}'='review','interpreted group compensation remains in review');
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT clock_timestamp() AS frame_started \gset
SELECT pg_temp.group_frame(:'ws',:'inp',1000) AS members \gset
SELECT preparation.reference_catalog(:'ws','{"kind":"taxonomy_context"}')#>'{entries,0}' AS tc \gset
SELECT preparation.get_group_context(:'ws',(:'tc'::jsonb->>'territory_id')::uuid,(:'tc'::jsonb->>'axis_id')::uuid) AS gc \gset
SELECT preparation.reference_catalog(:'ws',(:'gc'::jsonb-'catalog_digest'-'as_of')||'{"kind":"classification"}')#>'{entries,0,target}' AS mapping \gset
SELECT gen_random_uuid() AS gid,gen_random_uuid() AS gv \gset
SELECT jsonb_build_object('group_id',:'gid','version',:'gv','parent_versions','[]'::jsonb,'preparation_id',:'ws','context',:'gc'::jsonb,'members',:'members'::jsonb,
 'mapping',:'mapping'::jsonb,'state','accepted','method','manual','proposal_id',NULL) AS group_body \gset
SELECT preparation.read_item(:'ws',(:'members'::jsonb#>>'{0,item_id}')::uuid,NULL)#>>'{version,id}' AS before_accept \gset
SELECT preparation.save_group(:'ws',NULL,:'group_body',gen_random_uuid())#>>'{group,version}' AS saved_group_version \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',(:'members'::jsonb#>>'{0,item_id}')::uuid,NULL)#>>'{version,id}'=:'before_accept','accepting1000-member group writes no card');
SELECT pg_temp.assert_true(preparation.list_groups(:'ws',0,1)->>'total'='1','private group pagination');
SELECT pg_temp.expect_error(format('SELECT preparation.read_group(%L,%L,NULL,0,NULL)',:'ws',:'gid'),'22023','invalid_group_page');
SELECT pg_temp.expect_error(format('SELECT preparation.list_groups(%L,NULL,100)',:'ws'),'22023','invalid_group_page');

SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_group(:'ws',:'gid',NULL,0,100)->'members')=100 AND preparation.read_group(:'ws',:'gid',NULL,900,100)->>'total_members'='1000' AND
 preparation.read_group(:'ws',:'gid',NULL,0,100)->>'next_offset'='100' AND NOT (preparation.list_groups(:'ws',0,1)#>'{groups,0}') ? 'members','group reads page100 members and list summaries exclude bodies');

SELECT preparation.submit_item(:'ws',(:'members'::jsonb#>>'{0,item_id}')::uuid,(:'members'::jsonb#>>'{0,expected_version}')::uuid,gen_random_uuid())->>'contribution_id' AS retained_submission \gset
SELECT editorial.read_community_snapshot(:'retained_submission') AS submission_before \gset
SELECT jsonb_build_object('group_id',:'gid','expected_group_version',:'gv','selection',(SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(:'members'::jsonb) WITH ORDINALITY a(x,n) WHERE n<=100),'request_key',gen_random_uuid()) AS apply_request \gset
SELECT preparation.apply_group(:'ws',:'apply_request') AS first_receipt \gset
SELECT pg_temp.assert_true(:'first_receipt'::jsonb->>'state'='running' AND (SELECT count(*) FROM jsonb_array_elements(:'first_receipt'::jsonb->'items') x WHERE x->>'status'='applied')=50,'first bounded batch applies50 and exposes pending');
SELECT preparation.apply_group(:'ws',:'apply_request') AS complete_receipt \gset
SELECT pg_temp.assert_true(:'complete_receipt'::jsonb->>'state'='complete' AND (SELECT count(*) FROM jsonb_array_elements(:'complete_receipt'::jsonb->'items') x WHERE x->>'status'='applied')=100,'same-key resume processes remaining50 exactly');
SELECT pg_temp.assert_true(preparation.apply_group(:'ws',:'apply_request')=:'complete_receipt'::jsonb,'terminal receipt exact replay');
SELECT pg_temp.expect_error(format('SELECT preparation.read_group_operation(%L,%L,NULL,100)',:'ws',:'complete_receipt'::jsonb->>'operation_id'),'22023','invalid_group_page');

SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_group_operation(:'ws',(:'complete_receipt'::jsonb->>'operation_id')::uuid,0,10)->'items')=10 AND
 preparation.read_group_operation(:'ws',(:'complete_receipt'::jsonb->>'operation_id')::uuid,0,10)->>'next_offset'='10','operation receipts paginate separately from durable summary');

-- Concurrent edit after application: compensation must leave it intact.
SELECT :'complete_receipt'::jsonb#>>'{items,0,item_id}' AS edited_item \gset
SELECT preparation.read_item(:'ws',:'edited_item',NULL)->'version' AS edited_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'edited_item','expected_version',:'edited_version'::jsonb->>'id',
 'payload',jsonb_set(:'edited_version'::jsonb->'payload','{service,description}','"Unrelated later correction"'))),gen_random_uuid());
SELECT gen_random_uuid() AS undo_key \gset
SELECT preparation.undo_group(:'ws',(:'complete_receipt'::jsonb->>'operation_id')::uuid,:'undo_key') AS undo_first \gset
SELECT preparation.undo_group(:'ws',(:'complete_receipt'::jsonb->>'operation_id')::uuid,:'undo_key') AS undo_complete \gset
SELECT pg_temp.assert_true(:'undo_complete'::jsonb->>'state'='complete' AND (SELECT count(*) FROM jsonb_array_elements(:'undo_complete'::jsonb->'items') x WHERE x->>'status'='conflict')=1,'undo compensates only unchanged produced heads');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'edited_item',NULL)#>>'{version,payload,service,description}'='Unrelated later correction','undo preserves later edit');
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'retained_submission')=:'submission_before'::jsonb,'group apply and undo leave immutable submission untouched');
SELECT pg_temp.change_group_member(:'ws',:'members'::jsonb->100,false) AS manual_member,pg_temp.change_group_member(:'ws',:'members'::jsonb->101,true) AS cleared_member \gset
SELECT preparation.read_item(:'ws',(:'members'::jsonb#>>'{102,item_id}')::uuid,NULL)->'version' AS stale_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'members'::jsonb#>>'{102,item_id}','expected_version',:'stale_version'::jsonb->>'id',
 'payload',jsonb_set(:'stale_version'::jsonb->'payload','{service,description}','"Concurrent correction"'))),gen_random_uuid());
SELECT preparation.apply_group(:'ws',jsonb_build_object('group_id',:'gid','expected_group_version',:'gv','selection',jsonb_build_array(:'manual_member'::jsonb,:'cleared_member'::jsonb,:'members'::jsonb->102),'request_key',gen_random_uuid())) AS protected_receipt \gset
SELECT pg_temp.assert_true((SELECT count(*) FROM jsonb_array_elements(:'protected_receipt'::jsonb->'items') x WHERE x->>'status'='skipped' AND x->>'reason'='manual_or_cleared')=2 AND
 (SELECT count(*) FROM jsonb_array_elements(:'protected_receipt'::jsonb->'items') x WHERE x->>'status'='conflict' AND x->>'reason'='stale_item')=1,'manual cleared and stale members are preserved with durable outcomes');
SELECT pg_temp.check_interpreted_group(:'ws',:'members'::jsonb->103,:'gc',:'mapping');
-- Split and combine have explicit checked immutable parent lineage.
SELECT gen_random_uuid() AS child_id,gen_random_uuid() AS child_version \gset
SELECT (:'group_body'::jsonb)||jsonb_build_object('group_id',:'child_id','version',:'child_version','parent_versions',jsonb_build_array(:'gv'),'members',jsonb_build_array(:'members'::jsonb->100),'state','proposed') AS child \gset
SELECT preparation.save_group(:'ws',NULL,:'child',gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_group(:'ws',:'child_id',NULL)#>'{group,parent_versions}'=jsonb_build_array(:'gv'),'split retains exact parent version');
SELECT pg_temp.expect_error(format('SELECT preparation.save_group(%L,NULL,%L,gen_random_uuid())',:'ws',jsonb_set(:'child'::jsonb,'{group_id}',to_jsonb(gen_random_uuid()))),'23505');
SELECT gen_random_uuid() AS child2_id,gen_random_uuid() AS child2_version \gset
SELECT preparation.save_group(:'ws',NULL,(:'child'::jsonb)||jsonb_build_object('group_id',:'child2_id','version',:'child2_version','members',jsonb_build_array(:'members'::jsonb->101)),gen_random_uuid());
SELECT gen_random_uuid() AS combined_id,gen_random_uuid() AS combined_version \gset
SELECT preparation.save_group(:'ws',NULL,(:'child'::jsonb)||jsonb_build_object('group_id',:'combined_id','version',:'combined_version',
 'parent_versions',jsonb_build_array(:'child_version',:'child2_version'),'members',jsonb_build_array(:'members'::jsonb->100,:'members'::jsonb->101)),gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_group(:'ws',:'child_id',NULL)#>>'{group,state}'='archived' AND preparation.read_group(:'ws',:'child2_id',NULL)#>>'{group,state}'='archived','combine archives exact checked parent heads');

SELECT pg_temp.expect_error(format('SELECT preparation.save_group(%L,NULL,%L,gen_random_uuid())',:'ws',(:'child'::jsonb)||jsonb_build_object('group_id',gen_random_uuid(),'version',gen_random_uuid(),'parent_versions',jsonb_build_array(:'gv',:'gv'))),'22023','invalid_group_revision');
-- Expired taxonomy cannot authorize mapping, but unchanged archival remains recoverable.
SET TIME ZONE 'Pacific/Kiritimati';
SELECT pg_temp.expect_error(format('SELECT preparation.apply_group(%L,%L)',:'ws',jsonb_build_object('group_id',:'gid','expected_group_version',:'gv','selection',jsonb_build_array(:'members'::jsonb->104),'request_key',gen_random_uuid())),'22023','invalid_group_context');
SELECT preparation.save_group(:'ws',:'gv',(:'group_body'::jsonb)||jsonb_build_object('version',gen_random_uuid(),'parent_versions',jsonb_build_array(:'gv'),'state','archived'),gen_random_uuid())#>>'{group,state}' AS archived_state \gset
SELECT pg_temp.assert_true(:'archived_state'='archived','archival-only exact head succeeds after catalog expiry');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT has_table_privilege('egi_editorial','preparation.group_revisions','SELECT') AND NOT has_function_privilege('egi_preparation_worker','preparation.apply_group(uuid,jsonb)','EXECUTE'),'private group function-only capabilities');
SELECT pg_temp.expect_error('UPDATE preparation.group_revisions SET body=body','55000');
SELECT clock_timestamp()-:'frame_started'::timestamptz AS thousand_card_frame_elapsed;
CREATE ROLE egi_probe37_retention LOGIN IN ROLE egi_retention;
UPDATE preparation.workspaces SET state='trash',trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe37_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.private_groups WHERE workspace_id=:'ws') AND NOT EXISTS(SELECT FROM preparation.group_applications WHERE workspace_id=:'ws'),'expired private group lineage and receipts purge through existing retention hook');

ROLLBACK;
