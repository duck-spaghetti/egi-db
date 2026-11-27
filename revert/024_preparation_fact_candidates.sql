-- Revert egi_database:024_preparation_fact_candidates
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.ai_configurations WHERE provider_config->'interpretation_version'='2'::jsonb) OR
  EXISTS(SELECT FROM preparation.jobs WHERE output->'schema_version'='2'::jsonb) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='fact_candidate_protocol_in_use'; END IF;
END $$;
DROP FUNCTION preparation.merge_candidate(jsonb,jsonb,uuid,uuid);
ALTER FUNCTION preparation.merge_candidate_v1(jsonb,jsonb,uuid,uuid) RENAME TO merge_candidate;
DROP FUNCTION preparation.validate_job_result(preparation.jobs,jsonb);
ALTER FUNCTION preparation.validate_job_result_v1(preparation.jobs,jsonb) RENAME TO validate_job_result;
DROP FUNCTION preparation.literal_candidate_payload(jsonb,uuid,uuid);
COMMIT;
