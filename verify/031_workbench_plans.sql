-- Verify egi_database:031_workbench_plans
BEGIN;
SELECT plan_id,version,snapshot_key,eligible_snapshot FROM preparation.analysis_plans WHERE false;
SELECT context_id,digest,body FROM preparation.shared_contexts WHERE false;
SELECT packet_id,manifest,data,request_body FROM preparation.analysis_packets WHERE false;
SELECT packet_id,job_id FROM preparation.packet_jobs WHERE false;
SELECT event_id,kind FROM preparation.plan_events WHERE false;
SELECT 1/CASE WHEN has_function_privilege('egi_editorial','preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid)','EXECUTE')
 AND NOT has_function_privilege('egi_editorial','preparation.freeze_workbench_packet(uuid,bigint,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb)','EXECUTE')
 AND NOT has_table_privilege('egi_editorial','preparation.analysis_packets','SELECT')
 AND NOT has_table_privilege('egi_preparation_worker','preparation.shared_contexts','SELECT') THEN 1 ELSE 0 END;
ROLLBACK;
