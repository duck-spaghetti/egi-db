-- Native private v3 decisions and historical selective evidence.
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
CREATE FUNCTION pg_temp.check_interpretations(wid uuid,item uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v jsonb; p jsonb; target jsonb; context jsonb; basis jsonb; interpretation jsonb; hypothesis jsonb;
 eid uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid(); hid uuid:=gen_random_uuid(); proof uuid:=gen_random_uuid(); decision uuid; r jsonb; saved uuid; op uuid; contribution uuid;
BEGIN
 v:=preparation.read_item(wid,item,NULL)->'version'; p:=v->'payload';
 -- A description quotation is independent of any original category fact.
 p:=jsonb_set(p,'{service,description}','"Mensa"');
 p:=jsonb_set(p,'{evidence}',(p->'evidence')||jsonb_build_array((p#>'{evidence,1}')||jsonb_build_object('id',eid,'path','/service/description')));
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',v->>'id','payload',p)),gen_random_uuid());
 v:=preparation.read_item(wid,item,NULL)->'version'; p:=v->'payload';
 context:=preparation.reference_catalog(wid,'{"kind":"taxonomy_context"}')#>'{entries,0}';
 context:=jsonb_build_object('territory_id',context->'territory_id','axis_id',context->'axis_id');
 target:=preparation.reference_catalog(wid,context||'{"kind":"classification"}')#>'{entries,0,target}';
 context:=context||jsonb_build_object('catalog_digest',repeat('a',64),'as_of',current_date);
 basis:=jsonb_build_object('item_version',v->>'id','field_path','/service/description','value_digest',encode(sha256(convert_to((p#>'{service,description}')::text,'UTF8')),'hex'),'evidence_ids',jsonb_build_array(eid));
 interpretation:=jsonb_build_object('interpretation_id',iid,'basis',basis,'context',context,'candidates',jsonb_build_array(jsonb_build_object('target',target,'reason','Description supports a proposal only','support_evidence_ids',jsonb_build_array(eid))),'state','proposed','selected',NULL,'method','manual','job_id',NULL);
 hypothesis:=jsonb_build_object('hypothesis_id',hid,'kind','abbreviation_expansion','statement','Trigger is not proof of an expansion','state','unverified','basis',basis,'trigger_evidence_ids',jsonb_build_array(eid),'job_id',NULL,'verification',NULL);
 p:=p||jsonb_build_object('schema_version',3,'interpreted_classifications',jsonb_build_array(interpretation),'interpretation_hypotheses',jsonb_build_array(hypothesis));
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',v->>'id','payload',p)),gen_random_uuid());
 saved:=(r#>>'{items,0,after}')::uuid;
 PERFORM pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',jsonb_set(jsonb_set(p,'{interpreted_classifications,0,candidates}','[]'),'{interpreted_classifications,0,context,axis_id}','null')))),'22023','invalid_interpreted_classification');
 PERFORM pg_temp.assert_true(preparation.read_item(wid,item,NULL)#>>'{version,payload,interpreted_classifications,0,state}'='proposed','proposal never accepts automatically');
 PERFORM pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',v->'payload'))),'22023','item_schema_downgrade');
 p:=jsonb_set(p,'{interpreted_classifications,0}',interpretation||jsonb_build_object('state','confirmed','selected',jsonb_build_object('target',target,'actor_id',gen_random_uuid(),'confirmed_at','1900-01-01')));
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',p)),gen_random_uuid());
 saved:=(r#>>'{items,0,after}')::uuid; p:=preparation.read_item(wid,item,NULL)#>'{version,payload}';
 PERFORM pg_temp.assert_true(p#>>'{interpreted_classifications,0,selected,actor_id}'=(access.verify_session(encode(sha256(convert_to('session30','UTF8')),'hex'))->>'actor_id') AND p#>>'{interpreted_classifications,0,selected,confirmed_at}'<>'1900-01-01','human attribution server-owned');
 PERFORM pg_temp.assert_true(p#>'{service,classifications}' @> jsonb_build_array(jsonb_build_object('adoption_id',target->'adoption_id','term_id',target->'term_id')),'confirmation and body association atomic');
 hypothesis:=hypothesis||jsonb_build_object('state','verified','verification',jsonb_build_object('actor_id',gen_random_uuid(),'verified_at','1900-01-01','decision_id',gen_random_uuid(),'evidence_ids',jsonb_build_array(eid)));
 PERFORM pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',jsonb_set(p,'{interpretation_hypotheses}',jsonb_build_array(hypothesis))))),'22023','hypothesis_trigger_is_not_verification');
 p:=jsonb_set(p,'{evidence}',(p->'evidence')||jsonb_build_array(((p#>'{evidence,0}')-'span'-'quote')||jsonb_build_object('id',proof,'path','/service/name','kind','manual','note','Independent operator verification')));
 hypothesis:=jsonb_set(hypothesis,'{verification,evidence_ids}',jsonb_build_array(proof));
 p:=jsonb_set(p,'{interpretation_hypotheses}',jsonb_build_array(hypothesis));
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',p)),gen_random_uuid());
 saved:=(r#>>'{items,0,after}')::uuid; p:=preparation.read_item(wid,item,NULL)#>'{version,payload}'; decision:=(p#>>'{interpretation_hypotheses,0,verification,decision_id}')::uuid;
 p:=jsonb_set(p,'{interpretation_hypotheses,0,statement}','"A different expansion needs its own human decision"');
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',p)),gen_random_uuid());
 saved:=(r#>>'{items,0,after}')::uuid; p:=preparation.read_item(wid,item,NULL)#>'{version,payload}';
 PERFORM pg_temp.assert_true(p#>>'{interpretation_hypotheses,0,state}'='unverified' AND p#>'{interpretation_hypotheses,0,verification}'='null'::jsonb,'changed verified statement invalidates echoed verification');
 -- Editing the description removes its current quote, retaining the historical
 -- anchor and category association while staling its decision.
 p:=jsonb_set(p,'{service,description}','"Corrected description"');
 SELECT jsonb_set(p,'{evidence}',jsonb_agg(e)) INTO p FROM jsonb_array_elements(p->'evidence') e WHERE e->>'id'<>eid::text;
 r:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',saved,'payload',p)),gen_random_uuid());
 saved:=(r#>>'{items,0,after}')::uuid; p:=preparation.read_item(wid,item,NULL)#>'{version,payload}';
 PERFORM pg_temp.assert_true(p#>>'{interpreted_classifications,0,state}'='stale' AND p#>>'{interpretation_hypotheses,0,state}'='stale','changed basis stales both decisions');
 PERFORM pg_temp.assert_true(jsonb_array_length(p#>'{service,classifications}')>0,'staling never erases existing association');
 contribution:=(preparation.submit_item(wid,item,saved,gen_random_uuid())->>'contribution_id')::uuid;
 PERFORM pg_temp.assert_true(editorial.read_community_snapshot(contribution)#>'{snapshot,values,interpretation_support,0,evidence}' @> jsonb_build_array(jsonb_build_object('id',eid)),'selected snapshot retains historical support');
 PERFORM pg_temp.assert_true(position('PRIVATE UNSENT' IN editorial.read_community_snapshot(contribution)::text)=0,'snapshot never copies full input');
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.check_interpretations(:'ws',:'item');
RESET SESSION AUTHORIZATION;
\if :{?keep_interpretation_transaction}
\else
ROLLBACK;
\endif
