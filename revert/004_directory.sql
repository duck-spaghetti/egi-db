-- Revert egi_database:004_directory
BEGIN;

-- ============================================================================
-- Public Directory
-- ============================================================================
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

-- ============================================================================
-- Dynamic Translations
-- ============================================================================
DROP TRIGGER translation_updates ON governance.published_heads;
DROP FUNCTION governance.queue_translation_updates();
DROP FUNCTION api.resolve_text(uuid,text);
DROP FUNCTION governance.publish_translation(uuid,uuid,uuid,text);
DROP FUNCTION governance.review_translation(uuid,text,text);
DROP FUNCTION governance.propose_translation(uuid,text,text,text,text,uuid,text);
DROP FUNCTION governance.prioritize_language(uuid,text,integer,boolean,text);
DROP FUNCTION governance.register_language(text,text,text,text,text);
DROP FUNCTION governance.translation_scope(uuid);
DROP FUNCTION governance.translation_worklist(uuid);
DROP VIEW governance.translation_work;
DROP FUNCTION governance.public_content(uuid);
DROP TABLE i18n.translation_update_requests;
DROP TABLE i18n.territory_language_priorities;
DROP TABLE i18n.translation_heads;
DROP TABLE i18n.translation_publications;
DROP TABLE i18n.translation_reviews;
DROP TABLE i18n.translations;
DROP TABLE i18n.languages;

-- ============================================================================
-- Territorial Taxonomy
-- ============================================================================
DROP FUNCTION api.taxonomy_search(uuid,jsonb,date);
DELETE FROM governance.revision_extensions WHERE code IN('30_vocabulary','31_term','32_classification');
DROP FUNCTION governance.fork_taxonomy_release(uuid,uuid,text,text,text);
DROP FUNCTION governance.save_classifications(uuid,uuid,text,jsonb,jsonb,text);
DROP FUNCTION governance.adopt_taxonomy_release(uuid,uuid,date,date,text);
DROP FUNCTION governance.freeze_taxonomy_release(uuid,text,jsonb,jsonb,jsonb,text);
DROP FUNCTION governance.create_taxonomy_axis(uuid,text);
DROP FUNCTION governance.save_taxonomy_entity(uuid,uuid,text,jsonb,jsonb,text);
DROP TABLE taxonomy.assignments;
DROP TABLE taxonomy.territory_adoptions;
DROP TABLE taxonomy.broader_links;
DROP FUNCTION governance.check_taxonomy_adoption();
DROP FUNCTION governance.check_taxonomy_edge();
DROP TABLE taxonomy.release_terms;
DROP TABLE taxonomy.release_axes;
ALTER TABLE taxonomy.vocabularies DROP CONSTRAINT vocabularies_origin_release_id_origin_vocabulary_id_fkey;
DROP TABLE taxonomy.releases;
DROP FUNCTION governance.check_open_taxonomy_release();
DROP FUNCTION governance.protect_taxonomy_release();
DROP TABLE taxonomy.term_revisions;
DROP TABLE taxonomy.terms;
DROP TABLE taxonomy.axes;
DROP TABLE taxonomy.vocabulary_revisions;
DROP TABLE taxonomy.vocabularies;

-- ============================================================================
-- Shared Calendar
-- ============================================================================
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

-- ============================================================================
-- Weekly Hours
-- ============================================================================
DROP VIEW api.weekly_hours;
DROP FUNCTION api.weekly_opening(uuid,timestamptz,text,uuid);
DROP FUNCTION governance.clock_changes(text,timestamptz,timestamptz);
DROP FUNCTION governance.civil_occurrences(timestamp,text);
DROP FUNCTION governance.weekly_state(uuid,text,uuid,timestamptz);
DROP FUNCTION governance.eligible_schedules(uuid,text,uuid,timestamptz);
DELETE FROM governance.revision_extensions WHERE code='10_hours';
DROP FUNCTION governance.save_schedules(uuid,uuid,text,jsonb,jsonb,text);
DROP TABLE data.schedule_intervals;
DROP TABLE data.schedule_days;
DROP TABLE data.schedules;
DROP FUNCTION governance.check_schedule_interval();
DROP FUNCTION governance.check_schedule();

COMMIT;
