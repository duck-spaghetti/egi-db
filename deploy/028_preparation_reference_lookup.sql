-- Deploy egi_database:028_preparation_reference_lookup
-- requires: 027_preparation_category_matches
-- EGI-117 consumer handoff: bounded named lookup of already selected IDs.
BEGIN;
CREATE OR REPLACE FUNCTION preparation.catalog(query jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; page_size integer:=COALESCE((query->>'limit')::integer,50); start_at integer:=COALESCE((query->>'offset')::integer,0);
 search text:=lower(COALESCE(query->>'search','')); territory uuid:=(query->>'territory_id')::uuid; axis uuid:=(query->>'axis_id')::uuid;
BEGIN
 PERFORM preparation.actor();
 PERFORM preparation.closed(query,ARRAY['kind','search','limit','offset','territory_id','axis_id','adoption_id','organization_ids'],ARRAY['kind']);
 IF page_size NOT BETWEEN 1 AND 50 OR start_at NOT BETWEEN 0 AND 100000 OR length(search)>500 OR query->>'kind' NOT IN ('organization','classification','taxonomy_context') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_catalog_query'; END IF;
 IF query ? 'organization_ids' THEN
  IF query->>'kind' IS DISTINCT FROM 'organization' OR jsonb_typeof(query->'organization_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(query->'organization_ids')>100 OR
   EXISTS(SELECT FROM jsonb_array_elements(query->'organization_ids') id WHERE jsonb_typeof(id) IS DISTINCT FROM 'string') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_catalog_query'; END IF;
 END IF;
 IF query->>'kind'='organization' THEN
  WITH entries AS (
   SELECT o.entity_id,c.original_text AS label, h.revision_id AS work,p.revision_id AS public_head,
    COALESCE((SELECT jsonb_agg(t.territory_id ORDER BY t.territory_id) FROM governance.revision_territories t WHERE t.revision_id=CASE WHEN preparation.organization_visible(o.entity_id) THEN h.revision_id ELSE p.revision_id END),'[]') AS territories
   FROM data.organizations o JOIN governance.working_heads h USING(entity_id)
   LEFT JOIN governance.published_heads p USING(entity_id)
   JOIN i18n.revision_content_links l ON l.revision_id=CASE WHEN preparation.organization_visible(o.entity_id) THEN h.revision_id ELSE p.revision_id END AND l.field_code='name'
   JOIN i18n.content_units c USING(content_id)
   WHERE (preparation.organization_visible(o.entity_id) OR p.entity_id IS NOT NULL) AND strpos(lower(c.original_text),search)>0
    AND (NOT query ? 'organization_ids' OR o.entity_id IN (SELECT id::uuid FROM jsonb_array_elements_text(query->'organization_ids') id))
   ORDER BY lower(c.original_text),o.entity_id LIMIT page_size+1 OFFSET start_at)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('label',label,'published',public_head IS NOT NULL,'territories',territories,
   'target',jsonb_build_object('kind','organization','organization_id',entity_id,'expected_work',work,'expected_public',public_head))),'[]') INTO result FROM entries;
 ELSIF query->>'kind'='taxonomy_context' THEN
  WITH entries AS (
   SELECT a.adoption_id,a.territory_id,a.release_id,a.effective_from,a.effective_until,ra.axis_id,ra.label,r.version,
    c.original_text AS territory_label,ax.code AS axis_code
   FROM taxonomy.territory_adoptions a JOIN taxonomy.releases r USING(release_id) JOIN taxonomy.release_axes ra USING(release_id)
   JOIN taxonomy.axes ax ON ax.axis_id=ra.axis_id JOIN governance.published_heads h ON h.entity_id=a.territory_id
   JOIN i18n.revision_content_links l ON l.revision_id=h.revision_id AND l.field_code='name' JOIN i18n.content_units c USING(content_id)
   WHERE a.effective_from<=current_date AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND r.sealed_at IS NOT NULL
    AND (territory IS NULL OR a.territory_id=territory)
    AND strpos(lower(c.original_text||' '||ra.label),search)>0
   ORDER BY lower(c.original_text),a.adoption_id,ra.axis_id LIMIT page_size+1 OFFSET start_at)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('adoption_id',adoption_id,'territory_id',territory_id,'territory_label',territory_label,
   'release_id',release_id,'release_version',version,'axis_id',axis_id,'axis_label',label,'axis_code',axis_code,
   'effective_from',effective_from,'effective_until',effective_until)),'[]') INTO result FROM entries;
 ELSE
  IF territory IS NULL OR axis IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='taxonomy_context_required'; END IF;
  WITH entries AS (
   SELECT a.*,rt.term_id,rt.term_revision_id,ra.label AS axis_label,c.original_text AS label,
    COALESCE((SELECT jsonb_agg(b.parent_term_id ORDER BY b.parent_term_id) FROM taxonomy.broader_links b WHERE b.release_id=a.release_id AND b.child_term_id=rt.term_id),'[]') AS broader
   FROM taxonomy.territory_adoptions a JOIN taxonomy.releases r USING(release_id)
   JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id
   JOIN taxonomy.release_axes ra ON ra.release_id=rt.release_id AND ra.axis_id=rt.axis_id
   JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name'
   JOIN i18n.content_units c USING(content_id)
   WHERE a.territory_id=territory AND rt.axis_id=axis AND a.effective_from<=current_date
    AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND r.sealed_at IS NOT NULL AND tr.active
    AND (NOT query ? 'adoption_id' OR a.adoption_id=(query->>'adoption_id')::uuid)
    AND strpos(lower(c.original_text),search)>0
   ORDER BY lower(c.original_text),a.adoption_id,rt.term_id LIMIT page_size+1 OFFSET start_at)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('label',label,'axis_label',axis_label,'territory_id',territory_id,
   'effective_from',effective_from,'effective_until',effective_until,'broader',broader,'published',true,
   'target',jsonb_build_object('kind','classification','adoption_id',adoption_id,'release_id',release_id,'term_id',term_id,'axis_id',axis))),'[]') INTO result FROM entries;
 END IF;
 RETURN jsonb_build_object('entries',(SELECT COALESCE(jsonb_agg(e ORDER BY n),'[]') FROM jsonb_array_elements(result) WITH ORDINALITY x(e,n) WHERE n<=page_size),
  'next_offset',CASE WHEN jsonb_array_length(result)>page_size THEN start_at+page_size END,'complete',jsonb_array_length(result)<=page_size,
  'context',CASE WHEN query->>'kind'='organization' THEN jsonb_build_object('organization_name',COALESCE(query->>'search',''),'catalog_digest',preparation.organization_name_digest(COALESCE(query->>'search',''))) ELSE query-'search'-'limit'-'offset' END);
END $$;
COMMIT;
