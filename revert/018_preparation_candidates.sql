-- Revert egi_database:018_preparation_candidates on pg
BEGIN;
DO $$ BEGIN IF EXISTS(SELECT FROM preparation.candidate_applications) THEN
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='candidate_applications_exist'; END IF; END $$;
DROP FUNCTION preparation.create_items(uuid,uuid,uuid,jsonb,uuid),preparation.merge_candidate(jsonb,jsonb,uuid,uuid),preparation.component_ids(jsonb,text);
ALTER FUNCTION preparation.create_manual_item(uuid,uuid,uuid,jsonb,uuid) RENAME TO create_items;
GRANT EXECUTE ON FUNCTION preparation.create_items(uuid,uuid,uuid,jsonb,uuid) TO egi_editorial;
DROP TABLE preparation.candidate_applications;
ALTER TABLE preparation.jobs DROP CONSTRAINT jobs_workspace_identity;
COMMIT;
