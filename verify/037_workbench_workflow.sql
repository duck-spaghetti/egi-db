BEGIN;
SELECT 'preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid,text[])'::regprocedure;
SELECT 'preparation.amend_analysis_plan(uuid,uuid,bigint,uuid[],text,jsonb,uuid,text[])'::regprocedure;
SELECT 1/CASE WHEN NOT has_function_privilege('egi_editorial','preparation.normalize_workbench_states(preparation.analysis_packets,jsonb)','EXECUTE') THEN 1 ELSE 0 END;
ROLLBACK;
