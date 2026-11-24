-- Deploy egi_database:007_linked_supplements
-- requires: 006_hardening
BEGIN;

-- Resolve identifiers through history, then keep the last decision on each pair.
-- Private helper: readers receive only the guarded fragment projection below.
CREATE FUNCTION governance.resolved_source_links()
RETURNS TABLE(principal_id uuid,secondary_id uuid,relation text,link_sequence bigint)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 WITH resolved AS (
  SELECT l.*,a.service_id AS a_id,b.service_id AS b_id
  FROM governance.source_service_links l
  JOIN LATERAL (
   SELECT e.service_id FROM governance.sync_entries e JOIN governance.sync_versions v USING(version_id)
   WHERE v.published AND v.dataset_id=l.a_dataset_id AND e.identity->'keys' ? l.a_key AND e.service_id IS NOT NULL
   ORDER BY v.version_sequence DESC,(e.state='not_observed'),e.entry_number DESC LIMIT 1
  ) a ON true
  JOIN LATERAL (
   SELECT e.service_id FROM governance.sync_entries e JOIN governance.sync_versions v USING(version_id)
   WHERE v.published AND v.dataset_id=l.b_dataset_id AND e.identity->'keys' ? l.b_key AND e.service_id IS NOT NULL
   ORDER BY v.version_sequence DESC,(e.state='not_observed'),e.entry_number DESC LIMIT 1
  ) b ON true
 ), latest AS (
  SELECT DISTINCT ON(least(a_id,b_id),greatest(a_id,b_id)) * FROM resolved
  ORDER BY least(a_id,b_id),greatest(a_id,b_id),link_sequence DESC
 )
 SELECT CASE WHEN principal='a' THEN a_id ELSE b_id END,
        CASE WHEN principal='a' THEN b_id ELSE a_id END,relation,link_sequence FROM latest
$$;

-- Called only for eligible public fragment fields by the definer projection.
CREATE FUNCTION governance.supplement_text(content uuid,revision uuid,preferred text)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),
  'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,
  'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class)
 FROM i18n.content_units c
 LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred
 LEFT JOIN i18n.translation_publications p USING(publication_id)
 LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id
 WHERE c.content_id=content AND EXISTS(SELECT FROM i18n.revision_content_links l
                                      WHERE l.revision_id=revision AND l.content_id=content)
$$;

CREATE FUNCTION governance.supplement_provenance(decision uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('source_id',r.source_id,'source_code',r.code,
  'source_name',r.name,'homepage',r.homepage,'retrieved_at',c.retrieved_at,'published_at',c.published_at)),'[]')
 FROM governance.value_evidence e JOIN sources.assertions a USING(assertion_id)
 JOIN sources.normalized_subjects n USING(subject_id) JOIN sources.processing_runs p USING(run_id)
 JOIN sources.captures c ON c.capture_id=p.capture_id JOIN sources.datasets d USING(dataset_id)
 JOIN sources.registry r USING(source_id)
 WHERE e.value_decision_id=decision AND e.evidence_role='supporting'
$$;

CREATE FUNCTION governance.contact_fingerprint(channel text,value text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN channel IN('phone','whatsapp') THEN 'number:'||
  CASE WHEN btrim(value) LIKE '+39%' OR btrim(value) LIKE '0039%'
       OR (length(regexp_replace(value,'[^0-9]','','g'))=12 AND regexp_replace(value,'[^0-9]','','g') LIKE '393%')
   THEN regexp_replace(regexp_replace(value,'[^0-9]','','g'),'^(0039|39)','')
   ELSE regexp_replace(value,'[^0-9]','','g') END
  ELSE channel||':'||lower(btrim(value)) END
$$;

-- Approved review is permission for these fragments only, not publication of the
-- secondary service. Working/published source versions alone never grant it.
CREATE FUNCTION api.linked_service_supplements(principal uuid DEFAULT NULL,preferred text DEFAULT NULL)
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
        AND governance.contact_fingerprint(hidden.channel_type,hidden.value)
          =governance.contact_fingerprint(c.channel_type,c.value))),'[]'),
  'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'kind',c.condition_kind,'state',c.requirement_state,
     'details',governance.supplement_text(c.details_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.component_id)
     FROM data.access_conditions c WHERE c.revision_id=e.revision::uuid),'[]')) ORDER BY e.principal_id,e.service_id),'[]')
 FROM eligible e
$$;

REVOKE ALL ON FUNCTION governance.resolved_source_links(),governance.supplement_text(uuid,uuid,text),
 governance.supplement_provenance(uuid),governance.contact_fingerprint(text,text),
 api.linked_service_supplements(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.linked_service_supplements(uuid,text) TO egi_reader;
COMMIT;
