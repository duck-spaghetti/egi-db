-- Verify egi_database:024_preparation_fact_candidates
BEGIN;
SELECT 1/(to_regprocedure('preparation.literal_candidate_payload(jsonb,uuid,uuid)') IS NOT NULL)::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.literal_candidate_payload(jsonb,uuid,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','preparation.validate_job_result(preparation.jobs,jsonb)','EXECUTE'))::int;
ROLLBACK;
