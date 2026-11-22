-- Verify egi_database:005_sync
BEGIN;

-- ============================================================================
-- Sync
-- ============================================================================
SELECT version_id,dataset_id,previous_version_id,published FROM governance.sync_versions WHERE false;
SELECT version_id,service_id,state,identity,comparable,source_body FROM governance.sync_entries WHERE false;
SELECT link_id,relation,principal FROM governance.source_service_links WHERE false;
DO $$ BEGIN
 IF has_table_privilege('egi_reader','governance.sync_entries','SELECT') THEN RAISE EXCEPTION 'reader_internal_leak'; END IF;
 IF has_function_privilege('egi_reader','governance.withdraw_service(uuid,uuid,text,text)','EXECUTE') THEN RAISE EXCEPTION 'reader_write_leak'; END IF;
 IF has_function_privilege('egi_writer','governance.record_sync_version(uuid,text,boolean,uuid,uuid,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'writer_sync_leak'; END IF;
 IF has_table_privilege('egi_sync','data.service_revisions','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'sync_canonical_write_leak'; END IF;
 IF has_table_privilege('egi_sync','governance.published_heads','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'sync_publication_write_leak'; END IF;
 IF has_table_privilege('egi_sync','sources.registry','INSERT') THEN RAISE EXCEPTION 'sync_registration_leak'; END IF;
 IF NOT has_table_privilege('egi_sync','sources.assertions','INSERT') THEN RAISE EXCEPTION 'sync_evidence_missing'; END IF;
END $$;

ROLLBACK;
