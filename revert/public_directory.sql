BEGIN;
DROP FUNCTION governance.publication_diagnostics(uuid);
ALTER FUNCTION governance.prior_directory_diagnostics(uuid) RENAME TO publication_diagnostics;
DROP TRIGGER verification_consumers ON governance.verifications;
DROP FUNCTION governance.invalidate_verification_consumers();
DROP FUNCTION api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean);
DROP FUNCTION api.reference_closure(uuid);
DROP VIEW api.public_organizations;
DROP VIEW api.public_locations;
DROP FUNCTION api.service_detail(uuid,text,timestamptz,interval);
DROP TABLE api.export_manifests;
DROP VIEW api.public_sequence;
DROP VIEW api.source_attributions;
DROP VIEW api.public_taxonomy;
DROP VIEW api.public_territories;
CREATE OR REPLACE FUNCTION api.resolve_text(content uuid,preferred text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,'direction',COALESCE(lang.direction,orig.direction),'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class,'content_id',c.content_id)
 FROM i18n.content_units c LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred LEFT JOIN i18n.translation_publications p USING(publication_id) LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id LEFT JOIN i18n.languages lang ON lang.language_code=t.language_code LEFT JOIN i18n.languages orig ON orig.language_code=c.original_language
 WHERE c.content_id=content AND governance.public_content(content)
$$;
CREATE OR REPLACE FUNCTION governance.affected_territories(target_entity uuid, target_revision uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT territory_id FROM governance.revision_territories WHERE revision_id=target_revision
 UNION SELECT rt.territory_id FROM governance.working_heads wh JOIN governance.revision_territories rt ON rt.revision_id=wh.revision_id WHERE wh.entity_id=target_entity
 UNION SELECT rt.territory_id FROM governance.published_heads h JOIN governance.revision_territories rt ON rt.revision_id=h.revision_id WHERE h.entity_id=target_entity
 UNION SELECT m.territory_id FROM governance.published_heads h JOIN geo.service_memberships m ON m.revision_id=h.revision_id
 WHERE EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=target_entity)
 OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=target_entity)
 OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=target_entity)
 UNION SELECT m.territory_id FROM governance.calendar_event_versions ev JOIN data.schedule_calendar_links l ON l.calendar_id=ev.calendar_id JOIN governance.published_heads h ON h.revision_id=l.revision_id JOIN geo.service_memberships m ON m.revision_id=h.revision_id WHERE ev.entity_id=target_entity
$$;
COMMIT;
