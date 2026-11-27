-- Revert egi_database:017_preparation_jobs on pg
BEGIN;
DO $$ BEGIN IF EXISTS(SELECT FROM preparation.jobs) OR EXISTS(SELECT FROM preparation.ai_configurations) THEN
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_jobs_or_configuration_exist'; END IF; END $$;
DROP FUNCTION preparation.request_interpretation(uuid,uuid,text,uuid),preparation.read_job(uuid,uuid),preparation.cancel_job(uuid,uuid,uuid),
 preparation.claim_job(uuid),preparation.heartbeat_job(uuid,text,uuid),preparation.start_dispatch(uuid,text),
 preparation.finish_job(uuid,uuid,text,jsonb,jsonb),preparation.fail_job(uuid,text,text,boolean),
 preparation.validate_job_result(preparation.jobs,jsonb),preparation.validate_diagnostics(jsonb),preparation.leased_job(uuid,text),preparation.eligible_input(uuid,uuid),preparation.redact_text(uuid,text),preparation.requester_authorized(uuid,uuid),preparation.require_worker(),preparation.worker_login();
DROP TRIGGER workspace_cancel_jobs ON preparation.workspaces;
DROP FUNCTION preparation.cancel_trashed_jobs(),preparation.read_workspace(uuid);
ALTER FUNCTION preparation.read_workspace_initial(uuid) RENAME TO read_workspace;
GRANT EXECUTE ON FUNCTION preparation.read_workspace(uuid),preparation.trash_workspace(uuid,bigint,uuid) TO egi_editorial;
CREATE OR REPLACE FUNCTION preparation.purge_job_payloads(wid uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$ BEGIN RETURN; END $$;
DROP TABLE preparation.budget_reservations,preparation.budget_periods,preparation.jobs,preparation.ai_settings,preparation.ai_configurations;
REVOKE USAGE ON SCHEMA preparation FROM egi_preparation_worker;
-- Retain the NOLOGIN capability role: other databases may use it.
COMMIT;
