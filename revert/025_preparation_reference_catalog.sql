-- Revert egi_database:025_preparation_reference_catalog
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.item_versions v CROSS JOIN LATERAL jsonb_array_elements(COALESCE(v.payload->'resolutions','[]')) r WHERE r->>'state' IN ('proposed','confirmed')) OR
 EXISTS(SELECT FROM editorial.community_snapshots s CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.values->'resolutions','[]')) r WHERE r->>'state' IN ('proposed','confirmed')) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='reference_resolutions_in_use'; END IF;
END $$;
DROP TRIGGER reference_confirmation ON preparation.item_versions;
DROP FUNCTION preparation.stamp_reference_confirmation();
DROP FUNCTION preparation.validate_source_facts(uuid,jsonb);
ALTER FUNCTION preparation.validate_source_facts_literal(uuid,jsonb) RENAME TO validate_source_facts;
DROP FUNCTION preparation.reference_catalog(uuid,jsonb),editorial.reference_catalog(uuid,jsonb);
DROP FUNCTION preparation.catalog(jsonb),preparation.validate_reference(jsonb,jsonb,jsonb);
DROP FUNCTION preparation.organization_name_digest(text);
DROP FUNCTION preparation.organization_visible(uuid);
COMMIT;
