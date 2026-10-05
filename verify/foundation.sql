-- Verify egi_database:foundation on pg
BEGIN;
SELECT entity_id,entity_kind FROM data.entities WHERE false;
SELECT revision_id,sealed_at FROM governance.entity_revisions WHERE false;
SELECT content_id,owner_entity_id FROM i18n.content_units WHERE false;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_extension WHERE extname='postgis') THEN RAISE EXCEPTION 'postgis_missing'; END IF;
 IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgname='protect_revision' AND NOT tgisinternal) THEN RAISE EXCEPTION 'revision_guard_missing'; END IF;
 IF has_table_privilege('public','governance.entity_revisions','UPDATE') THEN RAISE EXCEPTION 'public_write_leak'; END IF;
END $$;
ROLLBACK;
