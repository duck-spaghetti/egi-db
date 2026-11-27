-- Native source eligibility, contextual metadata and explicit interpretation inputs.
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
 VALUES('context-fixture-1',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'context'::jsonb,'model','fixture-model','provider','fixture'),200000,10000,1000,0,1000,clock_timestamp(),'synthetic, no provider');
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('context-fixture-1',true);
CREATE FUNCTION pg_temp.context_card(wid uuid,iid uuid,literal boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE created jsonb; v jsonb; p jsonb; saved jsonb; path text; fact uuid:=gen_random_uuid();
BEGIN
 created:=preparation.create_items(wid,iid,NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0;
 v:=preparation.read_item(wid,(created->>'item_id')::uuid,NULL)->'version'; p:=v->'payload';
 IF literal THEN
  p:=p||jsonb_build_object('schema_version',2,'source_facts',jsonb_build_array(jsonb_build_object('fact_id',fact,'kind','category_label','subject','service','source_value','Mensa','value','Mensa')),
   'resolutions','[]'::jsonb,'field_origins',jsonb_build_object('/source_facts/0/source_value',jsonb_build_object('state','manual'),'/source_facts/0/value',jsonb_build_object('state','manual')));
  path:='/source_facts/0/source_value';
 ELSE p:=p||jsonb_build_object('service',jsonb_build_object('description','Mensa')); path:='/service/description'; END IF;
 p:=p||jsonb_build_object('evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path',path,'kind','stated','input_id',iid,'input_hash',preparation.read_input(wid,iid)->>'sha256','quote','Mensa','span',jsonb_build_object('start',18,'end',23))));
 saved:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',created->>'item_id','expected_version',v->>'id','payload',p)),gen_random_uuid());
 RETURN jsonb_build_object('item_id',created->>'item_id','version_id',saved#>>'{items,0,after}');
END $$;
CREATE FUNCTION pg_temp.materialize_context(wid uuid,item uuid,context jsonb,target jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v jsonb; p jsonb; basis jsonb; interpretation uuid:=gen_random_uuid(); eid text;
BEGIN
 v:=preparation.read_item(wid,item,NULL)->'version'; p:=v->'payload'; eid:=p#>>'{evidence,0,id}';
 basis:=jsonb_build_object('item_version',v->>'id','field_path','/service/description','value_digest',encode(sha256(convert_to((p#>'{service,description}')::text,'UTF8')),'hex'),'evidence_ids',jsonb_build_array(eid));
 p:=p||jsonb_build_object('schema_version',3,'source_facts','[]'::jsonb,'resolutions','[]'::jsonb,'interpreted_classifications',jsonb_build_array(jsonb_build_object(
  'interpretation_id',interpretation,'basis',basis,'context',context,'candidates',jsonb_build_array(jsonb_build_object('target',target,'reason','PRIVATE REASON MUST NOT LEAVE','support_evidence_ids',jsonb_build_array(eid))),
  'state','proposed','selected',NULL,'method','manual','job_id',NULL)),'interpretation_hypotheses','[]'::jsonb);
 PERFORM preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',v->>'id','payload',p)),gen_random_uuid());
 RETURN interpretation;
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.context_card(:'ws',:'inp',true) AS literal_card,pg_temp.context_card(:'ws',:'inp',false) AS description_card1,pg_temp.context_card(:'ws',:'inp',false) AS description_card2 \gset
SELECT '{"max_total_packets":5,"max_followup_packets":2,"max_reserved_micro_usd":1000000,"allowed_followup_kinds":["remaining_record_analysis","cross_packet_comparison"]}'::jsonb AS limits \gset
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[(:'literal_card'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS literal_plan \gset
SELECT pg_temp.assert_true(:'literal_plan'::jsonb->>'configuration_version'='context-fixture-1' AND (:'literal_plan'::jsonb->>'planned_request_count')::integer=2,'NULL configuration resolves current settings and operator-selected quoted raw label remains grouped');
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[(:'description_card1'::jsonb->>'item_id')::uuid,(:'description_card2'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS before_materialization \gset
SELECT pg_temp.assert_true((:'before_materialization'::jsonb->>'planned_request_count')::integer=1 AND
 (SELECT count(*) FROM jsonb_array_elements(:'before_materialization'::jsonb->'events') x WHERE x#>>'{body,code}'='awaiting_materialization')=2,'description-only records await explicit materialization for grouping');
SELECT (:'context'::jsonb->'context')||jsonb_build_object('catalog_digest',:'context'::jsonb->>'digest','as_of',current_date) AS interpretation_context \gset
SELECT pg_temp.materialize_context(:'ws',(:'description_card1'::jsonb->>'item_id')::uuid,:'interpretation_context',:'context'::jsonb#>'{entries,0,target}') AS interpretation1,
 pg_temp.materialize_context(:'ws',(:'description_card2'::jsonb->>'item_id')::uuid,:'interpretation_context',:'context'::jsonb#>'{entries,0,target}') AS interpretation2 \gset
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[(:'description_card1'::jsonb->>'item_id')::uuid,(:'description_card2'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS materialized_plan \gset
SELECT pg_temp.assert_true((:'materialized_plan'::jsonb->>'planned_request_count')::integer=2 AND :'materialized_plan'::jsonb#>>'{shared_context,inventory_coverage,supplied_labels}'='1' AND
 :'materialized_plan'::jsonb#>>'{shared_context,label_inventory,0,count}'='2','distinct interpreted units share aggregated unique label inventory');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets p,jsonb_array_elements(p.data->'bases') b WHERE b->>'kind'='source_context'),'metadata is contextual support and never an independently required classification basis');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_packets p,jsonb_array_elements(p.data->'supports') s WHERE s->>'origin'='source_metadata'),'metadata retained as weaker contextual support');
SELECT pg_temp.assert_true((SELECT jsonb_array_length(comparison_seed->'labels')=2 AND jsonb_array_length(comparison_seed->'prior_proposals')=2 FROM preparation.analysis_plans WHERE plan_id=(:'materialized_plan'::jsonb->>'plan_id')::uuid),'explicit materialized interpretation units and all alternatives retained separately');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets WHERE position('PRIVATE REASON' IN request_body::text)>0 OR position('PRIVATE UNSENT' IN request_body::text)>0) AND
 (SELECT position('PRIVATE REASON' IN comparison_seed::text)=0 FROM preparation.analysis_plans WHERE plan_id=(:'materialized_plan'::jsonb->>'plan_id')::uuid),'private interpretation prose and full input never become provider context');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets p JOIN preparation.ai_configurations c ON c.version='context-fixture-1' WHERE 2*octet_length(preparation.canonical_json(p.request_body))+33792>c.max_input_tokens),'complete duplicated request framing conservatively bounded');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.jobs),'all previews remain no-dispatch');
-- A materialized hypothesis without candidates is still explicit, but abstains safely.
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_item(:'ws',(:'description_card1'::jsonb->>'item_id')::uuid,NULL)->'version' AS no_candidate_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'description_card1'::jsonb->>'item_id','expected_version',:'no_candidate_version'::jsonb->>'id',
 'payload',jsonb_set(:'no_candidate_version'::jsonb->'payload','{interpreted_classifications,0,candidates}','[]'))),gen_random_uuid());
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[(:'description_card1'::jsonb->>'item_id')::uuid,(:'description_card2'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS no_candidate_plan \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_plans p,jsonb_array_elements(p.comparison_seed->'prior_proposals') prior WHERE p.plan_id=(:'no_candidate_plan'::jsonb->>'plan_id')::uuid
 AND prior->>'state'='insufficient_context' AND prior->'missing_context'='["insufficient_context"]'::jsonb),'zero retained candidates disclose nonempty safe missing context');
SELECT jsonb_set(jsonb_set(:'context'::jsonb,'{entries}','[]'),'{complete}','false')-'digest' AS sliced_context \gset
SELECT :'sliced_context'::jsonb||jsonb_build_object('digest',preparation.workbench_digest(:'sliced_context')) AS sliced_context \gset
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('context-fixture-2',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'sliced_context'::jsonb,'model','fixture-model','provider','fixture'),200000,10000,1000,0,1000,clock_timestamp(),'synthetic, no provider');
UPDATE preparation.ai_settings SET config_version='context-fixture-2';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[(:'description_card1'::jsonb->>'item_id')::uuid,(:'description_card2'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS missing_catalog_plan \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_plans p,jsonb_array_elements(p.comparison_seed->'prior_proposals') prior WHERE p.plan_id=(:'missing_catalog_plan'::jsonb->>'plan_id')::uuid
 AND prior->'choices'='[]'::jsonb AND prior->'missing_context'='["incomplete_catalog"]'::jsonb),'unavailable actual catalog choices omitted with explicit catalog limitation');
ROLLBACK;
