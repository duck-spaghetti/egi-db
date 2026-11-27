-- Deploy egi_database:030_preparation_interpretations
-- requires: 029_preparation_resolution_undo
BEGIN;
ALTER FUNCTION preparation.validate_payload(uuid,jsonb) RENAME TO validate_payload_v2;

-- Identity and historical basis ownership are independent of mutable array order.
CREATE TABLE preparation.interpretation_identities (
 id uuid PRIMARY KEY,
 item_id uuid NOT NULL REFERENCES preparation.items ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('classification','hypothesis'))
);
REVOKE ALL ON preparation.interpretation_identities FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;

CREATE FUNCTION preparation.interpretation_basis(wid uuid,basis jsonb) RETURNS preparation.item_versions
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE v preparation.item_versions; pointer text[]; eid jsonb;
BEGIN
 PERFORM preparation.closed(basis,ARRAY['item_version','field_path','value_digest','evidence_ids'],ARRAY['item_version','field_path','value_digest','evidence_ids']);
 SELECT iv.* INTO v FROM preparation.item_versions iv JOIN preparation.items i ON i.id=iv.item_id
 WHERE iv.id=(basis->>'item_version')::uuid AND i.workspace_id=wid;
 IF v.id IS NULL OR jsonb_typeof(basis->'field_path') IS DISTINCT FROM 'string' OR
  basis->>'field_path' !~ '^/(service|source_facts)/' OR jsonb_typeof(basis->'evidence_ids') IS DISTINCT FROM 'array' OR
  jsonb_array_length(basis->'evidence_ids')=0 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_basis'; END IF;
 SELECT array_agg(replace(replace(p,'~1','/'),'~0','~') ORDER BY n) INTO pointer
 FROM unnest(string_to_array(substr(basis->>'field_path',2),'/')) WITH ORDINALITY t(p,n);
 IF v.payload#>pointer IS NULL OR basis->>'value_digest' IS DISTINCT FROM preparation.digest(v.payload#>pointer) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_digest_mismatch'; END IF;
 FOR eid IN SELECT * FROM jsonb_array_elements(basis->'evidence_ids') LOOP
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(v.evidence) e WHERE e->>'id'=eid#>>'{}' AND e->>'path'=basis->>'field_path' AND e->>'kind' IN ('stated','interpreted') AND e ? 'span') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_evidence_required'; END IF;
 END LOOP;
 RETURN v;
END $$;

CREATE FUNCTION preparation.validate_payload(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb; c jsonb; h jsonb; v preparation.item_versions; eid jsonb;
BEGIN
 IF payload->'schema_version' IS DISTINCT FROM '3'::jsonb THEN
  PERFORM preparation.validate_payload_v2(wid,payload); RETURN; END IF;
 PERFORM preparation.closed(payload,ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions','interpreted_classifications','interpretation_hypotheses'],
 ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions','interpreted_classifications','interpretation_hypotheses']);
 PERFORM preparation.validate_payload_v2(wid,(payload-'interpreted_classifications'-'interpretation_hypotheses')||'{"schema_version":2}');
 IF jsonb_typeof(payload->'interpreted_classifications') IS DISTINCT FROM 'array' OR jsonb_typeof(payload->'interpretation_hypotheses') IS DISTINCT FROM 'array' OR
  jsonb_array_length(payload->'interpreted_classifications')>1000 OR jsonb_array_length(payload->'interpretation_hypotheses')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretations'; END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(payload->'interpreted_classifications') LOOP
  PERFORM preparation.closed(r,ARRAY['interpretation_id','basis','context','candidates','state','selected','method','job_id'],ARRAY['interpretation_id','basis','context','candidates','state','selected','method','job_id']);
  PERFORM (r->>'interpretation_id')::uuid;
  v:=preparation.interpretation_basis(wid,r->'basis');
  PERFORM preparation.closed(r->'context',ARRAY['territory_id','axis_id','catalog_digest','as_of'],ARRAY['territory_id','axis_id','catalog_digest','as_of']);
  IF r->>'state' NOT IN ('proposed','confirmed','rejected','stale') OR r->>'method' NOT IN ('ai','manual') OR
   r->>'state' IS NULL OR r->>'method' IS NULL OR jsonb_typeof(r->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(r->'candidates')>5 OR
   (r->>'method'='manual' AND r->'job_id'<>'null'::jsonb) OR (r->>'method'='ai' AND NOT EXISTS(SELECT FROM preparation.jobs WHERE id=(r->>'job_id')::uuid AND workspace_id=wid)) OR
   jsonb_typeof(r#>'{context,territory_id}') IS DISTINCT FROM 'string' OR jsonb_typeof(r#>'{context,axis_id}') IS DISTINCT FROM 'string' OR
   jsonb_typeof(r#>'{context,catalog_digest}') IS DISTINCT FROM 'string' OR COALESCE(r#>>'{context,catalog_digest}','') !~ '^[0-9a-f]{64}$' OR
   jsonb_typeof(r#>'{context,as_of}') IS DISTINCT FROM 'string' OR (r#>>'{context,as_of}')::date IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpreted_classification'; END IF;
  PERFORM (r#>>'{context,territory_id}')::uuid; PERFORM (r#>>'{context,axis_id}')::uuid;
  FOR c IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP
   PERFORM preparation.closed(c,ARRAY['target','reason','support_evidence_ids'],ARRAY['target','reason','support_evidence_ids']);
   IF jsonb_typeof(c->'reason') IS DISTINCT FROM 'string' OR length(btrim(c->>'reason')) NOT BETWEEN 1 AND 4000 OR jsonb_typeof(c->'support_evidence_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(c->'support_evidence_ids')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_candidate'; END IF;
   FOR eid IN SELECT * FROM jsonb_array_elements(c->'support_evidence_ids') LOOP
    IF NOT (r#>'{basis,evidence_ids}') @> jsonb_build_array(eid) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_interpretation_support'; END IF;
   END LOOP;
   PERFORM preparation.closed(c->'target',ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  END LOOP;
  IF r->>'state'='confirmed' THEN
   PERFORM preparation.closed(r->'selected',ARRAY['target','actor_id','confirmed_at'],ARRAY['target','actor_id','confirmed_at']);
   PERFORM preparation.closed(r#>'{selected,target}',ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  ELSIF r->'selected'<>'null'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unconfirmed_interpretation_selection'; END IF;
 END LOOP;
 FOR h IN SELECT * FROM jsonb_array_elements(payload->'interpretation_hypotheses') LOOP
  PERFORM preparation.closed(h,ARRAY['hypothesis_id','kind','statement','state','basis','trigger_evidence_ids','job_id','verification'],ARRAY['hypothesis_id','kind','statement','state','basis','trigger_evidence_ids','job_id','verification']);
  PERFORM (h->>'hypothesis_id')::uuid; v:=preparation.interpretation_basis(wid,h->'basis');
  IF h->>'kind' IS DISTINCT FROM 'abbreviation_expansion' OR h->>'state' IS NULL OR h->>'state' NOT IN ('unverified','verified','rejected','stale') OR
   jsonb_typeof(h->'statement') IS DISTINCT FROM 'string' OR length(btrim(h->>'statement')) NOT BETWEEN 1 AND 4000 OR
   jsonb_typeof(h->'trigger_evidence_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(h->'trigger_evidence_ids')=0 OR
   NOT (h#>'{basis,evidence_ids}') @> (h->'trigger_evidence_ids') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_hypothesis'; END IF;
  IF h->'job_id'<>'null'::jsonb AND NOT EXISTS(SELECT FROM preparation.jobs WHERE id=(h->>'job_id')::uuid AND workspace_id=wid) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_hypothesis_job'; END IF;
  IF h->>'state'='verified' THEN
   PERFORM preparation.closed(h->'verification',ARRAY['actor_id','verified_at','decision_id','evidence_ids'],ARRAY['actor_id','verified_at','decision_id','evidence_ids']);
   IF jsonb_typeof(h#>'{verification,evidence_ids}') IS DISTINCT FROM 'array' OR jsonb_array_length(h#>'{verification,evidence_ids}')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hypothesis_verification_support_required'; END IF;
   FOR eid IN SELECT * FROM jsonb_array_elements(h#>'{verification,evidence_ids}') LOOP
    IF (h->'trigger_evidence_ids') @> jsonb_build_array(eid) OR NOT EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') e WHERE e->>'id'=eid#>>'{}') THEN
     RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hypothesis_trigger_is_not_verification'; END IF;
   END LOOP;
  ELSIF h->'verification'<>'null'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unverified_hypothesis_verification'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(payload->'interpreted_classifications') x GROUP BY x->>'interpretation_id' HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(payload->'interpretation_hypotheses') x GROUP BY x->>'hypothesis_id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_interpretation_id'; END IF;
END $$;

CREATE FUNCTION preparation.guard_interpretation_version() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE wid uuid; previous jsonb; base uuid; r jsonb; old jsonb; a jsonb; result jsonb; field text; idfield text; v preparation.item_versions; pointer text[]; identity preparation.interpretation_identities; undoing boolean; stale boolean;
BEGIN
 SELECT i.workspace_id,i.current_version_id,p.payload INTO wid,base,previous FROM preparation.items i LEFT JOIN preparation.item_versions p ON p.id=i.current_version_id WHERE i.id=NEW.item_id;
 SELECT kind='undo' INTO undoing FROM preparation.operations WHERE id=NEW.operation_id;
 IF previous->'schema_version'='3'::jsonb AND NEW.payload->'schema_version'<>'3'::jsonb THEN
  IF undoing THEN NEW.payload:=NEW.payload||'{"schema_version":3,"interpreted_classifications":[],"interpretation_hypotheses":[]}';
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='item_schema_downgrade'; END IF;
 END IF;
 IF NEW.payload->'schema_version'<>'3'::jsonb THEN RETURN NEW; END IF;
 FOREACH field IN ARRAY ARRAY['interpreted_classifications','interpretation_hypotheses'] LOOP
  result:='[]'; idfield:=CASE field WHEN 'interpreted_classifications' THEN 'interpretation_id' ELSE 'hypothesis_id' END;
  FOR r IN SELECT * FROM jsonb_array_elements(NEW.payload->field) LOOP
   v:=preparation.interpretation_basis(wid,r->'basis');
   IF v.item_id<>NEW.item_id THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_item_mismatch'; END IF;
   INSERT INTO preparation.interpretation_identities VALUES((r->>idfield)::uuid,NEW.item_id,CASE field WHEN 'interpreted_classifications' THEN 'classification' ELSE 'hypothesis' END) ON CONFLICT DO NOTHING;
   SELECT * INTO identity FROM preparation.interpretation_identities WHERE id=(r->>idfield)::uuid;
   IF identity.item_id<>NEW.item_id OR identity.kind<>(CASE field WHEN 'interpreted_classifications' THEN 'classification' ELSE 'hypothesis' END) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_identity_conflict'; END IF;
   SELECT x INTO old FROM jsonb_array_elements(COALESCE(previous->field,'[]')) x WHERE x->>idfield=r->>idfield;
   SELECT array_agg(replace(replace(p,'~1','/'),'~0','~') ORDER BY n) INTO pointer FROM unnest(string_to_array(substr(r#>>'{basis,field_path}',2),'/')) WITH ORDINALITY t(p,n);
   stale:=NEW.payload#>pointer IS DISTINCT FROM v.payload#>pointer OR NEW.payload#>>ARRAY['field_origins',r#>>'{basis,field_path}','state'] IN ('manual','cleared');
   IF field='interpreted_classifications' AND r->>'state' IN ('proposed','confirmed') THEN
    BEGIN
     FOR a IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',(r->'context')-'catalog_digest'-'as_of',a->'target'); END LOOP;
     IF r->>'state'='confirmed' THEN PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',(r->'context')-'catalog_digest'-'as_of',r#>'{selected,target}'); END IF;
    EXCEPTION WHEN serialization_failure OR invalid_parameter_value THEN stale:=true; END;
   END IF;
   IF stale THEN r:=r||jsonb_build_object('state','stale',CASE field WHEN 'interpreted_classifications' THEN 'selected' ELSE 'verification' END,NULL);
   ELSIF field='interpreted_classifications' AND r->>'state'='confirmed' AND old->>'state'='confirmed' AND old->'selected'=r->'selected' AND (old->'basis' IS DISTINCT FROM r->'basis' OR old->'context' IS DISTINCT FROM r->'context') THEN
    r:=r||jsonb_build_object('state','proposed','selected',NULL);
   ELSIF field='interpreted_classifications' AND r->>'state'='confirmed' THEN
    IF old->>'state'='confirmed' AND old->'selected'=r->'selected' AND old->'basis'=r->'basis' AND old->'context'=r->'context' THEN r:=jsonb_set(r,'{selected}',old->'selected');
    ELSE r:=jsonb_set(r,'{selected}',jsonb_build_object('target',r#>'{selected,target}','actor_id',preparation.actor(),'confirmed_at',clock_timestamp())); END IF;
    a:=jsonb_build_object('adoption_id',r#>'{selected,target,adoption_id}','term_id',r#>'{selected,target,term_id}');
    IF NOT COALESCE(NEW.payload#>'{service,classifications}','[]') @> jsonb_build_array(a) THEN
     NEW.payload:=jsonb_set(NEW.payload,'{service}',(NEW.payload->'service')||jsonb_build_object('classifications',COALESCE(NEW.payload#>'{service,classifications}','[]')||jsonb_build_array(a))); END IF;
   ELSIF field='interpretation_hypotheses' AND r->>'state'='verified' AND old->>'state'='verified' AND old->'verification'=r->'verification' AND (old-'verification'-'state') IS DISTINCT FROM (r-'verification'-'state') THEN
    r:=r||jsonb_build_object('state','unverified','verification',NULL);
   ELSIF field='interpretation_hypotheses' AND r->>'state'='verified' AND (old->>'state' IS DISTINCT FROM 'verified' OR old->'verification' IS DISTINCT FROM r->'verification') THEN
    r:=jsonb_set(r,'{verification}',(r->'verification')||jsonb_build_object('actor_id',preparation.actor(),'verified_at',clock_timestamp(),'decision_id',gen_random_uuid()));
   END IF;
   result:=result||jsonb_build_array(r);
  END LOOP;
  NEW.payload:=jsonb_set(NEW.payload,ARRAY[field],result);
 END LOOP;
 PERFORM preparation.validate_payload(wid,NEW.payload);
 NEW.evidence:=NEW.payload->'evidence'; NEW.field_origins:=NEW.payload->'field_origins';
 RETURN NEW;
END $$;
CREATE TRIGGER aa_interpretation_version BEFORE INSERT ON preparation.item_versions FOR EACH ROW EXECUTE FUNCTION preparation.guard_interpretation_version();

-- Copy only the selected card's anchored quotes, never its full source input or
-- another card. This survives later private retention purge and basis edits.
CREATE FUNCTION editorial.snapshot_interpretation_support() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb; v preparation.item_versions; supports jsonb:='[]'; quotes jsonb;
BEGIN
 IF NEW.values->'schema_version'<>'3'::jsonb THEN RETURN NEW; END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(NEW.values->'interpreted_classifications') UNION ALL SELECT * FROM jsonb_array_elements(NEW.values->'interpretation_hypotheses') LOOP
  v:=preparation.interpretation_basis(NEW.preparation_id,r->'basis');
  IF v.item_id<>NEW.item_id THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_item_mismatch'; END IF;
  SELECT COALESCE(jsonb_agg(e),'[]') INTO quotes FROM jsonb_array_elements(v.evidence) e WHERE (r#>'{basis,evidence_ids}') @> jsonb_build_array(e->'id');
  supports:=supports||jsonb_build_array(jsonb_build_object('basis',r->'basis','evidence',quotes));
 END LOOP;
 NEW.values:=NEW.values||jsonb_build_object('interpretation_support',supports);
 RETURN NEW;
END $$;
CREATE TRIGGER interpretation_support BEFORE INSERT ON editorial.community_snapshots FOR EACH ROW EXECUTE FUNCTION editorial.snapshot_interpretation_support();
REVOKE ALL ON FUNCTION preparation.interpretation_basis(uuid,jsonb),preparation.validate_payload_v2(uuid,jsonb),preparation.validate_payload(uuid,jsonb),preparation.guard_interpretation_version(),editorial.snapshot_interpretation_support() FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
CREATE OR REPLACE FUNCTION preparation.guard_source_fact_version() RETURNS trigger
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
 IF NEW.payload->'schema_version' IN ('2'::jsonb,'3'::jsonb) THEN
  PERFORM preparation.validate_payload(wid,NEW.payload);
  FOR fact,idx IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(NEW.payload->'source_facts') WITH ORDINALITY LOOP
   SELECT (e->>'input_id')::uuid INTO evidence_input FROM jsonb_array_elements(NEW.payload->'evidence') e
    WHERE e->>'path'='/source_facts/'||idx||'/source_value' LIMIT 1;
   INSERT INTO preparation.fact_identities(fact_id,item_id,input_id,subject,kind,source_value)
    VALUES((fact->>'fact_id')::uuid,NEW.item_id,evidence_input,fact->>'subject',fact->>'kind',fact->>'source_value') ON CONFLICT DO NOTHING;
   SELECT * INTO identity FROM preparation.fact_identities WHERE fact_id=(fact->>'fact_id')::uuid;
   IF identity.item_id<>NEW.item_id OR identity.subject<>fact->>'subject' OR identity.kind<>fact->>'kind' OR identity.source_value<>fact->>'source_value' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_identity_conflict'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements(NEW.payload->'resolutions') r WHERE r->>'fact_id'=fact->>'fact_id' AND r->>'state' IN ('confirmed','proposed')) AND
    EXISTS(SELECT FROM jsonb_array_elements(previous->'source_facts') p WHERE p->>'fact_id'=fact->>'fact_id' AND p->'value' IS DISTINCT FROM fact->'value') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_resolution_stale'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION preparation.stamp_reference_confirmation() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE previous jsonb; base uuid; r jsonb; old jsonb; f jsonb; result jsonb:='[]'; binding jsonb; old_fact jsonb; candidate jsonb; undoing boolean; stale boolean;
BEGIN
 IF NEW.payload->'schema_version' NOT IN ('2'::jsonb,'3'::jsonb) THEN RETURN NEW; END IF;
 SELECT i.current_version_id,v.payload INTO base,previous FROM preparation.items i LEFT JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.id=NEW.item_id;
 SELECT kind='undo' INTO undoing FROM preparation.operations WHERE id=NEW.operation_id;
 FOR r IN SELECT * FROM jsonb_array_elements(NEW.payload->'resolutions') LOOP
  SELECT x INTO f FROM jsonb_array_elements(NEW.payload->'source_facts') x WHERE x->>'fact_id'=r->>'fact_id';
  IF undoing AND r->>'state' IN ('confirmed','proposed') THEN
   SELECT x INTO old_fact FROM jsonb_array_elements(COALESCE(previous->'source_facts','[]')) x WHERE x->>'fact_id'=r->>'fact_id';
   stale:=old_fact->'value' IS DISTINCT FROM f->'value';
   IF NOT stale THEN
    BEGIN
     IF r->>'state'='confirmed' THEN PERFORM preparation.validate_reference(f,r->'context',r#>'{selected,target}'); END IF;
     FOR candidate IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP
      PERFORM preparation.validate_reference(f,r->'context',candidate->'target');
     END LOOP;
    EXCEPTION WHEN serialization_failure OR invalid_parameter_value OR insufficient_privilege THEN stale:=true;
    END;
   END IF;
   IF stale THEN r:=jsonb_build_object('fact_id',r->'fact_id','state','unresolved','context','{}'::jsonb,'candidates','[]'::jsonb); END IF;
  END IF;
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
COMMIT;
