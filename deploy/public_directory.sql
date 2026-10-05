-- Deploy egi_database:public_directory [dynamic_translations] to pg
BEGIN;
ALTER FUNCTION governance.publication_diagnostics(uuid) RENAME TO prior_directory_diagnostics;
CREATE FUNCTION governance.publication_diagnostics(target uuid) RETURNS TABLE(code text,field text)
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT * FROM governance.prior_directory_diagnostics(target)
 UNION ALL SELECT 'unpublished_parent_location','parent_location_id' FROM data.location_revisions l WHERE l.revision_id=target AND l.parent_location_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=l.parent_location_id)
$$;
CREATE VIEW api.public_territories WITH(security_barrier=true) AS
SELECT t.entity_id AS territory_id,t.code,r.revision_id,r.name_content_id,c.original_text AS name,r.timezone_name,r.country_code,public.ST_AsGeoJSON(r.boundary)::jsonb AS boundary
FROM geo.territories t JOIN governance.published_heads h USING(entity_id) JOIN geo.territory_revisions r USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=r.name_content_id;
CREATE VIEW api.public_taxonomy WITH(security_barrier=true) AS
SELECT a.territory_id,a.adoption_id,a.release_id,a.effective_from,a.effective_until,ra.axis_id,ax.code AS axis_code,ra.label AS axis_label,rt.term_id,rt.term_revision_id,l.content_id AS name_content_id,c.original_text AS name,tr.presentation_metadata
FROM taxonomy.territory_adoptions a JOIN taxonomy.release_axes ra USING(release_id) JOIN taxonomy.axes ax USING(axis_id) JOIN taxonomy.release_terms rt ON rt.release_id=a.release_id AND rt.axis_id=ra.axis_id JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id JOIN i18n.revision_content_links l ON l.revision_id=tr.revision_id AND l.field_code='name' LEFT JOIN i18n.content_units c USING(content_id);
CREATE VIEW api.source_attributions WITH(security_barrier=true) AS
SELECT DISTINCT h.entity_id,h.revision_id,r.source_id,r.name,r.homepage,r.license,c.retrieved_at,c.published_at
FROM governance.published_heads h JOIN governance.value_decisions d ON d.revision_id=h.revision_id JOIN governance.value_evidence e USING(value_decision_id) JOIN sources.assertions a USING(assertion_id) JOIN sources.normalized_subjects n USING(subject_id) JOIN sources.processing_runs p USING(run_id) JOIN sources.captures c ON c.capture_id=p.capture_id JOIN sources.datasets ds USING(dataset_id) JOIN sources.registry r USING(source_id) WHERE e.evidence_role='supporting';
CREATE VIEW api.public_sequence WITH(security_barrier=true) AS SELECT COALESCE(max(change_sequence),0) AS snapshot_sequence FROM audit.public_changes;
CREATE TABLE api.export_manifests (
 export_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),format text NOT NULL CHECK(format IN('hsds','sqlite')),
 snapshot_sequence bigint NOT NULL,schema_version text NOT NULL,policy_version text NOT NULL,territories uuid[] NOT NULL,languages text[] NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),checksum text,status text NOT NULL CHECK(status IN('building','ready','failed'))
);
-- A public text endpoint may never expose a private contact's label.
CREATE OR REPLACE FUNCTION api.resolve_text(content uuid,preferred text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,'direction',CASE WHEN t.translation_id IS NULL THEN orig.direction ELSE lang.direction END,'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class,'content_id',c.content_id)
 FROM i18n.content_units c LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred LEFT JOIN i18n.translation_publications p USING(publication_id) LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id LEFT JOIN i18n.languages lang ON lang.language_code=t.language_code LEFT JOIN i18n.languages orig ON orig.language_code=c.original_language WHERE c.content_id=content AND governance.public_content(content)
$$;
CREATE FUNCTION api.service_detail(service uuid,preferred text DEFAULT NULL,instant timestamptz DEFAULT statement_timestamp(),review_after interval DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('service_id',s.entity_id,'revision_id',s.revision_id,'publication_id',h.publication_id,'snapshot_sequence',(SELECT snapshot_sequence FROM api.public_sequence),
 'name',api.resolve_text(s.name_content_id,preferred),'description',api.resolve_text(s.description_content_id,preferred),'delivery_mode',s.delivery_mode,'operational_status',s.operational_status,'cost',jsonb_build_object('state',s.cost_state,'note',api.resolve_text(s.cost_note_content_id,preferred)),
 'valid_from',s.valid_from,'valid_until',s.valid_until,'closure_date',s.closure_date,'closure_reason',api.resolve_text(s.closure_reason_content_id,preferred),
 'place',(SELECT jsonb_build_object('location_id',p.location_id,'territory_id',p.territory_id,'area_description',api.resolve_text(p.area_description_content_id,preferred),'location_revision_id',l.revision_id,'name',api.resolve_text(l.name_content_id,preferred),'coordinate_state',l.coordinate_state,'latitude',l.latitude,'longitude',l.longitude,'parent_location_id',l.parent_location_id,'addresses',COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',a.address_kind,'formatted',a.formatted,'line1',a.line1,'locality',a.locality,'postal_code',a.postal_code,'administrative_area',a.administrative_area,'country_code',a.country_code) ORDER BY a.component_id) FROM data.addresses a WHERE a.revision_id=l.revision_id),'[]'::jsonb)) FROM data.service_places p LEFT JOIN governance.published_heads lh ON lh.entity_id=p.location_id LEFT JOIN data.location_revisions l ON l.revision_id=lh.revision_id WHERE p.revision_id=s.revision_id),
 'organizations',COALESCE((SELECT jsonb_agg(jsonb_build_object('organization_id',o.organization_id,'role',o.role_code,'revision_id',org.revision_id,'name',api.resolve_text(org.name_content_id,preferred),'description',api.resolve_text(org.description_content_id,preferred),'website',org.website) ORDER BY o.component_id) FROM data.service_organizations o JOIN governance.published_heads oh ON oh.entity_id=o.organization_id JOIN data.organization_revisions org ON org.revision_id=oh.revision_id WHERE o.revision_id=s.revision_id),'[]'::jsonb),
 'contacts',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',ep.component_id,'link_component_id',ep.link_component_id,'subject_entity_id',ep.subject_entity_id,'scope',ep.subject_scope,'channel',ep.channel_type,'value',ep.value,'purpose',ep.purpose_code,'label',api.resolve_text(ep.label_content_id,preferred),'opening',api.opening(ep.subject_entity_id,instant,'contact',ep.component_id),
 'verification',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'component_id',v.component_id,'field',v.field_code,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END)) FROM governance.verifications v JOIN governance.published_heads vh ON vh.revision_id=v.revision_id WHERE vh.entity_id=ep.subject_entity_id AND (v.scope_kind='page' OR v.component_id=ep.component_id OR (v.scope_kind='field' AND v.field_code='contact'))),'[]'::jsonb)) ORDER BY ep.sort_order,ep.component_id,ep.link_component_id)
 FROM (
 SELECT c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,c.label_content_id,c.sort_order,NULL::uuid AS link_component_id FROM data.contact_entries c WHERE c.revision_id=s.revision_id AND c.is_public
 UNION ALL
 SELECT c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(link.label_content_id,c.label_content_id),c.sort_order,link.component_id FROM data.service_contact_links link JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id JOIN data.entities e ON e.entity_id=c.entity_id WHERE link.revision_id=s.revision_id AND c.is_public
 )ep),'[]'::jsonb),
 'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,'kind',c.condition_kind,'state',c.requirement_state,'details',api.resolve_text(c.details_content_id,preferred)) ORDER BY c.component_id) FROM data.access_conditions c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'service_languages',COALESCE((SELECT jsonb_agg(jsonb_build_object('language',l.language_code,'availability',l.availability_kind,'note',api.resolve_text(l.note_content_id,preferred))) FROM data.service_languages l WHERE l.revision_id=s.revision_id),'[]'::jsonb),
 'territories',COALESCE((SELECT jsonb_agg(m.territory_id ORDER BY m.territory_id) FROM geo.service_memberships m WHERE m.revision_id=s.revision_id),'[]'::jsonb),
 'coverage',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',c.territory_id,'geometry',public.ST_AsGeoJSON(c.geometry)::jsonb,'description',api.resolve_text(c.description_content_id,preferred))) FROM geo.service_coverage c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'classifications',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',a.territory_id,'adoption_id',a.adoption_id,'release_id',a.release_id,'term_id',a.term_id,'axis',ax.code,'label',api.resolve_text(l.content_id,preferred))) FROM taxonomy.assignments a JOIN taxonomy.release_terms rt USING(release_id,term_id) JOIN taxonomy.terms t ON t.entity_id=a.term_id JOIN taxonomy.axes ax ON ax.axis_id=t.axis_id JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name' WHERE a.revision_id=s.revision_id),'[]'::jsonb),
 'weekly_hours',COALESCE((SELECT jsonb_agg(to_jsonb(w)-'entity_id'-'revision_id' ORDER BY w.schedule_id,w.iso_weekday,w.opens_at) FROM api.weekly_hours w WHERE w.revision_id=s.revision_id),'[]'::jsonb),'opening',api.opening(s.entity_id,instant),
 'sources',COALESCE((SELECT jsonb_agg(to_jsonb(a)-'entity_id'-'revision_id') FROM api.source_attributions a WHERE a.entity_id=s.entity_id),'[]'::jsonb),
 'verification',jsonb_build_object('checks',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'field',v.field_code,'component_id',v.component_id,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END) ORDER BY v.checked_at) FROM governance.verifications v WHERE v.revision_id=s.revision_id),'[]'::jsonb),'page_state',CASE WHEN EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id AND v.scope_kind='page' AND v.outcome='confirmed') THEN 'verified_with_scope' ELSE 'unverified' END,'warning',CASE WHEN NOT EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id) THEN 'no_verification' WHEN review_after IS NULL THEN 'threshold_not_configured' ELSE NULL END))
 FROM governance.published_heads h JOIN data.service_revisions s USING(revision_id) WHERE s.entity_id=service
$$;
CREATE VIEW api.public_locations WITH(security_barrier=true) AS
SELECT l.entity_id AS location_id,l.revision_id,l.name_content_id,c.original_text AS name,l.location_kind,l.parent_location_id,l.latitude,l.longitude,l.coordinate_state,
COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',a.address_kind,'formatted',a.formatted,'line1',a.line1,'locality',a.locality,'postal_code',a.postal_code,'country_code',a.country_code)) FROM data.addresses a WHERE a.revision_id=l.revision_id),'[]'::jsonb) AS addresses
FROM governance.published_heads h JOIN data.location_revisions l USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=l.name_content_id;
CREATE VIEW api.public_organizations WITH(security_barrier=true) AS
SELECT o.entity_id AS organization_id,o.revision_id,o.name_content_id,o.description_content_id,c.original_text AS name,o.organization_type,o.website
FROM governance.published_heads h JOIN data.organization_revisions o USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=o.name_content_id;
CREATE FUNCTION api.reference_closure(territory uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
WITH RECURSIVE services AS(SELECT s.service_id,s.revision_id FROM api.discoverable_services s JOIN geo.service_memberships m USING(revision_id) WHERE m.territory_id=territory),
locations(id) AS(SELECT p.location_id FROM services s JOIN data.service_places p USING(revision_id) WHERE p.location_id IS NOT NULL UNION SELECT c.target_entity_id FROM services s JOIN data.service_contact_links c USING(revision_id) JOIN api.public_locations pl ON pl.location_id=c.target_entity_id UNION SELECT l.parent_location_id FROM locations p JOIN api.public_locations l ON l.location_id=p.id WHERE l.parent_location_id IS NOT NULL),
organizations(id) AS(SELECT o.organization_id FROM services s JOIN data.service_organizations o USING(revision_id) UNION SELECT c.target_entity_id FROM services s JOIN data.service_contact_links c USING(revision_id) JOIN api.public_organizations o ON o.organization_id=c.target_entity_id UNION SELECT o.organization_id FROM locations l JOIN api.public_locations pl ON pl.location_id=l.id JOIN data.location_organizations o ON o.revision_id=pl.revision_id),
territories(id) AS(SELECT territory UNION SELECT m.territory_id FROM services s JOIN geo.service_memberships m USING(revision_id) UNION SELECT c.territory_id FROM services s JOIN geo.service_coverage c USING(revision_id) WHERE c.territory_id IS NOT NULL)
SELECT jsonb_build_object('locations',COALESCE((SELECT jsonb_agg(to_jsonb(l)) FROM api.public_locations l JOIN locations p ON p.id=l.location_id),'[]'::jsonb),
'organizations',COALESCE((SELECT jsonb_agg(to_jsonb(o)) FROM api.public_organizations o JOIN organizations p ON p.id=o.organization_id),'[]'::jsonb),
'location_organizations',COALESCE((SELECT jsonb_agg(jsonb_build_object('location_id',l.location_id,'organization_id',o.organization_id,'role',o.role_code)) FROM api.public_locations l JOIN locations p ON p.id=l.location_id JOIN data.location_organizations o ON o.revision_id=l.revision_id),'[]'::jsonb),
'territories',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',t.id,'published',pt.territory_id IS NOT NULL,'details',to_jsonb(pt))) FROM territories t LEFT JOIN api.public_territories pt ON pt.territory_id=t.id),'[]'::jsonb))
$$;
CREATE FUNCTION api.directory_snapshot(territory uuid,preferred text DEFAULT NULL,selections jsonb DEFAULT '{}',instant timestamptz DEFAULT statement_timestamp(),only_open boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('schema_version','egi-directory-v1','snapshot_sequence',(SELECT snapshot_sequence FROM api.public_sequence),'territory_id',territory,'language_preference',preferred,'evaluated_at',instant,
 'services',COALESCE((SELECT jsonb_agg(api.service_detail(s,preferred,instant) ORDER BY s) FROM api.taxonomy_search(territory,selections,(instant AT TIME ZONE COALESCE((SELECT timezone_name FROM api.public_territories WHERE territory_id=territory),'UTC'))::date)s WHERE NOT only_open OR api.opening(s,instant)->>'status'='open'),'[]'::jsonb),
 'taxonomy',COALESCE((SELECT jsonb_agg(jsonb_build_object('adoption_id',t.adoption_id,'release_id',t.release_id,'axis_id',t.axis_id,'axis_code',t.axis_code,'axis_label',t.axis_label,'term_id',t.term_id,'term_revision_id',t.term_revision_id,'name',api.resolve_text(t.name_content_id,preferred),'presentation',t.presentation_metadata,'effective_from',t.effective_from,'effective_until',t.effective_until)) FROM api.public_taxonomy t WHERE t.territory_id=territory),'[]'::jsonb),
 'taxonomy_edges',COALESCE((SELECT jsonb_agg(jsonb_build_object('release_id',b.release_id,'child',b.child_term_id,'parent',b.parent_term_id)) FROM taxonomy.broader_links b WHERE EXISTS(SELECT FROM taxonomy.territory_adoptions a WHERE a.release_id=b.release_id AND a.territory_id=territory)),'[]'::jsonb),
 'references',api.reference_closure(territory),
 'territory',(SELECT to_jsonb(t) FROM api.public_territories t WHERE t.territory_id=territory))
 WHERE EXISTS(SELECT FROM api.public_territories WHERE territory_id=territory)
$$;
CREATE FUNCTION governance.invalidate_verification_consumers() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM governance.published_heads WHERE entity_id=NEW.entity_id AND revision_id=NEW.revision_id) THEN RETURN NEW; END IF;
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
 SELECT h.entity_id,h.publication_id,'verification','scoped_verification_added' FROM governance.published_heads h WHERE h.revision_id=NEW.revision_id OR EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=NEW.entity_id) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=NEW.entity_id) OR EXISTS(SELECT FROM data.service_contact_links l WHERE l.revision_id=h.revision_id AND l.target_entity_id=NEW.entity_id);
 RETURN NEW;
END $$;
CREATE TRIGGER verification_consumers AFTER INSERT ON governance.verifications FOR EACH ROW EXECUTE FUNCTION governance.invalidate_verification_consumers();
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
 UNION SELECT a.territory_id FROM taxonomy.territory_adoptions a WHERE a.vocabulary_id=target_entity OR EXISTS(SELECT FROM taxonomy.terms t WHERE t.entity_id=target_entity AND t.vocabulary_id=a.vocabulary_id)
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.reference_closure(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.service_detail(uuid,text,timestamptz,interval),api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean) FROM PUBLIC;
GRANT SELECT ON api.public_territories,api.public_taxonomy,api.source_attributions,api.public_sequence,api.public_locations,api.public_organizations TO egi_reader;
GRANT EXECUTE ON FUNCTION api.reference_closure(uuid) TO egi_reader;
GRANT EXECUTE ON FUNCTION api.service_detail(uuid,text,timestamptz,interval),api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean) TO egi_reader;
COMMIT;
