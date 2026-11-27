-- Deploy egi_database:018_preparation_candidates
-- requires: 017_preparation_jobs
-- Complete the job-to-card provider contract: explicit, idempotent selection and
-- field-origin-aware updates; no canonical identity may be selected by a provider.
BEGIN;
ALTER TABLE preparation.jobs ADD CONSTRAINT jobs_workspace_identity UNIQUE(id,workspace_id);
CREATE TABLE preparation.candidate_applications (
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 job_id uuid NOT NULL,
 candidate_id uuid NOT NULL,
 item_id uuid NOT NULL,
 applied_version_id uuid NOT NULL,
 was_new boolean NOT NULL,
 conflicts jsonb NOT NULL,
 PRIMARY KEY(workspace_id,job_id,candidate_id),
 FOREIGN KEY(job_id,workspace_id) REFERENCES preparation.jobs(id,workspace_id)
);
-- Item/version IDs intentionally become opaque receipts after private item purge.
-- Every live association is checked by create_items while holding its workspace.
CREATE FUNCTION preparation.component_ids(value jsonb,kind text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; k text; v jsonb; child jsonb;
BEGIN
 IF jsonb_typeof(value)='array' THEN
  result:='[]'; FOR child IN SELECT * FROM jsonb_array_elements(value) LOOP
   result:=result||jsonb_build_array(preparation.component_ids(child,kind)); END LOOP;
  RETURN result;
 ELSIF jsonb_typeof(value)='object' THEN
  result:='{}'; FOR k,v IN SELECT * FROM jsonb_each(value) LOOP result:=result||jsonb_build_object(k,preparation.component_ids(v,k)); END LOOP;
  IF kind IN ('contacts','addresses','organizations','conditions','contact_links','coverage','schedules','intervals','effects','place') THEN
   result:=result||jsonb_build_object('component_id',gen_random_uuid()); END IF;
  RETURN result;
 END IF;
 RETURN value;
END $$;
CREATE FUNCTION preparation.merge_candidate(old jsonb,candidate jsonb,input uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE payload jsonb:=old; origins jsonb:=old->'field_origins'; evidence jsonb:='[]'; conflicts jsonb:='[]'; applied text[]:=ARRAY[]::text[];
 k text; v jsonb; prefix text; zone text; body jsonb; old_origins jsonb; e jsonb; p text;
BEGIN
 FOR zone IN SELECT unnest(ARRAY['service','location']) LOOP
  IF zone='location' THEN
   IF candidate#>>'{location,kind}'<>'new' THEN CONTINUE; END IF;
   IF old#>>'{location,kind}'='existing' THEN
    conflicts:=conflicts||jsonb_build_array('/location'); CONTINUE; END IF;
   body:=candidate#>'{location,body}'; prefix:='/location/body/';
   IF payload#>>'{location,kind}'='none' THEN payload:=jsonb_set(payload,'{location}','{"kind":"new","body":{}}'); END IF;
  ELSE body:=candidate->'service'; prefix:='/service/'; END IF;
  FOR k,v IN SELECT * FROM jsonb_each(body) LOOP
   p:=prefix||replace(replace(k,'~','~0'),'/','~1');
   IF EXISTS(SELECT FROM jsonb_each(origins) f WHERE (f.key=p OR starts_with(f.key,p||'/') OR starts_with(p,f.key||'/'))
    AND f.value->>'state' IN ('manual','cleared')) THEN
    conflicts:=conflicts||jsonb_build_array(p); CONTINUE; END IF;
   IF zone='service' THEN payload:=jsonb_set(payload,ARRAY['service',k],preparation.component_ids(v,k));
   ELSE payload:=jsonb_set(payload,ARRAY['location','body',k],preparation.component_ids(v,k)); END IF;
   SELECT COALESCE(jsonb_object_agg(f.key,f.value),'{}') INTO old_origins FROM jsonb_each(origins) f
    WHERE f.key<>p AND NOT starts_with(f.key,p||'/');
   origins:=old_origins||jsonb_build_object(p,jsonb_build_object('state','generated','input_id',input,'job_id',job));
   applied:=array_append(applied,p);
  END LOOP;
 END LOOP;
 FOR e IN SELECT * FROM jsonb_array_elements(old->'evidence') LOOP
  IF NOT EXISTS(SELECT FROM unnest(applied) a(path) WHERE e->>'path'=a.path OR starts_with(e->>'path',a.path||'/')) THEN
   evidence:=evidence||jsonb_build_array(e); END IF;
 END LOOP;
 FOR e IN SELECT * FROM jsonb_array_elements(candidate->'evidence') LOOP
  IF EXISTS(SELECT FROM unnest(applied) a(path) WHERE e->>'path'=a.path OR starts_with(e->>'path',a.path||'/')) THEN
   evidence:=evidence||jsonb_build_array(e); END IF;
 END LOOP;
 RETURN jsonb_build_object('payload',payload||jsonb_build_object('field_origins',origins,'evidence',evidence),'conflicts',conflicts);
END $$;

ALTER FUNCTION preparation.create_items(uuid,uuid,uuid,jsonb,uuid) RENAME TO create_manual_item;
REVOKE EXECUTE ON FUNCTION preparation.create_manual_item(uuid,uuid,uuid,jsonb,uuid) FROM egi_editorial;
CREATE FUNCTION preparation.create_items(id uuid,input uuid,job uuid,selections jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); j preparation.jobs; r jsonb; eligible jsonb; selection jsonb;
 candidate_key text; candidate jsonb; cid uuid; target uuid; i preparation.items; previous preparation.item_versions;
 applied preparation.candidate_applications; payload jsonb; merged jsonb; op uuid; ver uuid; changes jsonb:='[]'; results jsonb:='[]';
 body jsonb:=jsonb_build_object('input',input,'job',job,'selections',selections);
BEGIN
 IF job IS NULL THEN RETURN preparation.create_manual_item(id,input,job,selections,key); END IF;
 r:=preparation.replay(id,'create_items',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF input IS NULL OR input IS DISTINCT FROM w.current_input_id THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='input_conflict'; END IF;
 SELECT * INTO j FROM preparation.jobs WHERE jobs.id=job AND workspace_id=id AND input_id=input;
 IF j.id IS NULL OR j.state<>'succeeded' OR j.cancelled_at IS NOT NULL THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='candidate_job_not_available'; END IF;
 eligible:=preparation.eligible_input(id,input);
 IF eligible-'locator_map' IS DISTINCT FROM j.eligible_payload OR eligible->'locator_map' IS DISTINCT FROM j.locator_map THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='eligibility_changed'; END IF;
 IF jsonb_typeof(selections) IS DISTINCT FROM 'array' OR jsonb_array_length(selections) NOT BETWEEN 1 AND 1000 OR
  EXISTS(SELECT FROM jsonb_array_elements(selections) s GROUP BY s->>'candidate_id' HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(selections) s WHERE s ? 'target_item_id' GROUP BY s->>'target_item_id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_candidate_selection'; END IF;
 INSERT INTO preparation.operations(workspace_id,actor_id,kind) VALUES(id,preparation.actor(),'edit') RETURNING operations.id INTO op;
 FOR selection IN SELECT * FROM jsonb_array_elements(selections) LOOP
  PERFORM preparation.closed(selection,ARRAY['candidate_id','target_item_id','expected_version'],ARRAY['candidate_id']);
  cid:=(selection->>'candidate_id')::uuid; target:=(selection->>'target_item_id')::uuid;
  SELECT e.key INTO candidate_key FROM jsonb_each_text(j.candidate_ids) e WHERE e.value=cid::text;
  IF candidate_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='candidate_not_found'; END IF;
  SELECT * INTO applied FROM preparation.candidate_applications a WHERE a.workspace_id=id AND a.job_id=job AND a.candidate_id=cid;
  IF FOUND THEN
   IF (target IS NOT NULL AND target<>applied.item_id) OR (target IS NULL AND NOT applied.was_new) THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='candidate_already_applied'; END IF;
   results:=results||jsonb_build_array(jsonb_build_object('item_id',applied.item_id,'version_id',applied.applied_version_id,
    'candidate_id',cid,'already_applied',true,'conflicts',applied.conflicts)); CONTINUE;
  END IF;
  SELECT c INTO candidate FROM jsonb_array_elements(j.output->'candidates') c WHERE c->>'candidate_key'=candidate_key;
  IF target IS NULL THEN
   IF selection ? 'expected_version' OR selection ? 'target_item_id' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_candidate_target'; END IF;
   INSERT INTO preparation.items(workspace_id,origin_input_id,origin_locator)
    VALUES(id,input,jsonb_build_object('job_id',job,'candidate_id',cid)) RETURNING * INTO i;
   previous:=NULL;
   payload:='{"schema_version":1,"service":{},"location":{"kind":"none"},"target":{"kind":"new"},"field_origins":{},"evidence":[],"outcome":"review"}';
  ELSE
   IF NOT selection ? 'expected_version' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='expected_version_required'; END IF;
   SELECT * INTO i FROM preparation.items WHERE items.id=target AND workspace_id=id;
   IF i.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
   IF i.current_version_id IS DISTINCT FROM (selection->>'expected_version')::uuid THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='item_version_conflict'; END IF;
   IF i.trashed_at<=clock_timestamp()-interval '30 days' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='item_restore_expired'; END IF;
   SELECT * INTO previous FROM preparation.item_versions WHERE item_versions.id=i.current_version_id;
   payload:=previous.payload;
  END IF;
  merged:=preparation.merge_candidate(payload,candidate,input,job); payload:=merged->'payload';
  PERFORM preparation.validate_payload(id,payload);
  INSERT INTO preparation.item_versions(item_id,version_number,parent_id,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
   VALUES(i.id,COALESCE(previous.version_number,0)+1,previous.id,input,payload,payload->'evidence',payload->'field_origins',payload->>'outcome',preparation.actor(),op)
   RETURNING item_versions.id INTO ver;
  UPDATE preparation.items SET current_version_id=ver WHERE items.id=i.id;
  INSERT INTO preparation.candidate_applications VALUES(id,job,cid,i.id,ver,target IS NULL,merged->'conflicts');
  changes:=changes||jsonb_build_array(jsonb_build_object('item_id',i.id,'before',previous.id,'after',ver));
  results:=results||jsonb_build_array(jsonb_build_object('item_id',i.id,'version_id',ver,'candidate_id',cid,
   'already_applied',false,'conflicts',merged->'conflicts'));
 END LOOP;
 IF jsonb_array_length(changes)=0 THEN DELETE FROM preparation.operations WHERE operations.id=op;
 ELSE UPDATE preparation.operations SET changed_item_versions=changes WHERE operations.id=op; END IF;
 r:=jsonb_build_object('items',results);
 RETURN preparation.receipt(id,'create_items',body,key,r);
END $$;
REVOKE ALL ON TABLE preparation.candidate_applications FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
REVOKE ALL ON FUNCTION preparation.component_ids(jsonb,text),preparation.merge_candidate(jsonb,jsonb,uuid,uuid),preparation.create_items(uuid,uuid,uuid,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.create_items(uuid,uuid,uuid,jsonb,uuid) TO egi_editorial;
COMMIT;
