-- Real category proposal -> dependent comparison -> deliberate private selection.
\set keep_coverage_transaction 1
\ir 36-workbench-coverage.sql
\unset keep_coverage_transaction
UPDATE preparation.ai_settings SET config_version='workbench-fixture-1';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS category_original \gset
SELECT jsonb_set(jsonb_set(:'category_original'::jsonb->'payload','{service,description}','"Mensa"'),'{evidence}',(:'category_original'::jsonb#>'{payload,evidence}')||jsonb_build_array((:'category_original'::jsonb#>'{payload,evidence,1}')||jsonb_build_object('id',gen_random_uuid(),'path','/service/description'))) AS category_payload \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'category_original'::jsonb->>'id','payload',:'category_payload'::jsonb)),gen_random_uuid());
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],'workbench-fixture-1',:'limits',gen_random_uuid()) AS category_plan \gset
SELECT preparation.start_analysis_plan(:'ws',(:'category_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid());
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS category_claim \gset
SELECT preparation.start_dispatch((:'category_claim'::jsonb->>'job_id')::uuid,:'category_claim'::jsonb->>'lease') AS category_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT b AS category_basis FROM jsonb_array_elements(:'category_claim'::jsonb#>'{eligible_payload,data,bases}') b WHERE b->>'kind'='category_label' \gset
SELECT pg_temp.workbench_result(:'category_claim'::jsonb->'eligible_payload') AS category_result \gset
SELECT jsonb_set(:'category_result','{proposals}',(SELECT jsonb_agg(CASE WHEN p->'basis_key'=:'category_basis'::jsonb->'basis_key' THEN p||jsonb_build_object('state','proposed','choices',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','reason','Source label and reviewed territorial context','support_keys',:'category_basis'::jsonb->'support_keys'))) ELSE p END) FROM jsonb_array_elements(:'category_result'::jsonb->'proposals') p)) AS category_result \gset
-- Unreadable/wrong envelope bindings earn nothing; duplicate scoped IDs never
-- pick an arbitrary first instance, and trigger-only support cannot prove a term.
SELECT q AS category_packet FROM preparation.analysis_packets q WHERE q.packet_id=(:'category_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid \gset
SELECT pg_temp.expect_error(format('SELECT preparation.reconcile_workbench_result(jsonb_populate_record(NULL::preparation.analysis_packets,%L),%L)',to_jsonb(:'category_packet'::preparation.analysis_packets),jsonb_set(:'category_result','{request_digest}',to_jsonb(repeat('0',64)))),'22023','invalid_workbench_result');
SELECT preparation.reconcile_workbench_result(:'category_packet'::preparation.analysis_packets,jsonb_set(:'category_result','{unit_results}',(:'category_result'::jsonb->'unit_results')||(:'category_result'::jsonb->'unit_results'))) AS duplicate_result \gset
SELECT pg_temp.assert_true(:'duplicate_result'::jsonb->'unit_results'='[]'::jsonb AND :'duplicate_result'::jsonb->>'state'='incomplete','duplicate unit supplies no coverage');
SELECT preparation.reconcile_workbench_result(:'category_packet'::preparation.analysis_packets,jsonb_set(:'category_result','{proposals}',(SELECT jsonb_agg(p) FROM jsonb_array_elements(:'category_result'::jsonb->'proposals') p WHERE p->'basis_key'<>:'category_basis'::jsonb->'basis_key'))) AS missing_outcome \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'missing_outcome'::jsonb#>'{unit_results,0,processed_basis_keys}')>0 AND (:'missing_outcome'::jsonb#>'{unit_results,0,unprocessed_basis_keys}') @> jsonb_build_array(:'category_basis'::jsonb->'basis_key'),'missing basis outcome demotes only that known basis and retains independent outcomes');
SELECT jsonb_set(:'category_result','{unit_results,0,hypotheses}',jsonb_build_array(jsonb_build_object('hypothesis_key','abbr','kind','abbreviation_expansion','statement','An unverified expansion','status','unverified','trigger_support_keys',:'category_basis'::jsonb->'support_keys','verification_needed',true))) AS trigger_result \gset
SELECT preparation.reconcile_workbench_result(:'category_packet'::preparation.analysis_packets,:'trigger_result') AS trigger_reconciled \gset
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM jsonb_array_elements(:'trigger_reconciled'::jsonb->'proposals') p WHERE p->'basis_key'=:'category_basis'::jsonb->'basis_key'),'hypothesis trigger alone never justifies category');
SELECT b AS description_basis FROM jsonb_array_elements(:'category_claim'::jsonb#>'{eligible_payload,data,bases}') b WHERE b->>'kind'='description' \gset
SELECT jsonb_set(:'category_result','{unit_results,0,hypotheses}',jsonb_build_array(jsonb_build_object('hypothesis_key','description-hypothesis','kind','abbreviation_expansion','statement','A separately reviewable unverified expansion','status','unverified','trigger_support_keys',:'description_basis'::jsonb->'support_keys','verification_needed',true))) AS category_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'category_claim'::jsonb->>'job_id')::uuid,(:'category_dispatch'::jsonb->>'dispatch_id')::uuid,:'category_claim'::jsonb->>'lease',:'category_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_packets WHERE plan_id=(:'category_plan'::jsonb->>'plan_id')::uuid AND task='group_labels'),'dependent comparison is frozen only after classified results exist');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_packets a,jsonb_array_elements(a.data->'prior_proposals') p WHERE a.plan_id=(:'category_plan'::jsonb->>'plan_id')::uuid AND a.task='group_labels' AND p->'basis_key'=:'category_basis'::jsonb->'basis_key' AND jsonb_array_length(p->'choices')=1 AND position(':' IN p->>'proposal_key')>0),'comparison receives original bases plus scoped prior alternatives');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS group_claim \gset
SELECT preparation.start_dispatch((:'group_claim'::jsonb->>'job_id')::uuid,:'group_claim'::jsonb->>'lease') AS group_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT jsonb_build_object('schema_version',1,'task','group_labels','request_digest',preparation.workbench_digest(:'group_claim'::jsonb->'eligible_payload'),'state','complete',
 'unit_results',(SELECT jsonb_agg(jsonb_build_object('unit_key',u->'unit_key','record_key',NULL,'state','analyzed','processed_basis_keys','[]'::jsonb,'unprocessed_basis_keys','[]'::jsonb,'proposal_keys','[]'::jsonb,'hypotheses','[]'::jsonb,'diagnostics','[]'::jsonb)) FROM jsonb_array_elements(:'group_claim'::jsonb#>'{eligible_payload,data,units}') u),
 'unprocessed_unit_keys','[]'::jsonb,'proposals','[]'::jsonb,'diagnostics','[]'::jsonb) AS group_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'group_claim'::jsonb->>'job_id')::uuid,(:'group_dispatch'::jsonb->>'dispatch_id')::uuid,:'group_claim'::jsonb->>'lease',:'group_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'category_plan'::jsonb->>'plan_id')::uuid,1) AS category_coverage \gset
SELECT pg_temp.assert_true(:'category_coverage'::jsonb->>'progress'='finished' AND jsonb_array_length(:'category_coverage'::jsonb#>'{comparison_coverage,completed_scope_keys}')=1,'comparison coverage is separate and complete only after comparison result');
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS before_materialization \gset
SELECT gen_random_uuid() AS select_key \gset
SELECT preparation.select_workbench_proposals(:'ws',(:'category_claim'::jsonb->>'job_id')::uuid,:'item',(:'before_materialization'::jsonb->>'id')::uuid,jsonb_build_array('p:'||(:'category_basis'::jsonb->>'basis_key')),:'select_key') AS selection \gset
SELECT pg_temp.assert_true(preparation.select_workbench_proposals(:'ws',(:'category_claim'::jsonb->>'job_id')::uuid,:'item',(:'before_materialization'::jsonb->>'id')::uuid,jsonb_build_array('p:'||(:'category_basis'::jsonb->>'basis_key')),:'select_key')=:'selection'::jsonb,'private proposal materialization has immutable idempotent receipt');
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS selected_version \gset
SELECT pg_temp.assert_true(:'selected_version'::jsonb#>>'{payload,schema_version}'='3' AND :'selected_version'::jsonb#>>'{payload,interpreted_classifications,0,state}'='proposed' AND :'selected_version'::jsonb#>'{payload,interpreted_classifications,0,selected}'='null'::jsonb AND jsonb_array_length(:'selected_version'::jsonb#>'{payload,source_facts}')=jsonb_array_length(:'before_materialization'::jsonb#>'{payload,source_facts}'),'selected model result assigns private server IDs and never confirms or fabricates source facts');
SELECT preparation.select_workbench_hypotheses(:'ws',(:'category_claim'::jsonb->>'job_id')::uuid,:'item',(:'selected_version'::jsonb->>'id')::uuid,'["description-hypothesis"]',gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,interpretation_hypotheses,0,state}'='unverified' AND preparation.read_item(:'ws',:'item',NULL)#>'{version,payload,interpretation_hypotheses,0,verification}'='null'::jsonb,'separate hypothesis selection remains unverified after prior category materialization');
SELECT preparation.read_analysis_coverage(:'ws',(:'category_plan'::jsonb->>'plan_id')::uuid,1) AS stale_coverage \gset
SELECT pg_temp.assert_true(:'stale_coverage'::jsonb#>>'{record_coverage,stale_records}'='1' AND jsonb_array_length(:'stale_coverage'::jsonb#>'{records,0,accepted_results}')=1 AND :'stale_coverage'::jsonb#>>'{records,0,context_digest}'=:'category_plan'::jsonb->>'context_digest','stale current applicability preserves accepted result audit links');
SELECT preparation.read_analysis_record_results(:'ws',(:'category_plan'::jsonb->>'plan_id')::uuid,1,:'item',0,1) AS result_page \gset
SELECT pg_temp.assert_true(:'result_page'::jsonb->>'total_results'='1' AND jsonb_array_length(:'result_page'::jsonb->'results')=1,'record proposal links have bounded authorized reader');
SELECT preparation.read_analysis_events(:'ws',(:'category_plan'::jsonb->>'plan_id')::uuid,1,0,1) AS event_page \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'event_page'::jsonb->'events')=1 AND :'event_page'::jsonb->>'next_event_id' IS NOT NULL,'event history exposes explicit bounded cursor');
SELECT pg_temp.expect_error(format('SELECT preparation.read_analysis_events(%L,%L,1,0,NULL)',:'ws',:'category_plan'::jsonb->>'plan_id'),'22023','invalid_event_page');
SELECT pg_temp.expect_error(format('SELECT preparation.read_analysis_coverage(%L,%L,1,0,NULL)',:'ws',:'category_plan'::jsonb->>'plan_id'),'22023','invalid_coverage_page');
SELECT pg_temp.expect_error(format('SELECT preparation.read_analysis_plan(%L,%L,1,NULL,1)',:'ws',:'category_plan'::jsonb->>'plan_id'),'22023','invalid_plan_page');
RESET SESSION AUTHORIZATION;
-- Explicit unknown retry is separately authorized and holds the old reservation.
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards','workbench-fixture-1',:'limits',gen_random_uuid()) AS unknown_plan \gset
SELECT preparation.start_analysis_plan(:'ws',(:'unknown_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid());
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS unknown_claim \gset
SELECT preparation.start_dispatch((:'unknown_claim'::jsonb->>'job_id')::uuid,:'unknown_claim'::jsonb->>'lease') AS unknown_dispatch \gset
SELECT preparation.fail_job((:'unknown_claim'::jsonb->>'job_id')::uuid,:'unknown_claim'::jsonb->>'lease','provider_timeout',true);
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'unknown_plan'::jsonb->>'plan_id')::uuid,1) AS unknown_coverage \gset
SELECT pg_temp.assert_true(:'unknown_coverage'::jsonb->>'progress'='waiting_retry','unknown dispatch never automatically retries');
SELECT gen_random_uuid() AS retry_key \gset
SELECT preparation.retry_uncertain_analysis_packet(:'ws',(:'unknown_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid,:'retry_key') AS retried \gset
SELECT pg_temp.assert_true(preparation.retry_uncertain_analysis_packet(:'ws',(:'unknown_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid,:'retry_key')=:'retried'::jsonb,'explicit paid retry receipt stable');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT state='uncertain' FROM preparation.budget_reservations WHERE job_id=(:'unknown_claim'::jsonb->>'job_id')::uuid),'old reservation remains held after explicit retry');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS retry_claim \gset
SELECT preparation.start_dispatch((:'retry_claim'::jsonb->>'job_id')::uuid,:'retry_claim'::jsonb->>'lease') AS retry_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.workbench_result(:'retry_claim'::jsonb->'eligible_payload') AS retry_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'retry_claim'::jsonb->>'job_id')::uuid,(:'retry_dispatch'::jsonb->>'dispatch_id')::uuid,:'retry_claim'::jsonb->>'lease',:'retry_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT state='uncertain' FROM preparation.budget_reservations WHERE job_id=(:'unknown_claim'::jsonb->>'job_id')::uuid) AND (SELECT state='settled' FROM preparation.budget_reservations WHERE job_id=(:'retry_claim'::jsonb->>'job_id')::uuid),'settling new dispatch never releases unknown old spend');
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.amend_analysis_plan(:'ws',(:'unknown_plan'::jsonb->>'plan_id')::uuid,1,:'independent_cards','workbench-fixture-1',jsonb_set(:'limits','{max_total_packets}','6'),gen_random_uuid()) AS amended \gset
SELECT pg_temp.assert_true(:'amended'::jsonb->>'plan_id'<>:'unknown_plan'::jsonb->>'plan_id' AND :'amended'::jsonb->>'snapshot_key'=:'unknown_plan'::jsonb->>'snapshot_key','changed limits create visible new immutable plan identity');
SELECT preparation.start_analysis_plan(:'ws',(:'amended'::jsonb->>'plan_id')::uuid,1,gen_random_uuid());
SELECT preparation.cancel_analysis_plan(:'ws',(:'amended'::jsonb->>'plan_id')::uuid,1,gen_random_uuid()) AS cancelled \gset
SELECT pg_temp.assert_true(:'cancelled'::jsonb->>'progress'='cancelled','plan cancellation remains visible after reload');
SELECT pg_temp.expect_error(format('SELECT preparation.continue_analysis_plan(%L,%L,1,gen_random_uuid())',:'ws',:'amended'::jsonb->>'plan_id'),'55000','analysis_plan_cancelled');
RESET SESSION AUTHORIZATION;
CREATE FUNCTION pg_temp.add_exact_label(wid uuid,items uuid[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE item uuid; v jsonb; p jsonb;
BEGIN
 FOREACH item IN ARRAY items LOOP
  v:=preparation.read_item(wid,item,NULL)->'version';
  p:=(v->'payload')||jsonb_build_object('schema_version',2,'source_facts',jsonb_build_array(jsonb_build_object('fact_id',gen_random_uuid(),'subject','service','kind','category_label','source_value','Mensa','value','Mensa')),'resolutions','[]'::jsonb,
   'evidence',(v#>'{payload,evidence}')||jsonb_build_array((v#>'{payload,evidence,0}')||jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value')));
  PERFORM preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',v->>'id','payload',p)),gen_random_uuid());
 END LOOP;
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.add_exact_label(:'ws',:'independent_cards');
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards','workbench-fixture-1',:'limits',gen_random_uuid()) AS repeated_plan \gset
SELECT preparation.start_analysis_plan(:'ws',(:'repeated_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid());
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS repeated_claim \gset
SELECT preparation.start_dispatch((:'repeated_claim'::jsonb->>'job_id')::uuid,:'repeated_claim'::jsonb->>'lease') AS repeated_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.workbench_result(:'repeated_claim'::jsonb->'eligible_payload') AS repeated_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'repeated_claim'::jsonb->>'job_id')::uuid,(:'repeated_dispatch'::jsonb->>'dispatch_id')::uuid,:'repeated_claim'::jsonb->>'lease',:'repeated_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
SELECT preparation.claim_job(gen_random_uuid()) AS repeated_group_claim \gset
SELECT preparation.start_dispatch((:'repeated_group_claim'::jsonb->>'job_id')::uuid,:'repeated_group_claim'::jsonb->>'lease') AS repeated_group_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(jsonb_array_length(:'repeated_group_claim'::jsonb#>'{eligible_payload,data,labels}')=1 AND :'repeated_group_claim'::jsonb#>>'{eligible_payload,data,labels,0,count}'='3','exact repeated label remains one contextual unit with three real occurrences');
SELECT jsonb_build_object('schema_version',1,'task','group_labels','request_digest',preparation.workbench_digest(:'repeated_group_claim'::jsonb->'eligible_payload'),'state','complete',
 'unit_results',jsonb_build_array(jsonb_build_object('unit_key',:'repeated_group_claim'::jsonb#>'{eligible_payload,data,units,0,unit_key}','record_key',NULL,'state','analyzed','processed_basis_keys','[]'::jsonb,'unprocessed_basis_keys','[]'::jsonb,'proposal_keys','["same-label"]'::jsonb,'hypotheses','[]'::jsonb,'diagnostics','[]'::jsonb)),
 'unprocessed_unit_keys','[]'::jsonb,'proposals',jsonb_build_array(jsonb_build_object('proposal_key','same-label','relation','equivalent','unit_keys',jsonb_build_array(:'repeated_group_claim'::jsonb#>'{eligible_payload,data,labels,0,unit_key}'),'membership_issues','[]'::jsonb,'choices','[]'::jsonb,'reason','Same original label in the same reviewed contextual scope','support_keys',(SELECT jsonb_agg(k) FROM jsonb_array_elements(:'repeated_group_claim'::jsonb#>'{eligible_payload,data,labels,0,occurrences}') o,jsonb_array_elements(o->'support_keys') k))),
 'diagnostics','[]'::jsonb) AS repeated_group_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'repeated_group_claim'::jsonb->>'job_id')::uuid,(:'repeated_group_dispatch'::jsonb->>'dispatch_id')::uuid,:'repeated_group_claim'::jsonb->>'lease',:'repeated_group_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT output#>>'{proposals,0,relation}'='equivalent' FROM preparation.jobs WHERE id=(:'repeated_group_claim'::jsonb->>'job_id')::uuid),'singleton contextual unit with multiple complete owned occurrences can form reviewed group');
\if :{?keep_proposal_transaction}
\else
ROLLBACK;
\endif
