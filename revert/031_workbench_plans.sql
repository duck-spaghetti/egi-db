-- Revert egi_database:031_workbench_plans
BEGIN;
DROP TRIGGER workbench_retain_plan_input ON preparation.inputs;
DROP FUNCTION preparation.workbench_retain_plan_input();
DROP FUNCTION preparation.purge_job_payloads(uuid);
ALTER FUNCTION preparation.purge_job_payloads_before_workbench(uuid) RENAME TO purge_job_payloads;
DROP FUNCTION preparation.preview_analysis_plan(uuid,uuid[],text,jsonb,uuid);
DROP FUNCTION preparation.read_analysis_plan(uuid,uuid,bigint,integer,integer);
DROP FUNCTION preparation.freeze_workbench_packet(uuid,bigint,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb);
DROP FUNCTION preparation.workbench_digest(jsonb);
DROP TABLE preparation.plan_events,preparation.packet_jobs,preparation.analysis_packets,preparation.analysis_plans,preparation.shared_contexts;
DROP FUNCTION preparation.workbench_immutable();
COMMIT;
