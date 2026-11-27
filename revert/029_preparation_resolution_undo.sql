-- Revert egi_database:029_preparation_resolution_undo
-- Current payload grammar is unchanged; no history is removed.
BEGIN;
CREATE OR REPLACE FUNCTION preparation.stamp_reference_confirmation() RETURNS trigger
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
COMMIT;
