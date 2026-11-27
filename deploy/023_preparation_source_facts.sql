-- Deploy egi_database:023_preparation_source_facts
-- requires: 022_community_evidence_context
-- EGI-114: versioned literal claims; matching/acceptance follows in EGI-117.
BEGIN;
ALTER FUNCTION preparation.validate_payload(uuid,jsonb) RENAME TO validate_payload_v1;
ALTER FUNCTION preparation.save_items_initial(uuid,jsonb,uuid) RENAME TO save_items_initial_v1;

-- A narrow identity register avoids scanning historical JSON on every save and
-- prevents a fact ID from being borrowed by another card/preparation. Cascade
-- follows the existing private retention purge, never the editorial snapshot.
CREATE TABLE preparation.fact_identities (
 fact_id uuid PRIMARY KEY,
 item_id uuid NOT NULL REFERENCES preparation.items(id) ON DELETE CASCADE,
 input_id uuid NOT NULL REFERENCES preparation.inputs(id),
 subject text NOT NULL CHECK(subject IN ('service','location')),
 kind text NOT NULL CHECK(kind IN ('organization_name','category_label')),
 source_value text NOT NULL
);
CREATE INDEX fact_identities_item ON preparation.fact_identities(item_id);
REVOKE ALL ON preparation.fact_identities FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;

CREATE FUNCTION preparation.validate_source_facts(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE fact jsonb; resolution jsonb; locator jsonb; origin jsonb; idx integer; pointer text; k text; part text;
 proxy jsonb:=payload-'source_facts'-'resolutions'; locators jsonb:='[]'; origins jsonb:='{}';
BEGIN
 PERFORM preparation.closed(payload,ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions'],
 ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions']);
 IF jsonb_typeof(payload->'source_facts') IS DISTINCT FROM 'array' OR jsonb_typeof(payload->'resolutions') IS DISTINCT FROM 'array' OR
    jsonb_typeof(payload->'evidence') IS DISTINCT FROM 'array' OR jsonb_typeof(payload->'field_origins') IS DISTINCT FROM 'object' OR
    jsonb_array_length(payload->'source_facts')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_facts'; END IF;
 FOR fact IN SELECT * FROM jsonb_array_elements(payload->'source_facts') LOOP
  PERFORM preparation.closed(fact,ARRAY['fact_id','subject','kind','source_value','value'],ARRAY['fact_id','subject','kind','source_value']);
  IF jsonb_typeof(fact->'fact_id') IS DISTINCT FROM 'string' OR
   fact->>'subject' NOT IN ('service','location') OR jsonb_typeof(fact->'subject') IS DISTINCT FROM 'string' OR
   fact->>'kind' NOT IN ('organization_name','category_label') OR jsonb_typeof(fact->'kind') IS DISTINCT FROM 'string' OR
   jsonb_typeof(fact->'source_value') IS DISTINCT FROM 'string' OR length(btrim(fact->>'source_value')) NOT BETWEEN 1 AND 50000 OR
   (fact ? 'value' AND (jsonb_typeof(fact->'value') IS DISTINCT FROM 'string' OR length(btrim(fact->>'value')) NOT BETWEEN 1 AND 50000)) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_fact'; END IF;
  PERFORM (fact->>'fact_id')::uuid;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(payload->'source_facts') f GROUP BY (f->>'fact_id')::uuid HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_source_fact_id'; END IF;
 FOR k,origin IN SELECT * FROM jsonb_each(payload->'field_origins') LOOP
  IF starts_with(k,'/source_facts/') THEN
   IF k !~ '^/source_facts/(0|[1-9][0-9]*)/(source_value|value)$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_fact_path'; END IF;
   idx:=split_part(k,'/',3)::integer;
   IF idx>=jsonb_array_length(payload->'source_facts') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_fact_path'; END IF;
   origins:=origins||jsonb_build_object('/service/fact_origin/'||idx||'/'||split_part(k,'/',4),origin);
  ELSE origins:=origins||jsonb_build_object(k,origin); END IF;
 END LOOP;
 FOR locator IN SELECT * FROM jsonb_array_elements(payload->'evidence') LOOP
  pointer:=locator->>'path';
  IF starts_with(pointer,'/source_facts/') THEN
   IF pointer !~ '^/source_facts/(0|[1-9][0-9]*)/source_value$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_fact_path'; END IF;
   idx:=split_part(pointer,'/',3)::integer;
   fact:=payload->'source_facts'->idx;
   IF fact IS NULL OR locator->>'kind' NOT IN ('stated','interpreted') OR NOT locator ? 'span' OR
      strpos(COALESCE(locator->>'quote',''),fact->>'source_value')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_evidence_mismatch'; END IF;
   -- Reuse the v1 exact-input/hash/span validator; this proxy is never stored.
   locators:=locators||jsonb_build_array(jsonb_set(locator,'{path}','"/service/name"'));
  ELSE locators:=locators||jsonb_build_array(locator); END IF;
 END LOOP;
 proxy:=proxy||jsonb_build_object('schema_version',1,'evidence',locators,'field_origins',origins);
 PERFORM preparation.validate_payload_v1(wid,proxy);
 FOR fact,idx IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(payload->'source_facts') WITH ORDINALITY LOOP
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') e WHERE e->>'path'='/source_facts/'||idx||'/source_value') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_evidence_required'; END IF;
  IF fact->>'value' IS DISTINCT FROM fact->>'source_value' THEN
   part:=payload#>>ARRAY['field_origins','/source_facts/'||idx||'/value','state'];
   IF part IS DISTINCT FROM (CASE WHEN fact ? 'value' THEN 'manual' ELSE 'cleared' END) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_manual_origin_required'; END IF;
  END IF;
 END LOOP;
 FOR resolution IN SELECT * FROM jsonb_array_elements(payload->'resolutions') LOOP
  PERFORM preparation.closed(resolution,ARRAY['fact_id','state','context','candidates','selected'],ARRAY['fact_id','state','context','candidates']);
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(payload->'source_facts') f WHERE (f->>'fact_id')::uuid=(resolution->>'fact_id')::uuid) OR
   jsonb_typeof(resolution->'fact_id') IS DISTINCT FROM 'string' OR
   jsonb_typeof(resolution->'state') IS DISTINCT FROM 'string' OR resolution->>'state' NOT IN ('unresolved','ignored') OR
   resolution->'context' IS DISTINCT FROM '{}'::jsonb OR resolution->'candidates' IS DISTINCT FROM '[]'::jsonb OR resolution ? 'selected' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reference_resolution_not_available'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(payload->'resolutions') r GROUP BY (r->>'fact_id')::uuid HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_fact_resolution'; END IF;
END $$;

CREATE FUNCTION preparation.validate_payload(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF payload->'schema_version'='2'::jsonb THEN PERFORM preparation.validate_source_facts(wid,payload);
 ELSE PERFORM preparation.validate_payload_v1(wid,payload); END IF;
END $$;

CREATE FUNCTION preparation.citation_unchanged(previous jsonb,payload jsonb,locator jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE path text[]:=string_to_array(substr(locator->>'path',2),'/'); old_locator jsonb; old_path text[]; fact jsonb; old_fact jsonb;
BEGIN
 IF path[1]='source_facts' THEN
  SELECT e INTO old_locator FROM jsonb_array_elements(previous->'evidence') e WHERE e->>'id'=locator->>'id';
  old_path:=string_to_array(substr(old_locator->>'path',2),'/');
  IF old_path[1] IS DISTINCT FROM 'source_facts' THEN RETURN false; END IF;
  fact:=payload->'source_facts'->(path[2]::integer); old_fact:=previous->'source_facts'->(old_path[2]::integer);
  RETURN (old_fact->>'fact_id')::uuid IS NOT DISTINCT FROM (fact->>'fact_id')::uuid AND
   old_fact->>'source_value' IS NOT DISTINCT FROM fact->>'source_value';
 END IF;
 SELECT array_agg(replace(replace(part,'~1','/'),'~0','~') ORDER BY ord) INTO path
  FROM unnest(path) WITH ORDINALITY AS p(part,ord);
 RETURN previous#>path IS NOT DISTINCT FROM payload#>path;
END $$;

CREATE FUNCTION preparation.guard_source_fact_version() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE wid uuid; previous jsonb; op text; fact jsonb; identity preparation.fact_identities; evidence_input uuid; idx integer;
BEGIN
 SELECT i.workspace_id,v.payload INTO wid,previous FROM preparation.items i
  LEFT JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.id=NEW.item_id;
 IF previous->'schema_version'='2'::jsonb AND NEW.payload->'schema_version'='1'::jsonb THEN
  SELECT kind INTO op FROM preparation.operations WHERE id=NEW.operation_id;
  IF op='undo' THEN NEW.payload:=NEW.payload||'{"schema_version":2,"source_facts":[],"resolutions":[]}';
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='item_schema_downgrade'; END IF;
 END IF;
 IF NEW.payload->'schema_version'='2'::jsonb THEN
  PERFORM preparation.validate_payload(wid,NEW.payload);
  FOR fact,idx IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(NEW.payload->'source_facts') WITH ORDINALITY LOOP
   SELECT (e->>'input_id')::uuid INTO evidence_input FROM jsonb_array_elements(NEW.payload->'evidence') e
    WHERE e->>'path'='/source_facts/'||idx||'/source_value' LIMIT 1;
   INSERT INTO preparation.fact_identities(fact_id,item_id,input_id,subject,kind,source_value)
    VALUES((fact->>'fact_id')::uuid,NEW.item_id,evidence_input,fact->>'subject',fact->>'kind',fact->>'source_value') ON CONFLICT DO NOTHING;
   SELECT * INTO identity FROM preparation.fact_identities WHERE fact_id=(fact->>'fact_id')::uuid;
   IF identity.item_id<>NEW.item_id OR identity.subject<>fact->>'subject' OR identity.kind<>fact->>'kind' OR identity.source_value<>fact->>'source_value' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_identity_conflict'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements(NEW.payload->'resolutions') r WHERE r->>'fact_id'=fact->>'fact_id' AND r->>'state'='confirmed') AND
    EXISTS(SELECT FROM jsonb_array_elements(previous->'source_facts') p WHERE p->>'fact_id'=fact->>'fact_id' AND p->'value' IS DISTINCT FROM fact->'value') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_resolution_stale'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER source_fact_version BEFORE INSERT ON preparation.item_versions FOR EACH ROW EXECUTE FUNCTION preparation.guard_source_fact_version();

CREATE FUNCTION preparation.save_items_initial(id uuid,changes jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb; change jsonb; i preparation.items;
 previous preparation.item_versions; ver uuid; op uuid; changed jsonb:='[]'; payload jsonb; locator jsonb; path text[];
BEGIN
 r:=preparation.replay(id,'save_items',changes,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF jsonb_typeof(changes) IS DISTINCT FROM 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 1000 OR
  EXISTS(SELECT FROM jsonb_array_elements(changes) c GROUP BY c->>'item_id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_item_changes'; END IF;
 INSERT INTO preparation.operations(workspace_id,actor_id,kind) VALUES(id,preparation.actor(),'edit') RETURNING operations.id INTO op;
 FOR change IN SELECT * FROM jsonb_array_elements(changes) LOOP
  PERFORM preparation.closed(change,ARRAY['item_id','expected_version','payload'],ARRAY['item_id','expected_version','payload']);
  SELECT * INTO i FROM preparation.items WHERE items.id=(change->>'item_id')::uuid AND workspace_id=id;
  IF i.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
  IF i.current_version_id IS DISTINCT FROM (change->>'expected_version')::uuid THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='item_version_conflict',DETAIL=i.id::text; END IF;
  payload:=change->'payload'; PERFORM preparation.validate_payload(id,payload);
  SELECT * INTO previous FROM preparation.item_versions WHERE item_versions.id=i.current_version_id;
  -- A retained quotation must not silently follow a changed manual value.
  FOR locator IN SELECT * FROM jsonb_array_elements(payload->'evidence') LOOP
   path:=string_to_array(substr(locator->>'path',2),'/');
   SELECT array_agg(replace(replace(part,'~1','/'),'~0','~') ORDER BY ord) INTO path
    FROM unnest(path) WITH ORDINALITY AS p(part,ord);
   IF locator->>'kind'<>'manual' AND NOT preparation.citation_unchanged(previous.payload,payload,locator) AND
    EXISTS(SELECT FROM jsonb_array_elements(previous.evidence) old WHERE old->>'id'=locator->>'id') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='citation_value_conflict';
   END IF;
  END LOOP;
  INSERT INTO preparation.item_versions(item_id,version_number,parent_id,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
   VALUES(i.id,previous.version_number+1,previous.id,previous.input_id,payload,payload->'evidence',payload->'field_origins',payload->>'outcome',preparation.actor(),op)
   RETURNING item_versions.id INTO ver;
  UPDATE preparation.items SET current_version_id=ver,trashed_at=CASE WHEN payload->>'outcome'='trash' THEN COALESCE(trashed_at,clock_timestamp()) ELSE NULL END WHERE items.id=i.id;
  changed:=changed||jsonb_build_array(jsonb_build_object('item_id',i.id,'before',previous.id,'after',ver));
 END LOOP;
 UPDATE preparation.operations SET changed_item_versions=changed WHERE operations.id=op;
 r:=jsonb_build_object('operation_id',op,'items',changed);
 RETURN preparation.receipt(id,'save_items',changes,key,r);
END $$;

REVOKE ALL ON FUNCTION preparation.validate_payload_v1(uuid,jsonb),preparation.validate_source_facts(uuid,jsonb),
 preparation.validate_payload(uuid,jsonb),preparation.citation_unchanged(jsonb,jsonb,jsonb),
 preparation.guard_source_fact_version(),preparation.save_items_initial(uuid,jsonb,uuid),
 preparation.save_items_initial_v1(uuid,jsonb,uuid) FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
COMMIT;
