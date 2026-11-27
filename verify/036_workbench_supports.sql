BEGIN;
SELECT 1/CASE WHEN position('support->''record_key''' IN pg_get_functiondef('preparation.validate_workbench_result(preparation.analysis_packets,jsonb)'::regprocedure))>0 THEN 1 ELSE 0 END;
ROLLBACK;
