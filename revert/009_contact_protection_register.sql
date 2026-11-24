-- Revert egi_database:009_contact_protection_register
-- A populated privacy register cannot be silently discarded.
BEGIN;
SELECT governance.lock_operation();
DO $$ BEGIN
 IF EXISTS(SELECT FROM governance.contact_protections)
  OR EXISTS(SELECT FROM governance.contact_protection_scopes)
  OR EXISTS(SELECT FROM governance.contact_protection_resolutions) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='contact_protection_history_exists';
 END IF;
END $$;
CREATE OR REPLACE VIEW api.service_contacts WITH(security_barrier=true) AS
 SELECT s.entity_id AS service_id,c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,l.original_text AS label,c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.contact_entries c ON c.revision_id=s.revision_id LEFT JOIN i18n.content_units l ON l.content_id=c.label_content_id WHERE c.is_public
 UNION ALL SELECT s.entity_id,c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(ll.original_text,cl.original_text),c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.service_contact_links link ON link.revision_id=s.revision_id
 JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id
 JOIN data.entities e ON e.entity_id=c.entity_id LEFT JOIN i18n.content_units ll ON ll.content_id=link.label_content_id LEFT JOIN i18n.content_units cl ON cl.content_id=c.label_content_id WHERE c.is_public;
CREATE OR REPLACE FUNCTION governance.public_content(content uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM i18n.content_units c JOIN i18n.revision_content_links l USING(content_id) JOIN governance.published_heads h USING(revision_id) WHERE c.content_id=content AND NOT EXISTS(SELECT FROM data.contact_entries p WHERE p.revision_id=h.revision_id AND p.component_id=c.component_id AND NOT p.is_public))
 OR EXISTS(SELECT FROM taxonomy.release_terms rt JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id JOIN taxonomy.territory_adoptions a USING(release_id) WHERE l.content_id=content)
$$;
CREATE OR REPLACE FUNCTION api.service_detail(service uuid,preferred text DEFAULT NULL,instant timestamptz DEFAULT statement_timestamp(),review_after interval DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
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
CREATE OR REPLACE FUNCTION api.linked_service_supplements(principal uuid DEFAULT NULL,preferred text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 WITH active AS (
  SELECT DISTINCT ON(dataset_id) * FROM governance.sync_versions WHERE published
  ORDER BY dataset_id,version_sequence DESC
 ), links AS MATERIALIZED (
  SELECT * FROM governance.resolved_source_links() WHERE relation='same'
 ), eligible AS (
  SELECT DISTINCT l.principal_id,e.service_id,e.source_body->'revisions'->>'service' AS revision,
    r.code,r.name
  FROM links l JOIN governance.published_heads h ON h.entity_id=l.principal_id
  JOIN data.service_revisions public_service ON public_service.revision_id=h.revision_id
  JOIN active v ON true JOIN governance.sync_entries e ON e.version_id=v.version_id AND e.service_id=l.secondary_id
  JOIN governance.working_heads w ON w.entity_id=e.service_id AND w.revision_id=(e.source_body->'revisions'->>'service')::uuid
  JOIN governance.entity_revisions rev ON rev.revision_id=w.revision_id AND rev.sealed_at IS NOT NULL
  JOIN sources.datasets ds ON ds.dataset_id=v.dataset_id JOIN sources.registry r USING(source_id)
  JOIN LATERAL (SELECT outcome FROM governance.review_decisions d WHERE d.target_revision_id=w.revision_id
                ORDER BY decision_sequence DESC LIMIT 1) reviewed ON reviewed.outcome='approved'
  LEFT JOIN LATERAL (SELECT action,details->>'cause' AS cause FROM audit.events a
                    WHERE a.entity_id=e.service_id AND a.action IN('withdraw','publish')
                    ORDER BY event_id DESC LIMIT 1) last_action ON true
  WHERE e.state='loaded' AND (principal IS NULL OR l.principal_id=principal)
    AND public_service.operational_status<>'defunct'
    AND NOT EXISTS(SELECT FROM governance.published_heads own WHERE own.entity_id=e.service_id)
    AND NOT EXISTS(SELECT FROM links chain WHERE chain.secondary_id=l.principal_id)
    AND NOT COALESCE(last_action.action='withdraw' AND last_action.cause='moderation',false)
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('principal_id',e.principal_id,'service_id',e.service_id,
  'revision_id',e.revision,'source_code',e.code,'source_name',e.name,
  'contacts',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'channel',c.channel_type,'value',c.value,'purpose',c.purpose_code,
     'label',governance.supplement_text(c.label_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.sort_order,c.component_id)
     FROM data.contact_entries c WHERE c.revision_id=e.revision::uuid AND c.is_public
      AND NOT EXISTS(SELECT FROM governance.published_heads ph
       JOIN data.contact_entries hidden ON hidden.revision_id=ph.revision_id
       WHERE ph.entity_id=e.principal_id AND NOT hidden.is_public
        AND governance.contact_aliases(hidden.channel_type,hidden.value)
          && governance.contact_aliases(c.channel_type,c.value))),'[]'),
  'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'kind',c.condition_kind,'state',c.requirement_state,
     'details',governance.supplement_text(c.details_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.component_id)
     FROM data.access_conditions c WHERE c.revision_id=e.revision::uuid),'[]')) ORDER BY e.principal_id,e.service_id),'[]')
 FROM eligible e
$$;

DROP TRIGGER retain_contact_protections ON governance.published_heads;
DROP TRIGGER retain_contact_protection_links ON governance.source_service_links;
DROP TRIGGER retain_contact_protection_identity ON governance.sync_entries;
DROP TRIGGER capture_contact_protections ON governance.publications;
DROP TRIGGER contact_protection_links ON governance.source_service_links;
DROP TRIGGER contact_protection_source_identity ON governance.sync_entries;
DROP FUNCTION api.service_contact_visible(uuid,uuid,uuid,uuid);
DROP FUNCTION governance.retain_contact_protection_context(),governance.retain_current_contact_protections(uuid);
DROP FUNCTION governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text),
 governance.refresh_contact_protection_scopes(),governance.capture_publication_contact_protections(),
 governance.capture_private_contact_revision(uuid,uuid),governance.propagate_contact_protection_scopes(),
 governance.read_contact_protections(uuid),governance.contact_allowed_by_protection(jsonb,text,text,text,boolean),
 governance.effective_contact_protections(uuid),governance.protection_service_group(uuid),
 governance.protection_phone_uncertain(text,text,text),governance.protection_contact_keys(text,text,text),
 governance.protection_phone_labelled(text,text),governance.protection_phone_keys(text),
 governance.protection_phone_key(text),governance.protection_phone_text(text),governance.protection_phone_whitespace(text);
DROP TABLE governance.contact_protection_resolutions,governance.contact_protection_scopes,governance.contact_protections;
-- Retain the cluster-wide NOLOGIN role/memberships; other databases may use them.
COMMIT;
