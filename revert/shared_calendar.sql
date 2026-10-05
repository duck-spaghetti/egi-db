BEGIN;
DROP TRIGGER calendar_consumers ON governance.published_heads;
DROP FUNCTION governance.invalidate_calendar_consumers();
DROP FUNCTION api.opening(uuid,timestamptz,text,uuid);
DROP FUNCTION governance.calendar_state(uuid,text,uuid,timestamptz);
DELETE FROM governance.revision_extensions WHERE code IN('20_calendar_event','21_calendar_links');
DROP FUNCTION governance.save_calendar_links(uuid,uuid,text,jsonb,jsonb,text);
DROP FUNCTION governance.save_calendar_event(uuid,uuid,text,jsonb,jsonb,text);
DROP FUNCTION governance.create_calendar(text,text,uuid);
DROP TABLE data.exception_intervals;
DROP TABLE data.schedule_exception_effects;
DROP TABLE data.schedule_calendar_links;
CREATE OR REPLACE FUNCTION governance.affected_territories(target_entity uuid, target_revision uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT territory_id FROM governance.revision_territories WHERE revision_id=target_revision
 UNION SELECT rt.territory_id FROM governance.working_heads wh JOIN governance.revision_territories rt ON rt.revision_id=wh.revision_id WHERE wh.entity_id=target_entity
 UNION SELECT rt.territory_id FROM governance.published_heads h JOIN governance.revision_territories rt ON rt.revision_id=h.revision_id WHERE h.entity_id=target_entity
 UNION SELECT m.territory_id FROM governance.published_heads h JOIN geo.service_memberships m ON m.revision_id=h.revision_id
 WHERE EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=target_entity)
 OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=target_entity)
 OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=target_entity)
$$;
DROP TABLE governance.calendar_event_versions;
DROP TABLE governance.exception_calendars;
ALTER TABLE data.components DROP CONSTRAINT components_component_kind_check;
ALTER TABLE data.components ADD CONSTRAINT components_component_kind_check CHECK(component_kind IN ('contact','contact_link','address','condition','place','organization_role','coverage','schedule','interval'));
COMMIT;
