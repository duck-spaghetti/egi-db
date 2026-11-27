-- Explicit requested tasks, all-task lifecycle and outcome-derived abstention.
\set keep_coverage_transaction 1
\ir 36-workbench-coverage.sql
\unset keep_coverage_transaction
SELECT jsonb_set(jsonb_set(:'limits','{max_total_packets}','10'),'{max_followup_packets}','6') AS workflow_limits,gen_random_uuid() AS workflow_key \gset
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],NULL,:'workflow_limits',:'workflow_key',ARRAY['group_labels','classify_cards']) AS both_plan \gset
SELECT pg_temp.assert_true(preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],NULL,:'workflow_limits',:'workflow_key')=:'both_plan'::jsonb,'canonical tasks replay matches legacy both-task API');
SELECT pg_temp.expect_error(format('SELECT preparation.preview_analysis_plan(%L,ARRAY[%L::uuid],NULL,%L,%L,ARRAY[''group_labels''])',:'ws',:'item',:'workflow_limits',:'workflow_key'),'40001','plan_request_conflict');
SELECT pg_temp.expect_error(format('SELECT preparation.preview_analysis_plan(%L,ARRAY[%L::uuid],NULL,%L,gen_random_uuid(),ARRAY[''group_labels'',''group_labels''])',:'ws',:'item',:'workflow_limits'),'22023','invalid_analysis_tasks');
SELECT preparation.start_analysis_plan(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'plan_id';
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS workflow_claim \gset
SELECT preparation.start_dispatch((:'workflow_claim'::jsonb->>'job_id')::uuid,:'workflow_claim'::jsonb->>'lease') AS workflow_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT jsonb_set(pg_temp.workbench_result(:'workflow_claim'::jsonb->'eligible_payload','insufficient_context'),'{unit_results,0,state}','"analyzed"') AS false_credit \gset
SELECT pg_temp.assert_true((SELECT preparation.reconcile_workbench_result(a,:'false_credit')#>>'{unit_results,0,state}'='insufficient_context' FROM preparation.analysis_packets a WHERE a.packet_id=(:'workflow_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid),'attributable abstention overrides caller analyzed state');
SELECT pg_temp.expect_error(format('SELECT preparation.validate_workbench_result(a,%L) FROM preparation.analysis_packets a WHERE a.packet_id=%L',:'false_credit',:'workflow_claim'::jsonb#>>'{eligible_payload,packet_key}'),'22023','workbench_state_outcome_mismatch');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'workflow_claim'::jsonb->>'job_id')::uuid,(:'workflow_dispatch'::jsonb->>'dispatch_id')::uuid,:'workflow_claim'::jsonb->>'lease',:'false_credit','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1) AS queued_comparison \gset
SELECT pg_temp.assert_true(:'queued_comparison'::jsonb->>'progress'='running' AND :'queued_comparison'::jsonb#>>'{record_coverage,validated_records}'='0' AND :'queued_comparison'::jsonb#>>'{record_coverage,insufficient_context_records}'='1','queued comparison remains live while all classification outcomes abstain');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS group_claim \gset
SELECT preparation.start_dispatch((:'group_claim'::jsonb->>'job_id')::uuid,:'group_claim'::jsonb->>'lease') AS group_dispatch \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.assert_true(preparation.read_analysis_coverage(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1)->>'progress'='running','running comparison keeps polling live');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.fail_job((:'group_claim'::jsonb->>'job_id')::uuid,:'group_claim'::jsonb->>'lease','provider_timeout',true);
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.assert_true(preparation.read_analysis_coverage(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1)->>'progress'='waiting_retry','comparison unknown exposes explicit retry');
SELECT preparation.retry_uncertain_analysis_packet(:'ws',(:'group_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid,gen_random_uuid())->>'packet_id';
RESET SESSION AUTHORIZATION;
SELECT committed_microusd AS workflow_committed FROM preparation.budget_periods WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date \gset
UPDATE preparation.budget_periods SET committed_microusd=limit_microusd-reserved_microusd-1 WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS budget_group \gset
SELECT pg_temp.assert_true(preparation.start_dispatch((:'budget_group'::jsonb->>'job_id')::uuid,:'budget_group'::jsonb->>'lease')->>'code'='budget_exceeded','comparison capped before paid dispatch');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.assert_true(preparation.read_analysis_coverage(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1)->>'progress'='waiting_budget','comparison budget failure is actionable, not terminal analysis');
RESET SESSION AUTHORIZATION;
UPDATE preparation.budget_periods SET committed_microusd=:'workflow_committed' WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.assert_true(preparation.continue_analysis_plan(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'progress'='running','explicit continue retries unresolved comparison after budget restoration');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS resumed_group \gset
SELECT preparation.start_dispatch((:'resumed_group'::jsonb->>'job_id')::uuid,:'resumed_group'::jsonb->>'lease') AS resumed_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT jsonb_build_object('schema_version',1,'task','group_labels','request_digest',preparation.workbench_digest(:'resumed_group'::jsonb->'eligible_payload'),'state','complete','unit_results',jsonb_build_array(jsonb_build_object('unit_key',:'resumed_group'::jsonb#>'{eligible_payload,data,units,0,unit_key}','record_key',NULL,'state','insufficient_context','processed_basis_keys','[]'::jsonb,'unprocessed_basis_keys','[]'::jsonb,'proposal_keys','[]'::jsonb,'hypotheses','[]'::jsonb,'diagnostics','["insufficient_context"]'::jsonb)),'unprocessed_unit_keys','[]'::jsonb,'proposals','[]'::jsonb,'diagnostics','[]'::jsonb) AS group_abstention \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'resumed_group'::jsonb->>'job_id')::uuid,(:'resumed_dispatch'::jsonb->>'dispatch_id')::uuid,:'resumed_group'::jsonb->>'lease',:'group_abstention','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'both_plan'::jsonb->>'plan_id')::uuid,1) AS done_workflow \gset
SELECT pg_temp.assert_true(:'done_workflow'::jsonb->>'progress'='finished' AND (:'done_workflow'::jsonb#>'{comparison_coverage,limitations}') ? 'insufficient_context','settled comparison removes historical unknown/budget blockers but preserves abstention');
SELECT jsonb_set(jsonb_set(:'workflow_limits','{max_total_packets}','1'),'{max_followup_packets}','0') AS primary_limits \gset
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],NULL,:'primary_limits',gen_random_uuid(),ARRAY['group_labels']) AS only_group \gset
SELECT preparation.read_analysis_coverage(:'ws',(:'only_group'::jsonb->>'plan_id')::uuid,1) AS only_group_coverage \gset
SELECT pg_temp.assert_true(:'only_group'::jsonb->>'planned_request_count'='1' AND :'only_group'::jsonb#>>'{packets,0,task}'='group_labels' AND :'only_group'::jsonb#>>'{packets,0,stage}'='initial' AND :'only_group'::jsonb#>'{packets,0,required_record_ids}'='[]'::jsonb AND jsonb_array_length(:'only_group'::jsonb#>'{packets,0,reference_record_ids}')=1,'group-only primary work fits zero followups and one paid ceiling');
SELECT pg_temp.assert_true(:'only_group_coverage'::jsonb->'analysis_requested'='false'::jsonb AND :'only_group_coverage'::jsonb#>>'{record_coverage,selected_records}'='0' AND :'only_group_coverage'::jsonb#>>'{records,0,reason}'='analysis_not_requested' AND :'only_group_coverage'::jsonb#>'{records,0,state}'='null'::jsonb AND :'only_group_coverage'::jsonb->>'selected_record_count'='1','reference records never receive classification credit or perpetual pending');
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'item'::uuid],NULL,:'primary_limits',gen_random_uuid(),ARRAY['classify_cards']) AS only_classify \gset
SELECT pg_temp.assert_true(:'only_classify'::jsonb->>'planned_request_count'='1' AND :'only_classify'::jsonb#>'{stage_policy,tasks}'='["classify_cards"]'::jsonb AND preparation.read_analysis_coverage(:'ws',(:'only_classify'::jsonb->>'plan_id')::uuid,1)#>>'{records,0,comparison_state}'='not_requested','classification-only has no phantom comparison work');
SELECT preparation.amend_analysis_plan(:'ws',(:'only_classify'::jsonb->>'plan_id')::uuid,1,ARRAY[:'item'::uuid],NULL,:'primary_limits',gen_random_uuid(),ARRAY['group_labels']) AS amended_tasks \gset
SELECT pg_temp.assert_true(:'amended_tasks'::jsonb#>'{stage_policy,tasks}'='["group_labels"]'::jsonb AND :'amended_tasks'::jsonb->>'plan_id'<>:'only_classify'::jsonb->>'plan_id','amendment has visible identity and frozen selected tasks');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM preparation.analysis_packets WHERE plan_id=(:'only_group'::jsonb->>'plan_id')::uuid AND task='classify_cards'),'no hidden classification packet');
ROLLBACK;
