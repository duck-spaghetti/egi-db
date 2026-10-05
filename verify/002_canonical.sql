-- Verify egi_database:002_canonical
BEGIN;

-- ============================================================================
-- Canonical
-- ============================================================================
SELECT revision_id,delivery_mode,cost_state FROM data.service_revisions WHERE false;
SELECT revision_id,latitude,longitude,point FROM data.location_revisions WHERE false;
SELECT * FROM governance.publication_diagnostics(NULL);
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_attribute WHERE attrelid='data.location_revisions'::regclass AND attname='point' AND attgenerated='s') THEN RAISE EXCEPTION 'derived_point_missing'; END IF;
END $$;

ROLLBACK;
