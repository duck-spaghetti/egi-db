-- Revert egi_database:016_community_sources on pg
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM editorial.community_source_requests) OR EXISTS(SELECT FROM governance.community_source_admissions) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_source_decisions_exist'; END IF;
END $$;
DROP FUNCTION editorial.register_community_source(jsonb,uuid),editorial.admit_community_source(uuid,text);
DROP TABLE editorial.community_source_requests,governance.community_source_admissions;
COMMIT;
