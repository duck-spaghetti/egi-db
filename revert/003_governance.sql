-- Revert egi_database:003_governance
BEGIN;

-- ============================================================================
-- Aggregate Extensions
-- ============================================================================
DROP FUNCTION governance.apply_revision_extensions(uuid,uuid,text,jsonb,jsonb,text);
DROP TABLE governance.revision_extensions;
DROP FUNCTION governance.lock_operation();

-- ============================================================================
-- Publication
-- ============================================================================
DROP VIEW api.service_verification,api.service_contacts,api.discoverable_services,api.published_services;
DROP FUNCTION governance.verify_revision(uuid,text,text,uuid,timestamptz,text,text,text),governance.restore_revision(uuid,uuid,uuid,text),governance.publish_revision(uuid,uuid,uuid),governance.review_revision(uuid,uuid,text,text),governance.require_publishable(uuid),governance.save_revision(text,uuid,uuid,uuid,jsonb,text),governance.select_value(uuid,uuid,text,uuid,jsonb,text),governance.owned_component(uuid,text,uuid),governance.bind_original(uuid,uuid,text,text,text,uuid),governance.lock_expected(uuid,uuid,uuid,boolean),governance.require_capability(text,uuid[]),governance.affected_territories(uuid,uuid),governance.publication_diagnostics(uuid);
ALTER FUNCTION governance.draft_diagnostics(uuid) RENAME TO publication_diagnostics;
DROP TABLE audit.public_changes,governance.verifications,governance.published_heads,governance.publications,governance.review_decisions,governance.submissions,governance.revision_territories,governance.actor_grants;
-- Retain cluster-wide roles: other databases may use them.

COMMIT;
