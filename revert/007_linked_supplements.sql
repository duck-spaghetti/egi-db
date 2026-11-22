-- Revert egi_database:007_linked_supplements
BEGIN;
DROP FUNCTION api.linked_service_supplements(uuid,text);
DROP FUNCTION governance.contact_fingerprint(text,text);
DROP FUNCTION governance.supplement_provenance(uuid);
DROP FUNCTION governance.supplement_text(uuid,uuid,text);
DROP FUNCTION governance.resolved_source_links();
COMMIT;
