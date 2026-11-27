-- Verify egi_database:012_revision_body
-- Behaviour (round trip through save_revision) is covered by tests/contract/15-revision-body.sql.
BEGIN;
DO $$ BEGIN
 IF NOT has_function_privilege('egi_editorial','editorial.revision_body(uuid)','EXECUTE')
  OR has_function_privilege('egi_reader','editorial.revision_body(uuid)','EXECUTE')
  OR has_function_privilege('egi_intake','editorial.revision_body(uuid)','EXECUTE')
  OR has_function_privilege('egi_editorial','editorial.present(jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'revision_body_privileges_invalid';
 END IF;
 IF editorial.clock('09:00') IS DISTINCT FROM '09:00' OR editorial.clock('09:00:30') IS DISTINCT FROM '09:00:30' THEN
  RAISE EXCEPTION 'revision_body_clock_invalid';
 END IF;
END $$;
ROLLBACK;
