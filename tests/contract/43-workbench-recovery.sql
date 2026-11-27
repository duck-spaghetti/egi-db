-- Monthly-budget refusal, explicit unknown replacement, partial continuation and comparison.
\set keep_proposal_transaction 1
\ir 38-workbench-proposals.sql
\unset keep_proposal_transaction
SELECT committed_microusd AS saved_committed FROM preparation.budget_periods WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date \gset
UPDATE preparation.budget_periods SET committed_microusd=limit_microusd-reserved_microusd-1 WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date;
SELECT jsonb_set(jsonb_set(:'limits','{max_total_packets}','8'),'{max_followup_packets}','4') AS recovery_limits \gset
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards',NULL,:'recovery_limits',gen_random_uuid()) AS recovery_plan \gset
SELECT preparation.start_analysis_plan(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'plan_id';
RESET SESSION AUTHORIZATION;
SELECT count(*) AS reservations_before FROM preparation.budget_reservations \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS budget_claim \gset
SELECT preparation.start_dispatch((:'budget_claim'::jsonb->>'job_id')::uuid,:'budget_claim'::jsonb->>'lease') AS budget_dispatch \gset
SELECT pg_temp.assert_true(:'budget_dispatch'::jsonb->>'code'='budget_exceeded','monthly ceiling blocks before issuing dispatch');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM preparation.budget_reservations)=:'reservations_before'::integer AND (SELECT dispatch_id IS NULL FROM preparation.jobs WHERE id=(:'budget_claim'::jsonb->>'job_id')::uuid),'budget refusal creates neither dispatch nor reservation');
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1) AS waiting_budget \gset
SELECT pg_temp.assert_true(:'waiting_budget'::jsonb->>'progress'='waiting_budget' AND :'waiting_budget'::jsonb#>>'{record_coverage,pending_records}'='3' AND :'waiting_budget'::jsonb#>>'{record_coverage,blocked_records}'='0','pre-dispatch budget wait is actionable pending analysis, not an invalid model result');
RESET SESSION AUTHORIZATION;
UPDATE preparation.budget_periods SET committed_microusd=:'saved_committed' WHERE period_start=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.continue_analysis_plan(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'progress';
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS uncertain_claim \gset
SELECT preparation.start_dispatch((:'uncertain_claim'::jsonb->>'job_id')::uuid,:'uncertain_claim'::jsonb->>'lease') AS uncertain_dispatch \gset
SELECT preparation.fail_job((:'uncertain_claim'::jsonb->>'job_id')::uuid,:'uncertain_claim'::jsonb->>'lease','provider_timeout',true);
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.retry_uncertain_analysis_packet(:'ws',(:'uncertain_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid,gen_random_uuid())->>'packet_id';
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT state='uncertain' AND cancelled_at IS NOT NULL FROM preparation.jobs WHERE id=(:'uncertain_claim'::jsonb->>'job_id')::uuid) AND (SELECT state='uncertain' FROM preparation.budget_reservations WHERE job_id=(:'uncertain_claim'::jsonb->>'job_id')::uuid),'explicit replacement revokes old result applicability but keeps unknown spend held');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS replacement_claim \gset
SELECT preparation.start_dispatch((:'replacement_claim'::jsonb->>'job_id')::uuid,:'replacement_claim'::jsonb->>'lease') AS replacement_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.workbench_result(:'replacement_claim'::jsonb->'eligible_payload') AS partial \gset
SELECT (:'partial'::jsonb)||jsonb_build_object('state','incomplete','unit_results',jsonb_build_array(:'partial'::jsonb#>'{unit_results,0}'),
 'unprocessed_unit_keys',(SELECT jsonb_agg(u->'unit_key') FROM jsonb_array_elements(:'replacement_claim'::jsonb#>'{eligible_payload,data,units}') WITH ORDINALITY e(u,n) WHERE n>1),
 'proposals',(SELECT jsonb_agg(p) FROM jsonb_array_elements(:'partial'::jsonb->'proposals') p WHERE (:'partial'::jsonb#>'{unit_results,0,processed_basis_keys}') @> jsonb_build_array(p->'basis_key')),'diagnostics','["provider_incomplete"]'::jsonb) AS partial \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'replacement_claim'::jsonb->>'job_id')::uuid,(:'replacement_dispatch'::jsonb->>'dispatch_id')::uuid,:'replacement_claim'::jsonb->>'lease',:'partial','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1) AS known_partial \gset
SELECT pg_temp.assert_true(:'known_partial'::jsonb#>>'{record_coverage,validated_records}'='1' AND :'known_partial'::jsonb#>>'{record_coverage,pending_records}'='2','honest incomplete output retains one record and leaves two pending');
SELECT preparation.continue_analysis_plan(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'progress';
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS residual_claim \gset
SELECT preparation.start_dispatch((:'residual_claim'::jsonb->>'job_id')::uuid,:'residual_claim'::jsonb->>'lease') AS residual_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(jsonb_array_length(:'residual_claim'::jsonb#>'{eligible_payload,data,records}')=2,'continuation excludes the validated replacement record');
SELECT pg_temp.workbench_result(:'residual_claim'::jsonb->'eligible_payload') AS residual_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'residual_claim'::jsonb->>'job_id')::uuid,(:'residual_dispatch'::jsonb->>'dispatch_id')::uuid,:'residual_claim'::jsonb->>'lease',:'residual_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
SELECT preparation.claim_job(gen_random_uuid()) AS comparison_claim \gset
SELECT pg_temp.assert_true(:'comparison_claim'::jsonb->>'task'='group_labels','superseded unknown predecessor and partial original do not block cumulative comparison');
SELECT preparation.start_dispatch((:'comparison_claim'::jsonb->>'job_id')::uuid,:'comparison_claim'::jsonb->>'lease') AS comparison_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*)=count(DISTINCT p->>'proposal_key') AND bool_and(length(p->>'proposal_key')<=100) FROM jsonb_array_elements(:'comparison_claim'::jsonb#>'{eligible_payload,data,prior_proposals}') p),'cross-packet prior keys are unique, scoped and profile bounded');
SELECT jsonb_build_object('schema_version',1,'task','group_labels','request_digest',preparation.workbench_digest(:'comparison_claim'::jsonb->'eligible_payload'),'state','complete','unit_results',jsonb_build_array(jsonb_build_object('unit_key',:'comparison_claim'::jsonb#>'{eligible_payload,data,units,0,unit_key}','record_key',NULL,'state','insufficient_context','processed_basis_keys','[]'::jsonb,'unprocessed_basis_keys','[]'::jsonb,'proposal_keys','[]'::jsonb,'hypotheses','[]'::jsonb,'diagnostics','["insufficient_context"]'::jsonb)),'unprocessed_unit_keys','[]'::jsonb,'proposals','[]'::jsonb,'diagnostics','[]'::jsonb) AS comparison_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'comparison_claim'::jsonb->>'job_id')::uuid,(:'comparison_dispatch'::jsonb->>'dispatch_id')::uuid,:'comparison_claim'::jsonb->>'lease',:'comparison_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_analysis_coverage(:'ws',(:'recovery_plan'::jsonb->>'plan_id')::uuid,1,0,1) AS recovered \gset
SELECT pg_temp.assert_true(:'recovered'::jsonb->>'progress'='finished' AND :'recovered'::jsonb#>>'{record_coverage,validated_records}'='3' AND (:'recovered'::jsonb#>'{comparison_coverage,limitations}') @> '["insufficient_context"]'::jsonb,'finished scoped comparison abstention remains globally visible on every record page');
RESET SESSION AUTHORIZATION;
SELECT count(*) AS results_before_late FROM preparation.workbench_unit_results \gset
SELECT pg_temp.workbench_result(:'uncertain_claim'::jsonb->'eligible_payload') AS late_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'uncertain_claim'::jsonb->>'job_id')::uuid,(:'uncertain_dispatch'::jsonb->>'dispatch_id')::uuid,:'uncertain_claim'::jsonb->>'lease',:'late_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT state='settled' FROM preparation.budget_reservations WHERE job_id=(:'uncertain_claim'::jsonb->>'job_id')::uuid) AND (SELECT output IS NULL FROM preparation.jobs WHERE id=(:'uncertain_claim'::jsonb->>'job_id')::uuid) AND (SELECT count(*) FROM preparation.workbench_unit_results)=:'results_before_late'::integer,'late old usage settles once while revoked content earns no duplicate coverage');
ROLLBACK;
