-- Verify egi_database:034_workbench_context
BEGIN;
SELECT 1/CASE WHEN has_function_privilege('egi_editorial','preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid)','EXECUTE')
 AND NOT has_function_privilege('egi_editorial','preparation.preview_analysis_plan_before_context(uuid,uuid[],text,jsonb,uuid)','EXECUTE')
 AND NOT has_function_privilege('egi_preparation_worker','preparation.workbench_interpreted_context(uuid,jsonb,jsonb,text,jsonb,jsonb)','EXECUTE') THEN 1 ELSE 0 END;
ROLLBACK;
