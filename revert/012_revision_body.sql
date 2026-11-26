-- Revert egi_database:012_revision_body
-- Read-only functions: nothing is stored, so nothing is lost.
BEGIN;
DROP FUNCTION editorial.revision_body(uuid);
DROP FUNCTION editorial.clock(time);
DROP FUNCTION editorial.present(jsonb);
COMMIT;
