-- Verify egi_database:007_linked_supplements
BEGIN;
DO $$ BEGIN
 IF NOT has_function_privilege('egi_reader','api.linked_service_supplements(uuid,text)','EXECUTE')
  OR has_function_privilege('egi_reader','governance.resolved_source_links()','EXECUTE')
  OR has_table_privilege('egi_reader','governance.sync_entries','SELECT') THEN
  RAISE EXCEPTION 'supplement_privileges_invalid';
 END IF;
 PERFORM api.linked_service_supplements(NULL,'it');
END $$;
ROLLBACK;
