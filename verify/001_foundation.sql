-- Verify egi_database:001_foundation
BEGIN;

-- ============================================================================
-- Foundation
-- ============================================================================
SELECT entity_id,entity_kind FROM data.entities WHERE false;
SELECT revision_id,sealed_at FROM governance.entity_revisions WHERE false;
SELECT content_id,owner_entity_id FROM i18n.content_units WHERE false;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_extension WHERE extname='postgis') THEN RAISE EXCEPTION 'postgis_missing'; END IF;
 IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgname='protect_revision' AND NOT tgisinternal) THEN RAISE EXCEPTION 'revision_guard_missing'; END IF;
 IF has_table_privilege('public','governance.entity_revisions','UPDATE') THEN RAISE EXCEPTION 'public_write_leak'; END IF;
END $$;

-- ============================================================================
-- Evidence
-- ============================================================================
SELECT capture_id,source_metadata_snapshot FROM sources.captures WHERE false;
SELECT record_version_id,raw_payload FROM sources.record_versions WHERE false;
SELECT value_decision_id,assertion_id,evidence_role FROM governance.value_evidence WHERE false;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid='sources.assertions'::regclass AND tgname='immutable') THEN RAISE EXCEPTION 'assertion_guard_missing'; END IF;
END $$;

ROLLBACK;
