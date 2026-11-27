-- Revert egi_database:014_preparations on pg
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.workspaces) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparations_exist';
 END IF;
END $$;
DROP SCHEMA preparation CASCADE;
COMMIT;
