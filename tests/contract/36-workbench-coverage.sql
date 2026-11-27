-- Real worker leasing/settlement and independent incomplete-unit recovery.
\set keep_workbench_transaction 1
\ir 35-workbench-plans.sql
\unset keep_workbench_transaction
CREATE FUNCTION pg_temp.workbench_result(req jsonb,unit_state text DEFAULT 'analyzed') RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object('schema_version',1,'task',req->>'task','request_digest',preparation.workbench_digest(req),'state','complete',
  'unit_results',(SELECT jsonb_agg(jsonb_build_object('unit_key',u->'unit_key','record_key',u->'record_key','state',unit_state,'processed_basis_keys',u->'basis_keys','unprocessed_basis_keys','[]'::jsonb,
   'proposal_keys',(SELECT jsonb_agg('p:'||(k#>>'{}')) FROM jsonb_array_elements(u->'basis_keys') k),'hypotheses','[]'::jsonb,'diagnostics','[]'::jsonb)) FROM jsonb_array_elements(req#>'{data,units}') u),
  'unprocessed_unit_keys','[]'::jsonb,'diagnostics','[]'::jsonb,
  'proposals',(SELECT jsonb_agg(jsonb_build_object('proposal_key','p:'||(b->>'basis_key'),'basis_key',b->'basis_key','state',CASE WHEN unit_state='insufficient_context' THEN 'insufficient_context' ELSE 'no_supplied_match' END,'choices','[]'::jsonb,'missing_context','[]'::jsonb)) FROM jsonb_array_elements(req#>'{data,bases}') b));
$$;
CREATE ROLE egi_probe36_worker LOGIN IN ROLE egi_preparation_worker;
SET SESSION AUTHORIZATION egi_probe30;
SELECT gen_random_uuid() AS start_key \gset
SELECT preparation.start_analysis_plan(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1,:'start_key') AS started \gset
SELECT pg_temp.assert_true(preparation.start_analysis_plan(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1,:'start_key')=:'started'::jsonb,'explicit start receipt idempotent');
SELECT preparation.read_analysis_coverage(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1,0,1) AS coverage \gset
SELECT pg_temp.assert_true(:'coverage'::jsonb#>>'{record_coverage,selected_records}'='3' AND :'coverage'::jsonb#>>'{record_coverage,pending_records}'='3' AND jsonb_array_length(:'coverage'::jsonb->'records')=1 AND :'coverage'::jsonb->>'next_record_offset'='1','all manifest pages reconcile independently of displayed page');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM preparation.jobs)=2 AND NOT EXISTS(SELECT FROM preparation.budget_reservations),'one job per bounded packet, no reservation until dispatch');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim \gset
SELECT pg_temp.assert_true(:'claim'::jsonb#>>'{eligible_payload,task}'='classify_cards' AND :'claim'::jsonb->'locator_map'='null'::jsonb AND position('PRIVATE UNSENT' IN (:'claim'::jsonb->'eligible_payload')::text)=0,'worker receives source-safe projected packet only');
SELECT preparation.start_dispatch((:'claim'::jsonb->>'job_id')::uuid,:'claim'::jsonb->>'lease') AS dispatch \gset
RESET SESSION AUTHORIZATION;
\pset tuples_only on
\pset format unaligned
\o /private/tmp/egi-cw1-model-request.json
SELECT jsonb_build_object('request',:'claim'::jsonb->'eligible_payload','digest',preparation.workbench_digest(:'claim'::jsonb->'eligible_payload'))::text;
\o
\pset tuples_only off
\pset format aligned
SELECT jsonb_set(pg_temp.workbench_result(:'claim'::jsonb->'eligible_payload'),'{unit_results,1,processed_basis_keys}','["foreign-basis"]') AS result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'claim'::jsonb->>'job_id')::uuid,(:'dispatch'::jsonb->>'dispatch_id')::uuid,:'claim'::jsonb->>'lease',:'result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}') AS finished \gset
SELECT pg_temp.assert_true(preparation.finish_job((:'claim'::jsonb->>'job_id')::uuid,(:'dispatch'::jsonb->>'dispatch_id')::uuid,:'claim'::jsonb->>'lease',:'result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}')=:'finished'::jsonb,'raw worker replay normalizes to same settled receipt');
SELECT pg_temp.expect_error(format('SELECT preparation.read_analysis_coverage(%L,%L,1)',:'ws',:'split_plan'::jsonb->>'plan_id'),'42501');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM preparation.workbench_unit_results)=1,'valid unit survives invalid sibling, foreign basis has no credit');
SELECT pg_temp.assert_true((SELECT state='settled' FROM preparation.budget_reservations WHERE job_id=(:'claim'::jsonb->>'job_id')::uuid),'invalid sibling never discards usage settlement');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim2 \gset
SELECT preparation.start_dispatch((:'claim2'::jsonb->>'job_id')::uuid,:'claim2'::jsonb->>'lease') AS dispatch2 \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.workbench_result(:'claim2'::jsonb->'eligible_payload','insufficient_context') AS result2 \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'claim2'::jsonb->>'job_id')::uuid,(:'dispatch2'::jsonb->>'dispatch_id')::uuid,:'claim2'::jsonb->>'lease',:'result2','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1) AS coverage \gset
SELECT pg_temp.assert_true(:'coverage'::jsonb#>>'{record_coverage,validated_records}'='1' AND :'coverage'::jsonb#>>'{record_coverage,insufficient_context_records}'='1' AND :'coverage'::jsonb#>>'{record_coverage,blocked_records}'='1' AND :'coverage'::jsonb->>'progress'='finished_with_gaps','validated, abstained and blocked records remain disjoint');
SELECT preparation.continue_analysis_plan(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid()) AS continued \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM preparation.analysis_packets WHERE stage='remaining_record_analysis')=1,'explicit continuation freezes only unresolved scope');
SELECT pg_temp.assert_true((SELECT jsonb_array_length(manifest->'required_record_ids') FROM preparation.analysis_packets WHERE stage='remaining_record_analysis')=1,'already validated records never requeued as primary');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim3 \gset
SELECT preparation.start_dispatch((:'claim3'::jsonb->>'job_id')::uuid,:'claim3'::jsonb->>'lease') AS dispatch3 \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.workbench_result(:'claim3'::jsonb->'eligible_payload') AS result3 \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'claim3'::jsonb->>'job_id')::uuid,(:'dispatch3'::jsonb->>'dispatch_id')::uuid,:'claim3'::jsonb->>'lease',:'result3','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'split_plan'::jsonb->>'plan_id')::uuid,1) AS final_coverage \gset
SELECT pg_temp.assert_true(:'final_coverage'::jsonb->>'progress'='finished' AND :'final_coverage'::jsonb#>>'{record_coverage,validated_records}'='2' AND :'final_coverage'::jsonb#>>'{record_coverage,insufficient_context_records}'='1','unique coverage across continuation completes declared scope');
RESET SESSION AUTHORIZATION;
\if :{?keep_coverage_transaction}
\else
ROLLBACK;
\endif
