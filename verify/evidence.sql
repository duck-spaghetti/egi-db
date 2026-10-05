-- Verify egi_database:evidence on pg
BEGIN;
SELECT capture_id,source_metadata_snapshot FROM sources.captures WHERE false;
SELECT record_version_id,raw_payload FROM sources.record_versions WHERE false;
SELECT value_decision_id,assertion_id,evidence_role FROM governance.value_evidence WHERE false;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid='sources.assertions'::regclass AND tgname='immutable') THEN RAISE EXCEPTION 'assertion_guard_missing'; END IF;
END $$;
ROLLBACK;
