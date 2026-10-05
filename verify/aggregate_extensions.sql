-- Verify egi_database:aggregate_extensions on pg
BEGIN;
SELECT code,save_handler FROM governance.revision_extensions WHERE false;
ROLLBACK;
