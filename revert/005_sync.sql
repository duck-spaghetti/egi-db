-- Revert egi_database:005_sync
BEGIN;

-- ============================================================================
-- Privileges
-- ============================================================================
DO $$ BEGIN
 IF EXISTS(SELECT FROM governance.sync_versions) OR EXISTS(SELECT FROM governance.source_service_links) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='sync_history_exists';
 END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA data,sources,i18n,geo,taxonomy,audit,governance FROM egi_sync;
REVOKE EXECUTE ON FUNCTION governance.lock_operation() FROM egi_sync;
REVOKE USAGE ON SCHEMA data,sources,i18n,geo,audit,taxonomy FROM egi_sync;

-- ============================================================================
-- Operations and versions
-- ============================================================================
DROP FUNCTION
 governance.link_source_services(uuid,text,uuid,text,text,text,text),
 governance.withdraw_service(uuid,uuid,text,text),
 governance.record_sync_version(uuid,text,boolean,uuid,uuid,jsonb);
DROP TABLE governance.source_service_links,governance.sync_entries,governance.sync_versions;
-- Retain cluster-wide roles and their membership: other databases may use them.

COMMIT;
