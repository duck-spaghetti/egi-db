-- Native immutable previews, eligibility, exact replay and function-only ACL.
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
SELECT jsonb_build_object('schema_version',1,'kind','classification','as_of',current_date::text,'complete',true,
 'context',jsonb_build_object('territory_id',a.territory_id,'axis_id',rt.axis_id),
 'entries',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','label',c.original_text,'published',true,'active',true,
 'effective_from',a.effective_from::text,'effective_until',a.effective_until,'broader','[]'::jsonb,
 'target',jsonb_build_object('kind','classification','adoption_id',a.adoption_id,'release_id',a.release_id,'term_id',rt.term_id,'axis_id',rt.axis_id)))) AS context
 FROM taxonomy.territory_adoptions a JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.axes ax ON ax.axis_id=rt.axis_id
 JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name' JOIN i18n.content_units c USING(content_id)
 WHERE a.effective_from<=current_date AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND ax.code='service_type' \gset
SELECT :'context'::jsonb||jsonb_build_object('digest',preparation.workbench_digest(:'context')) AS context \gset
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('workbench-fixture-1',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'context'::jsonb),100000,20000,1000,0,1000,clock_timestamp(),'synthetic, no provider');
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('workbench-fixture-1',true);
SELECT '{"max_total_packets":5,"max_followup_packets":2,"max_reserved_micro_usd":1000000,"allowed_followup_kinds":["remaining_record_analysis","cross_packet_comparison"]}'::jsonb AS limits,gen_random_uuid() AS plan_key \gset
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],'workbench-fixture-1',:'limits',:'plan_key') AS plan \gset
SELECT pg_temp.assert_true(preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],'workbench-fixture-1',:'limits',:'plan_key')=:'plan'::jsonb,'exact request replay returns frozen plan');
SELECT pg_temp.assert_true((:'plan'::jsonb->>'total_packets')::integer=1 AND (:'plan'::jsonb->>'planned_request_count')::integer=2,'classification frozen and dependent comparison budgeted');
SELECT pg_temp.assert_true(jsonb_array_length(preparation.read_analysis_plan(:'ws',(:'plan'::jsonb->>'plan_id')::uuid,1,0,1)->'packets')=1,'packet manifests paginated');
SELECT pg_temp.expect_error(format('SELECT preparation.preview_analysis_plan(%L,ARRAY[%L::uuid],%L,%L,%L)',:'ws',:'item','workbench-fixture-1',jsonb_set(:'limits','{max_total_packets}','6'),:'plan_key'),'40001','plan_request_conflict');
SELECT pg_temp.expect_error(format('SELECT preparation.preview_analysis_plan(%L,ARRAY[%L::uuid],%L,%L,gen_random_uuid())',:'ws',gen_random_uuid(),'workbench-fixture-1',:'limits'),'22023','selection_not_current_or_owned');
-- An empty card remains explicitly blocked while the eligible family still proceeds.
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0->>'item_id' AS blocked_item \gset
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid,:'blocked_item'::uuid],'workbench-fixture-1',:'limits',gen_random_uuid()) AS blocked_plan \gset
SELECT pg_temp.assert_true((:'blocked_plan'::jsonb->>'total_packets')::integer=1 AND jsonb_array_length(:'blocked_plan'::jsonb->'selection')=2 AND
 EXISTS(SELECT FROM jsonb_array_elements(:'blocked_plan'::jsonb->'events') e WHERE e->>'kind'='blocked' AND e#>>'{body,record_key}'=:'blocked_item'),'blocked member remains visible beside eligible packet');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.jobs),'preview creates no job or dispatch');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.budget_reservations),'preview creates no ledger reservation');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets WHERE position('PRIVATE UNSENT' IN request_body::text)>0),'only selected decoded fields go to provider, never full input');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets q,jsonb_array_elements(q.data->'supports') s WHERE s->>'quote' IS DISTINCT FROM substr(s->>'text',(s->>'start')::integer+1,(s->>'end')::integer-(s->>'start')::integer)),'decoded support spans exact');
SELECT pg_temp.assert_true(NOT has_function_privilege('egi_editorial','preparation.freeze_workbench_packet(uuid,bigint,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb)','EXECUTE'),'no arbitrary provider data writer');
CREATE FUNCTION pg_temp.make_workbench_cards(wid uuid,iid uuid,n integer) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE ids uuid[]:='{}'; r jsonb; v jsonb; p jsonb; i integer;
BEGIN
 FOR i IN 1..n LOOP
  r:=preparation.create_items(wid,iid,NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0;
  v:=preparation.read_item(wid,(r->>'item_id')::uuid,NULL)->'version';
  p:=(v->'payload')||jsonb_build_object('service',jsonb_build_object('description','Mensa'),'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),
   'path','/service/description','kind','stated','input_id',iid,'input_hash',preparation.read_input(wid,iid)->>'sha256','quote','Mensa','span',jsonb_build_object('start',18,'end',23))));
  PERFORM preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',r->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
  ids:=array_append(ids,(r->>'item_id')::uuid);
 END LOOP;
 RETURN ids;
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.make_workbench_cards(:'ws',:'inp',3) AS independent_cards \gset
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards','workbench-fixture-1',:'limits',gen_random_uuid()) AS packed_plan \gset
SELECT pg_temp.assert_true((:'packed_plan'::jsonb->>'total_packets')::integer=1 AND jsonb_array_length(:'packed_plan'::jsonb#>'{packets,0,required_record_ids}')=3,'multiple independent records share one bounded request');
RESET SESSION AUTHORIZATION;
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('workbench-fixture-2',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'context'::jsonb),100000,4500,1000,0,1000,clock_timestamp(),'synthetic, no provider');
UPDATE preparation.ai_settings SET config_version='workbench-fixture-2';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards','workbench-fixture-2',:'limits',gen_random_uuid()) AS split_plan \gset
SELECT pg_temp.assert_true((:'split_plan'::jsonb->>'total_packets')::integer=2 AND
 (SELECT sum(jsonb_array_length(x->'required_record_ids')) FROM jsonb_array_elements(:'split_plan'::jsonb->'packets') x)=3,'output bound splits independent records with complete unique membership');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.expect_error('UPDATE preparation.analysis_plans SET snapshot_key=''changed''','55000');
SELECT pg_temp.expect_error('DELETE FROM preparation.plan_events','55000');
CREATE ROLE egi_probe35_retention LOGIN IN ROLE egi_retention;
SET SESSION AUTHORIZATION egi_probe35_retention;
SELECT pg_temp.expect_error(format('SELECT preparation.purge_job_payloads(%L)',:'ws'),'42501');
RESET SESSION AUTHORIZATION;
UPDATE preparation.workspaces SET state='trash',trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe35_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_plans WHERE workspace_id=:'ws') AND NOT EXISTS(SELECT FROM preparation.shared_contexts WHERE workspace_id=:'ws'),'expired private plan/context payloads purged before input removal');
ROLLBACK;
