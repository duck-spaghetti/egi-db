-- Revert egi_database:011_editorial
-- Contributions and their outcomes cannot be silently discarded.
BEGIN;
SELECT governance.lock_operation();
DO $$ BEGIN
 IF EXISTS(SELECT FROM editorial.contributions) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='contributions_exist';
 END IF;
END $$;
DROP SCHEMA editorial CASCADE;
-- Retain the cluster-wide roles egi_intake and egi_retention: other databases may use them.
COMMIT;
