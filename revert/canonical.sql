-- Revert egi_database:canonical from pg
BEGIN;
DROP FUNCTION governance.publication_diagnostics(uuid);
DROP TABLE geo.service_coverage,geo.service_memberships,data.service_languages,data.addresses,data.access_conditions,data.service_contact_links,data.contact_entries,data.location_organizations,data.service_organizations,data.service_places,data.service_revisions,data.location_revisions,geo.geocoding_cache,geo.geocoding_results,data.organization_revisions,geo.territory_revisions,geo.territories;
DROP FUNCTION IF EXISTS governance.check_payload_content(),geo.check_selected_coordinates();
COMMIT;
