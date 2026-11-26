-- Deploy egi_database:021_community_component_evidence
-- requires: 020_community_acceptance
BEGIN;
-- Compare stable canonical components at their new collection positions. A removed
-- sibling never turns an unchanged component into a newly sourced assertion.
CREATE FUNCTION editorial.community_align_baseline(old_body jsonb,new_body jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; k text; v jsonb; prior jsonb;
BEGIN
 IF jsonb_typeof(new_body)='object' THEN
  result:=CASE WHEN jsonb_typeof(old_body)='object' THEN old_body ELSE '{}' END;
  FOR k,v IN SELECT * FROM jsonb_each(new_body) LOOP
   IF result ? k THEN result:=jsonb_set(result,ARRAY[k],editorial.community_align_baseline(old_body->k,v),true); END IF;
  END LOOP;
  RETURN result;
 ELSIF jsonb_typeof(new_body)='array' THEN
  result:='[]';
  FOR v IN SELECT * FROM jsonb_array_elements(new_body) LOOP
   prior:=NULL;
   SELECT item INTO prior FROM jsonb_array_elements(CASE WHEN jsonb_typeof(old_body)='array' THEN old_body ELSE '[]' END) item
   WHERE CASE WHEN v ? 'component_id' THEN item->>'component_id'=v->>'component_id'
    WHEN v ? 'weekday' THEN item->'weekday'=v->'weekday'
    ELSE editorial.community_without_evidence(item)=editorial.community_without_evidence(v) END LIMIT 1;
   result:=result||jsonb_build_array(CASE WHEN prior IS NULL THEN NULL ELSE editorial.community_align_baseline(prior,v) END);
  END LOOP;
  RETURN result;
 END IF;
 RETURN old_body;
END $$;
ALTER FUNCTION editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text)
 RENAME TO bind_community_body_unaligned;
CREATE FUNCTION editorial.bind_community_body(s editorial.community_snapshots,old_body jsonb,new_body jsonb,prefix text[],
 selected uuid[],observations jsonb,reason text) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
 SELECT editorial.bind_community_body_unaligned(s,editorial.community_align_baseline(old_body,new_body),new_body,prefix,selected,observations,reason)
$$;
REVOKE ALL ON FUNCTION editorial.community_align_baseline(jsonb,jsonb),
 editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.read_community_snapshot(contribution uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=preparation.actor(); s editorial.community_snapshots; resolution jsonb;
BEGIN
 SELECT * INTO s FROM editorial.community_snapshots WHERE contribution_id=contribution;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 SELECT to_jsonb(r) INTO resolution FROM editorial.community_resolutions r WHERE r.contribution_id=contribution;
 RETURN jsonb_build_object('snapshot',to_jsonb(s),'diagnostics',editorial.community_diagnostics(s.values,s.evidence),
  'resolved_service_id',editorial.community_identity(s.contribution_id),'resolution',resolution);
END $$;
COMMIT;
