-- Revert egi_database:030_preparation_interpretations
BEGIN;
DROP TRIGGER interpretation_support ON editorial.community_snapshots;
DROP FUNCTION editorial.snapshot_interpretation_support();
DROP TRIGGER aa_interpretation_version ON preparation.item_versions;
DROP FUNCTION preparation.guard_interpretation_version();
DROP FUNCTION preparation.validate_payload(uuid,jsonb);
ALTER FUNCTION preparation.validate_payload_v2(uuid,jsonb) RENAME TO validate_payload;
DROP FUNCTION preparation.interpretation_basis(uuid,jsonb);
DROP TABLE preparation.interpretation_identities;
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
 IF NEW.payload->'schema_version'<>'2'::jsonb THEN RETURN NEW; END IF;
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
