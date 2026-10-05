-- Revert egi_database:evidence from pg
BEGIN;
DROP TABLE governance.value_evidence,governance.value_decisions,governance.identity_aliases,governance.subject_bindings,governance.resolution_members,governance.resolution_decisions,governance.match_candidates;
DROP TABLE sources.assertions,sources.normalized_subjects,sources.processing_runs,sources.capture_records,sources.record_versions,sources.records,sources.captures,sources.datasets,sources.registry;
DROP FUNCTION governance.check_evidence_open();
DROP FUNCTION sources.check_interpretation_capture();
COMMIT;
