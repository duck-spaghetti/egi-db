-- Revert egi_database:034_workbench_context
BEGIN;
DROP FUNCTION preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid);
ALTER FUNCTION preparation.preview_analysis_plan_before_context(uuid,uuid[],text,jsonb,uuid) RENAME TO preview_analysis_plan;
GRANT EXECUTE ON FUNCTION preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid) TO egi_editorial;
DROP FUNCTION preparation.freeze_workbench_packet(uuid,bigint,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb);
ALTER FUNCTION preparation.freeze_workbench_packet_before_context(uuid,bigint,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb) RENAME TO freeze_workbench_packet;
DROP FUNCTION preparation.workbench_interpreted_context(uuid,jsonb,jsonb,text,jsonb,jsonb);
COMMIT;
