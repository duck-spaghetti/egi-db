-- Verify egi_database:003_governance
BEGIN;

-- ============================================================================
-- Publication
-- ============================================================================
SELECT * FROM api.published_services WHERE false;
DO $$ BEGIN
 IF has_table_privilege('egi_reader','data.service_revisions','SELECT') THEN RAISE EXCEPTION 'reader_internal_leak'; END IF;
 IF has_function_privilege('egi_reader','governance.publish_revision(uuid,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'reader_write_leak'; END IF;
 IF NOT has_function_privilege('egi_writer','governance.save_revision(text,uuid,uuid,uuid,jsonb,text)','EXECUTE') THEN RAISE EXCEPTION 'writer_operation_missing'; END IF;
END $$;

-- ============================================================================
-- Aggregate Extensions
-- ============================================================================
SELECT code,save_handler FROM governance.revision_extensions WHERE false;

ROLLBACK;
