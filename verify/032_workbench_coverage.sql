BEGIN;
SELECT 'preparation.workbench_unit_results'::regclass;
SELECT 'preparation.read_analysis_coverage(uuid,uuid,bigint,integer,integer)'::regprocedure;
SELECT 1/CASE WHEN has_function_privilege('egi_preparation_worker','preparation.claim_job(uuid)','EXECUTE') AND NOT has_function_privilege('egi_preparation_worker','preparation.claim_job_text(uuid)','EXECUTE') THEN 1 ELSE 0 END;
ROLLBACK;
