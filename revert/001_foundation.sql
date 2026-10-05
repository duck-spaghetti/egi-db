-- Revert egi_database:001_foundation
BEGIN;

-- ============================================================================
-- Evidence
-- ============================================================================
DROP TABLE governance.value_evidence,governance.value_decisions,governance.identity_aliases,governance.subject_bindings,governance.resolution_members,governance.resolution_decisions,governance.match_candidates;
DROP TABLE sources.assertions,sources.normalized_subjects,sources.processing_runs,sources.capture_records,sources.record_versions,sources.records,sources.captures,sources.datasets,sources.registry;
DROP FUNCTION governance.check_evidence_open();
DROP FUNCTION sources.check_interpretation_capture();

-- ============================================================================
-- Foundation
-- ============================================================================
DROP SCHEMA api CASCADE;
DROP SCHEMA taxonomy CASCADE;
DROP SCHEMA geo CASCADE;
DROP SCHEMA sources CASCADE;
DROP SCHEMA audit CASCADE;
DROP SCHEMA i18n CASCADE;
DROP SCHEMA governance CASCADE;
DROP SCHEMA data CASCADE;
-- Retain the pre-existing PostGIS extension and public-schema ACL.

COMMIT;
