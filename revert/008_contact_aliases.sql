-- Revert egi_database:008_contact_aliases; restore the exact 007 projection.
BEGIN;
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
        AND governance.contact_fingerprint(hidden.channel_type,hidden.value)
          =governance.contact_fingerprint(c.channel_type,c.value))),'[]'),
  'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'kind',c.condition_kind,'state',c.requirement_state,
     'details',governance.supplement_text(c.details_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.component_id)
     FROM data.access_conditions c WHERE c.revision_id=e.revision::uuid),'[]')) ORDER BY e.principal_id,e.service_id),'[]')
 FROM eligible e
$$;

DROP FUNCTION governance.contact_aliases(text,text);
COMMIT;
