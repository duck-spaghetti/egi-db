-- Deploy egi_database:025_preparation_reference_catalog
-- requires: 024_preparation_fact_candidates
-- EGI-117: authorized bounded catalog and explicit, attributable selections.
BEGIN;
CREATE FUNCTION preparation.organization_visible(entity uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(
  SELECT FROM governance.actor_grants g WHERE g.actor_id=governance.current_actor() AND g.capability='propose'
  AND g.valid_from<=clock_timestamp() AND (g.valid_until IS NULL OR g.valid_until>clock_timestamp())
  AND (g.territory_id IS NULL OR (EXISTS(SELECT FROM governance.working_heads h JOIN governance.revision_territories t USING(revision_id) WHERE h.entity_id=entity)
   AND NOT EXISTS(SELECT FROM governance.working_heads h JOIN governance.revision_territories t USING(revision_id)
    WHERE h.entity_id=entity AND NOT EXISTS(SELECT FROM governance.actor_grants p WHERE p.actor_id=g.actor_id AND p.capability='propose'
     AND p.territory_id=t.territory_id AND p.valid_from<=clock_timestamp() AND (p.valid_until IS NULL OR p.valid_until>clock_timestamp()))))))
$$;

-- Same-name candidates are a warning/context token, never an identity rule.
CREATE FUNCTION preparation.organization_name_digest(name text) RETURNS text
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT preparation.digest(COALESCE(jsonb_agg(jsonb_build_array(o.entity_id,h.revision_id,p.revision_id) ORDER BY o.entity_id),'[]'))
 FROM data.organizations o JOIN governance.working_heads h USING(entity_id) LEFT JOIN governance.published_heads p USING(entity_id)
 JOIN i18n.revision_content_links l ON l.revision_id=CASE WHEN preparation.organization_visible(o.entity_id) THEN h.revision_id ELSE p.revision_id END AND l.field_code='name'
 JOIN i18n.content_units c USING(content_id)
 WHERE (preparation.organization_visible(o.entity_id) OR p.entity_id IS NOT NULL) AND lower(btrim(c.original_text))=lower(btrim(name))
$$;

CREATE FUNCTION preparation.catalog(query jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; page_size integer:=COALESCE((query->>'limit')::integer,50); start_at integer:=COALESCE((query->>'offset')::integer,0);
 search text:=lower(COALESCE(query->>'search','')); territory uuid:=(query->>'territory_id')::uuid; axis uuid:=(query->>'axis_id')::uuid;
BEGIN
 PERFORM preparation.actor();
 PERFORM preparation.closed(query,ARRAY['kind','search','limit','offset','territory_id','axis_id','adoption_id'],ARRAY['kind']);
 IF page_size NOT BETWEEN 1 AND 50 OR start_at NOT BETWEEN 0 AND 100000 OR length(search)>500 OR query->>'kind' NOT IN ('organization','classification','taxonomy_context') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_catalog_query'; END IF;
 IF query->>'kind'='organization' THEN
  WITH entries AS (
   SELECT o.entity_id,c.original_text AS label, h.revision_id AS work,p.revision_id AS public_head,
    COALESCE((SELECT jsonb_agg(t.territory_id ORDER BY t.territory_id) FROM governance.revision_territories t WHERE t.revision_id=CASE WHEN preparation.organization_visible(o.entity_id) THEN h.revision_id ELSE p.revision_id END),'[]') AS territories
   FROM data.organizations o JOIN governance.working_heads h USING(entity_id)
   LEFT JOIN governance.published_heads p USING(entity_id)
   JOIN i18n.revision_content_links l ON l.revision_id=CASE WHEN preparation.organization_visible(o.entity_id) THEN h.revision_id ELSE p.revision_id END AND l.field_code='name'
   JOIN i18n.content_units c USING(content_id)
   WHERE (preparation.organization_visible(o.entity_id) OR p.entity_id IS NOT NULL) AND strpos(lower(c.original_text),search)>0
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
CREATE FUNCTION preparation.reference_catalog(wid uuid,query jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN PERFORM preparation.authorize(wid); RETURN preparation.catalog(query); END $$;
CREATE FUNCTION editorial.reference_catalog(contribution uuid,query jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM preparation.actor();
 IF NOT EXISTS(SELECT FROM editorial.community_snapshots WHERE contribution_id=contribution) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 RETURN preparation.catalog(query);
END $$;

-- Structural validation and a fresh catalog check are shared by private saves
-- and acceptance. A source name cannot supply a canonical ID or an implicit role.
CREATE FUNCTION preparation.validate_reference(fact jsonb,context jsonb,target jsonb) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE body jsonb; k text; scopes uuid[];
BEGIN
 IF fact->>'kind'='organization_name' THEN
  IF context IS DISTINCT FROM '{}'::jsonb THEN
   PERFORM preparation.closed(context,ARRAY['organization_name','catalog_digest'],ARRAY['organization_name','catalog_digest']);
   IF jsonb_typeof(context->'organization_name') IS DISTINCT FROM 'string' OR context->>'catalog_digest' IS DISTINCT FROM preparation.organization_name_digest(context->>'organization_name') THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='organization_catalog_changed'; END IF;
  END IF;
  IF target->>'kind'='organization' THEN
   PERFORM preparation.closed(target,ARRAY['kind','organization_id','expected_work','expected_public'],ARRAY['kind','organization_id','expected_work','expected_public']);
   IF NOT EXISTS(SELECT FROM data.organizations o JOIN governance.working_heads w USING(entity_id)
    LEFT JOIN governance.published_heads p USING(entity_id) WHERE o.entity_id=(target->>'organization_id')::uuid
    AND w.revision_id=(target->>'expected_work')::uuid AND p.revision_id IS NOT DISTINCT FROM (target->>'expected_public')::uuid
    AND (preparation.organization_visible(o.entity_id) OR p.entity_id IS NOT NULL)) THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='reference_heads_changed'; END IF;
  ELSIF target->>'kind'='new_organization' THEN
   PERFORM preparation.closed(target,ARRAY['kind','body'],ARRAY['kind','body']); body:=target->'body';
   IF context->>'organization_name' IS DISTINCT FROM body->>'name' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='organization_catalog_context_required'; END IF;
   PERFORM preparation.closed(body,ARRAY['name','original_language','description','organization_type','website','territories'],ARRAY['name','original_language','territories']);
   FOREACH k IN ARRAY ARRAY['name','original_language','description','organization_type','website'] LOOP
    IF body ? k AND (jsonb_typeof(body->k) IS DISTINCT FROM 'string' OR length(btrim(body->>k)) NOT BETWEEN 1 AND 50000) THEN
     RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_organization_body'; END IF;
   END LOOP;
   IF jsonb_typeof(body->'territories') IS DISTINCT FROM 'array' OR jsonb_array_length(body->'territories')>1000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_organization_body'; END IF;
   SELECT COALESCE(array_agg(v::uuid),ARRAY[]::uuid[]) INTO scopes FROM jsonb_array_elements_text(body->'territories') v;
   IF EXISTS(SELECT FROM unnest(scopes) t WHERE NOT EXISTS(SELECT FROM geo.territories WHERE entity_id=t)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_organization_body'; END IF;
   PERFORM governance.require_capability('propose',scopes);
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_reference_target'; END IF;
 ELSIF fact->>'kind'='category_label' THEN
  IF fact->>'subject'<>'service' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='classification_subject_required'; END IF;
  PERFORM preparation.closed(context,ARRAY['territory_id','axis_id'],ARRAY['territory_id','axis_id']);
  PERFORM preparation.closed(target,ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  IF target->>'kind' IS DISTINCT FROM 'classification' OR target->>'axis_id' IS DISTINCT FROM context->>'axis_id' OR NOT EXISTS(
   SELECT FROM taxonomy.territory_adoptions a JOIN taxonomy.releases r USING(release_id)
   JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id
   WHERE a.adoption_id=(target->>'adoption_id')::uuid AND a.release_id=(target->>'release_id')::uuid
    AND a.territory_id=(context->>'territory_id')::uuid AND rt.term_id=(target->>'term_id')::uuid AND rt.axis_id=(target->>'axis_id')::uuid
    AND a.effective_from<=current_date AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND r.sealed_at IS NOT NULL AND tr.active) THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='taxonomy_context_stale'; END IF;
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_reference_target'; END IF;
END $$;

ALTER FUNCTION preparation.validate_source_facts(uuid,jsonb) RENAME TO validate_source_facts_literal;
CREATE FUNCTION preparation.validate_source_facts(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb; f jsonb; c jsonb; seen uuid[]:=ARRAY[]::uuid[];
BEGIN
 PERFORM preparation.validate_source_facts_literal(wid,jsonb_set(payload,'{resolutions}','[]'));
 IF jsonb_typeof(payload->'resolutions') IS DISTINCT FROM 'array' OR jsonb_array_length(payload->'resolutions')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reference_resolution_not_available'; END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(payload->'resolutions') LOOP
  PERFORM preparation.closed(r,ARRAY['fact_id','state','context','candidates','selected','confirmation'],ARRAY['fact_id','state','context','candidates']);
  SELECT fact INTO f FROM jsonb_array_elements(payload->'source_facts') fact WHERE fact->>'fact_id'=r->>'fact_id';
  IF f IS NULL OR jsonb_typeof(r->'fact_id') IS DISTINCT FROM 'string' OR r->>'state' NOT IN ('unresolved','proposed','confirmed','ignored') OR
   jsonb_typeof(r->'state') IS DISTINCT FROM 'string' OR jsonb_typeof(r->'candidates') IS DISTINCT FROM 'array' OR
   jsonb_array_length(r->'candidates')>100 OR jsonb_typeof(r->'context') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reference_resolution_not_available'; END IF;
  IF (r->>'fact_id')::uuid=ANY(seen) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_fact_resolution'; END IF;
  seen:=array_append(seen,(r->>'fact_id')::uuid);
  IF r->>'state' IN ('unresolved','ignored') THEN
   IF r->'context'<>'{}'::jsonb OR r->'candidates'<>'[]'::jsonb OR r ? 'selected' OR r ? 'confirmation' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reference_resolution_not_available'; END IF;
   CONTINUE;
  END IF;
  IF NOT f ? 'value' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_resolution_stale'; END IF;
  FOR c IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP
   PERFORM preparation.closed(c,ARRAY['target','rank','reason'],ARRAY['target','rank','reason']);
   IF c#>>'{target,kind}'='new_organization' OR jsonb_typeof(c->'rank') IS DISTINCT FROM 'number' OR
    (c->>'rank')::numeric NOT BETWEEN 1 AND 100 OR (c->>'rank')::numeric<>trunc((c->>'rank')::numeric) OR
    jsonb_typeof(c->'reason') IS DISTINCT FROM 'string' OR length(btrim(c->>'reason')) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_reference_candidate'; END IF;
   PERFORM preparation.validate_reference(f,r->'context',c->'target');
  END LOOP;
  IF r->>'state'='confirmed' THEN
   IF NOT r->'selected' ? 'target' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reference_resolution_not_available'; END IF;
   PERFORM preparation.closed(r->'selected',ARRAY['target','role'],ARRAY['target']);
   PERFORM preparation.validate_reference(f,r->'context',r#>'{selected,target}');
   IF (f->>'kind'='organization_name' AND (jsonb_typeof(r#>'{selected,role}') IS DISTINCT FROM 'string' OR length(btrim(r#>>'{selected,role}')) NOT BETWEEN 1 AND 100)) OR
    (f->>'kind'='category_label' AND r->'selected' ? 'role') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='explicit_organization_role_required'; END IF;
  ELSIF r ? 'selected' OR r ? 'confirmation' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unconfirmed_reference_selection'; END IF;
 END LOOP;
END $$;

-- Stamp only newly confirmed/changed choices. Clients cannot impersonate the
-- confirmer; an unchanged choice retains its original actor and item base.
CREATE FUNCTION preparation.stamp_reference_confirmation() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE previous jsonb; base uuid; r jsonb; old jsonb; f jsonb; result jsonb:='[]'; binding jsonb;
BEGIN
 IF NEW.payload->'schema_version'<>'2'::jsonb THEN RETURN NEW; END IF;
 SELECT i.current_version_id,v.payload INTO base,previous FROM preparation.items i LEFT JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.id=NEW.item_id;
 FOR r IN SELECT * FROM jsonb_array_elements(NEW.payload->'resolutions') LOOP
  IF r->>'state'='confirmed' THEN
   SELECT x INTO old FROM jsonb_array_elements(COALESCE(previous->'resolutions','[]')) x WHERE x->>'fact_id'=r->>'fact_id';
   SELECT x INTO f FROM jsonb_array_elements(NEW.payload->'source_facts') x WHERE x->>'fact_id'=r->>'fact_id';
   IF old->>'state'='confirmed' AND old->'selected'=r->'selected' AND old->'context'=r->'context' THEN
    binding:=old->'confirmation';
   ELSE binding:=jsonb_build_object('actor_id',preparation.actor(),'item_version',base,'fact_value',f->'value'); END IF;
   r:=(r-'confirmation')||jsonb_build_object('confirmation',binding);
  END IF;
  result:=result||jsonb_build_array(r);
 END LOOP;
 NEW.payload:=jsonb_set(NEW.payload,'{resolutions}',result);
 RETURN NEW;
END $$;
CREATE TRIGGER reference_confirmation BEFORE INSERT ON preparation.item_versions FOR EACH ROW EXECUTE FUNCTION preparation.stamp_reference_confirmation();
REVOKE ALL ON FUNCTION preparation.organization_visible(uuid),preparation.organization_name_digest(text),preparation.catalog(jsonb),preparation.validate_reference(jsonb,jsonb,jsonb),
 preparation.validate_source_facts_literal(uuid,jsonb),preparation.validate_source_facts(uuid,jsonb),preparation.stamp_reference_confirmation(),
 preparation.reference_catalog(uuid,jsonb),editorial.reference_catalog(uuid,jsonb) FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
GRANT EXECUTE ON FUNCTION preparation.reference_catalog(uuid,jsonb),editorial.reference_catalog(uuid,jsonb) TO egi_editorial;
COMMIT;
