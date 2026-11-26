-- EGI-106 integration correction: identity-based comparison after collection edits.
BEGIN;
\ir helpers.sql
DO $$ DECLARE first uuid:=gen_random_uuid(); second uuid:=gen_random_uuid(); source uuid:=gen_random_uuid();
 old_body jsonb; new_body jsonb; aligned jsonb; snap editorial.community_snapshots; bound jsonb;
BEGIN
 old_body:=jsonb_build_object('name','Original','contacts',jsonb_build_array(
  jsonb_build_object('component_id',first,'channel_type','phone','value','123','is_public',true,'evidence',jsonb_build_array(jsonb_build_object('assertion_id',source,'role','supporting'))),
  jsonb_build_object('component_id',second,'channel_type','email','value','desk@example.invalid','is_public',true,'evidence',jsonb_build_array(jsonb_build_object('assertion_id',source,'role','supporting')))));
 new_body:=old_body#-'{contacts,0}';
 snap.values:=jsonb_build_object('service','{}'::jsonb,'location',jsonb_build_object('kind','none'));
 snap.evidence:='[]';
 aligned:=editorial.community_align_baseline(old_body,new_body);
 PERFORM pg_temp.assert_true(aligned#>>'{contacts,0,component_id}'=second::text,'baseline follows component identity');
 bound:=editorial.bind_community_body(snap,old_body,new_body,ARRAY['service'],ARRAY[]::uuid[],'[]','Remove first contact');
 PERFORM pg_temp.assert_true(bound#>'{contacts,0}'=old_body#>'{contacts,1}','unchanged shifted contact preserves its original evidence');
 new_body:=jsonb_set(new_body,'{contacts,0,value}','"different@example.invalid"');
 PERFORM pg_temp.expect_error(format('SELECT editorial.bind_community_body(%L::editorial.community_snapshots,%L,%L,%L,ARRAY[]::uuid[],%L,%L)',snap,old_body,new_body,ARRAY['service'],'[]','Changed fact'),'22023','community_fact_needs_evidence_or_observation');
END $$;
ROLLBACK;
