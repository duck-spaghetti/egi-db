-- Revert egi_database:015_preparation_history on pg
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.workspaces) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparations_exist'; END IF;
END $$;
DROP FUNCTION preparation.purge_trash(),preparation.purge_job_payloads(uuid),preparation.retention_login(),
 preparation.read_history(uuid,uuid,bigint,integer),preparation.undo_operation(uuid,uuid,uuid),
 preparation.trash_workspace(uuid,bigint,uuid),preparation.restore_workspace(uuid,bigint,uuid),preparation.save_items(uuid,jsonb,uuid);
ALTER FUNCTION preparation.save_items_initial(uuid,jsonb,uuid) RENAME TO save_items;
GRANT EXECUTE ON FUNCTION preparation.save_items(uuid,jsonb,uuid) TO egi_editorial;
REVOKE USAGE ON SCHEMA preparation FROM egi_retention;
CREATE OR REPLACE FUNCTION preparation.immutable_row() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_immutable'; END $$;
ALTER TABLE preparation.workspaces DROP CONSTRAINT workspaces_trash_clock,
 ADD CONSTRAINT workspaces_check CHECK((state='trash')=(trashed_at IS NOT NULL));
COMMIT;
