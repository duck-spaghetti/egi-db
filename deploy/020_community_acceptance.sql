-- Deploy egi_database:020_community_acceptance
-- requires: 019_community_submissions
-- EGI-106: selective canonical evidence, stable service identity and guarded acceptance.
BEGIN;
CREATE TABLE editorial.community_resolutions (
 contribution_id uuid PRIMARY KEY REFERENCES editorial.community_snapshots,
 service_id uuid NOT NULL REFERENCES data.services,
 initial_revision_id uuid NOT NULL,
 accepted_by uuid NOT NULL REFERENCES governance.actors,
 accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 request_key uuid NOT NULL,
 decision_digest text NOT NULL,
 FOREIGN KEY(initial_revision_id,service_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE TABLE editorial.community_evidence (
 contribution_id uuid NOT NULL REFERENCES editorial.community_snapshots,
 assertion_id uuid NOT NULL REFERENCES sources.assertions,
 field_path text NOT NULL,
 locator_id uuid,
 source_id uuid NOT NULL REFERENCES sources.registry,
 PRIMARY KEY(contribution_id,assertion_id), UNIQUE(contribution_id,locator_id)
);
CREATE FUNCTION editorial.community_resolution_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE item uuid;
BEGIN
 PERFORM governance.lock_operation();
 SELECT item_id INTO STRICT item FROM editorial.community_snapshots WHERE contribution_id=NEW.contribution_id;
 PERFORM pg_advisory_xact_lock(hashtextextended('community-item:'||item::text,0));
 IF EXISTS(SELECT FROM editorial.community_resolutions r JOIN editorial.community_snapshots s USING(contribution_id)
  WHERE s.item_id=item AND r.service_id<>NEW.service_id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='community_item_identity_conflict'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER resolution_identity BEFORE INSERT ON editorial.community_resolutions
 FOR EACH ROW EXECUTE FUNCTION editorial.community_resolution_guard();
CREATE TRIGGER resolutions_immutable BEFORE UPDATE OR DELETE ON editorial.community_resolutions
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE FUNCTION editorial.community_evidence_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE actual uuid;
BEGIN
 SELECT d.source_id INTO actual FROM sources.assertions a JOIN sources.normalized_subjects n USING(subject_id)
 JOIN sources.record_versions v USING(record_version_id) JOIN sources.records r USING(record_id)
 JOIN sources.datasets d ON d.dataset_id=v.dataset_id AND d.dataset_id=r.dataset_id WHERE a.assertion_id=NEW.assertion_id;
 IF actual IS DISTINCT FROM NEW.source_id THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='community_assertion_source_mismatch'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER evidence_source BEFORE INSERT ON editorial.community_evidence
 FOR EACH ROW EXECUTE FUNCTION editorial.community_evidence_guard();
CREATE TRIGGER evidence_immutable BEFORE UPDATE OR DELETE ON editorial.community_evidence
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE OR REPLACE FUNCTION editorial.community_identity(parent uuid) RETURNS uuid
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT r.service_id FROM editorial.community_snapshots s JOIN editorial.community_resolutions r USING(contribution_id)
 WHERE s.item_id=(SELECT item_id FROM editorial.community_snapshots WHERE contribution_id=parent)
 ORDER BY r.accepted_at,r.contribution_id LIMIT 1
$$;

-- Decode only the closed aggregate's RFC6901 paths; evidence and identifiers are
-- not editable scalar slots. IDs inside selected component values retain ownership.
CREATE FUNCTION editorial.community_path(path text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE parts text[]; part text; result text[]:=ARRAY[]::text[];
BEGIN
 IF path IS NULL OR path !~ '^/' OR length(path)>1000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_acceptance_path'; END IF;
 parts:=string_to_array(substr(path,2),'/');
 FOREACH part IN ARRAY parts LOOP
  IF part='' OR part ~ '~([^01]|$)' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_acceptance_path'; END IF;
  part:=replace(replace(part,'~1','/'),'~0','~');
  IF part IN ('evidence','component_id') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='protected_acceptance_path'; END IF;
  result:=array_append(result,part);
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION editorial.community_patch(body jsonb,operation jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE parts text[]:=editorial.community_path(operation->>'path'); parent text[]; owner jsonb; actual text[]:=parts;
 index_value integer; exists_value boolean; result jsonb; op text:=operation->>'op';
BEGIN
 PERFORM preparation.closed(operation,ARRAY['op','path','value','evidence_ids'],ARRAY['op','path','evidence_ids']);
 IF jsonb_typeof(operation->'op') IS DISTINCT FROM 'string' OR op NOT IN ('add','replace','remove') OR (op='remove' AND operation ? 'value') OR (op<>'remove' AND NOT operation ? 'value') OR
  jsonb_typeof(operation->'evidence_ids') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_acceptance_operation'; END IF;
 IF op<>'remove' AND EXISTS(SELECT FROM jsonb_path_query(operation->'value','$.** ? (@.type() == "object").keyvalue()') k WHERE k->>'key'='evidence') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='canonical_evidence_not_accepted'; END IF;
 parent:=parts[1:cardinality(parts)-1];
 owner:=CASE WHEN cardinality(parent)=0 THEN body ELSE body#>parent END;
 IF jsonb_typeof(owner)='array' THEN
  IF parts[cardinality(parts)]='-' AND op='add' THEN index_value:=jsonb_array_length(owner);
  ELSIF parts[cardinality(parts)] ~ '^(0|[1-9][0-9]*)$' THEN index_value:=parts[cardinality(parts)]::integer;
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_acceptance_index'; END IF;
  IF index_value>jsonb_array_length(owner) OR (op<>'add' AND index_value>=jsonb_array_length(owner)) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='acceptance_path_not_found'; END IF;
  actual:=parent||index_value::text;
  IF op='add' THEN
   IF index_value=jsonb_array_length(owner) THEN
    IF cardinality(parent)=0 THEN result:=body||jsonb_build_array(operation->'value');
    ELSE result:=jsonb_set(body,parent,owner||jsonb_build_array(operation->'value')); END IF;
   ELSE result:=jsonb_insert(body,actual,operation->'value'); END IF;
  ELSIF op='replace' THEN result:=jsonb_set(body,actual,operation->'value');
  ELSE result:=body#-actual; END IF;
 ELSIF jsonb_typeof(owner)='object' THEN
  exists_value:=owner ? parts[cardinality(parts)];
  IF op IN ('replace','remove') AND NOT exists_value THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='acceptance_path_not_found'; END IF;
  result:=CASE WHEN op='remove' THEN body#-parts ELSE jsonb_set(body,parts,operation->'value',true) END;
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='acceptance_parent_not_found'; END IF;
 RETURN jsonb_build_object('body',result,'path',to_jsonb(actual));
END $$;
CREATE FUNCTION editorial.community_without_evidence(value jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; key text; child jsonb;
BEGIN
 IF jsonb_typeof(value)='object' THEN
  result:='{}'; FOR key,child IN SELECT * FROM jsonb_each(value) LOOP
   IF key<>'evidence' THEN result:=result||jsonb_build_object(key,editorial.community_without_evidence(child)); END IF; END LOOP;
  RETURN result;
 ELSIF jsonb_typeof(value)='array' THEN
  SELECT COALESCE(jsonb_agg(editorial.community_without_evidence(v) ORDER BY n),'[]') INTO result
   FROM jsonb_array_elements(value) WITH ORDINALITY AS a(v,n); RETURN result;
 END IF;
 RETURN value;
END $$;
CREATE FUNCTION editorial.community_leaves(node jsonb,prefix text[] DEFAULT ARRAY[]::text[])
RETURNS TABLE(path text[],value jsonb)
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE key text; child jsonb; n integer:=0;
BEGIN
 IF jsonb_typeof(node)='object' THEN
  FOR key,child IN SELECT * FROM jsonb_each(node) LOOP
   IF key NOT IN ('component_id','evidence') THEN RETURN QUERY SELECT * FROM editorial.community_leaves(child,prefix||key); END IF;
  END LOOP;
 ELSIF jsonb_typeof(node)='array' THEN
  FOR child IN SELECT * FROM jsonb_array_elements(node) LOOP RETURN QUERY SELECT * FROM editorial.community_leaves(child,prefix||n::text); n:=n+1; END LOOP;
 ELSE path:=prefix;value:=node; RETURN NEXT; END IF;
END $$;
CREATE FUNCTION editorial.community_normal_path(path text[]) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT COALESCE(array_agg(CASE WHEN p ~ '^(0|[1-9][0-9]*)$' OR p='-' THEN '*' ELSE p END ORDER BY n),ARRAY[]::text[])
 FROM unnest(path) WITH ORDINALITY AS a(p,n)
$$;
CREATE FUNCTION editorial.community_evidence_slot(path text[]) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF path[1] IN ('contacts','addresses','organizations','conditions','contact_links','languages','coverage','classifications') AND cardinality(path)>=2 THEN
  RETURN path[1:2]||ARRAY['evidence'];
 ELSIF path[1]='place' THEN RETURN ARRAY['place','evidence'];
 ELSIF path[1]='schedules' AND cardinality(path)>=2 THEN
  IF path[3]='days' AND path[5]='intervals' AND cardinality(path)>=6 THEN RETURN path[1:6]||ARRAY['evidence']; END IF;
  RETURN path[1:2]||ARRAY['evidence'];
 ELSIF path[1]='calendar_links' AND path[3]='effects' THEN
  IF path[5]='intervals' AND cardinality(path)>=6 THEN RETURN path[1:6]||ARRAY['evidence']; END IF;
  RETURN path[1:4]||ARRAY['evidence'];
 END IF;
 IF path[1] IN ('latitude','longitude') THEN RETURN ARRAY['evidence','coordinates']; END IF;
 RETURN ARRAY['evidence',path[1]];
END $$;

CREATE FUNCTION editorial.community_claim_key(path text[],value jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT encode(sha256(convert_to(jsonb_build_array(editorial.community_normal_path(path),value)::text,'UTF8')),'hex')
$$;
CREATE FUNCTION editorial.community_context_matches(source jsonb,target jsonb,source_path text[],target_path text[]) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE src_day integer:=array_position(source_path,'days'); dst_day integer:=array_position(target_path,'days');
BEGIN
 IF src_day IS NOT NULL AND dst_day IS NOT NULL THEN
  RETURN source#>(source_path[1:src_day+1]||ARRAY['weekday']) IS NOT DISTINCT FROM target#>(target_path[1:dst_day+1]||ARRAY['weekday']);
 END IF;
 RETURN true;
END $$;
CREATE FUNCTION editorial.community_locator_supports(snapshot jsonb,combined jsonb,source_path text[],target_path text[],locator jsonb) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE cited text[]:=editorial.community_path(locator->>'path'); n integer:=cardinality(cited);
 meta boolean:=target_path[cardinality(target_path)] IN ('channel_type','weekday','end_day_offset','scope','timezone','completeness','normalization_state');
 src_relative text[]; cite_relative text[]; root_size integer;
BEGIN
 IF NOT editorial.community_context_matches(snapshot,combined,source_path,target_path) THEN RETURN false; END IF;
 IF cited=source_path[1:n] THEN RETURN true; END IF;
 IF meta THEN
  root_size:=CASE WHEN source_path[1]='location' THEN 2 ELSE 1 END;
  IF cited[1:root_size]<>source_path[1:root_size] THEN RETURN false; END IF;
  src_relative:=source_path[root_size+1:]; cite_relative:=cited[root_size+1:];
  IF editorial.community_evidence_slot(src_relative)=editorial.community_evidence_slot(cite_relative) THEN RETURN true; END IF;
  IF src_relative[1]='schedules' AND src_relative[1:2]=cite_relative[1:2] THEN
   IF src_relative[3]='days' THEN RETURN src_relative[1:4]=cite_relative[1:4]; END IF;
   RETURN true;
  END IF;
 END IF;
 RETURN false;
END $$;
CREATE FUNCTION editorial.materialize_community_locator(s editorial.community_snapshots,locator uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE e jsonb; path text[]; claim jsonb; payload jsonb; digest text; dataset uuid; record uuid; version uuid; capture uuid; run uuid; subject uuid; assertion uuid;
 leaf record; kind text; at timestamptz:=clock_timestamp();
BEGIN
 SELECT assertion_id INTO assertion FROM editorial.community_evidence
  WHERE contribution_id=s.contribution_id AND locator_id=locator;
 IF FOUND THEN RETURN assertion; END IF;
 SELECT entry INTO e FROM jsonb_array_elements(s.evidence) entry WHERE entry->>'id'=locator::text;
 IF e IS NULL OR e->>'kind' NOT IN ('stated','interpreted') OR NOT e ?& ARRAY['quote','span'] THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='submitted_evidence_required'; END IF;
 path:=editorial.community_path(e->>'path'); claim:=s.values#>path;
 IF claim IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='evidence_value_not_found'; END IF;
 IF e->>'kind'='stated' THEN
  FOR leaf IN SELECT * FROM editorial.community_leaves(claim,path) LOOP
   IF leaf.path[cardinality(leaf.path)] NOT IN ('channel_type','weekday','end_day_offset','scope','timezone','completeness',
    'normalization_state','original_language','language_code','sort_order','is_public') AND
    jsonb_typeof(leaf.value) IN ('string','number') AND position(leaf.value#>>'{}' IN e->>'quote')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unrelated_submitted_quote'; END IF;
  END LOOP;
 END IF;
 kind:=CASE WHEN path[1]='location' THEN 'location' ELSE 'service' END;
 INSERT INTO sources.datasets(source_id,external_key,name) VALUES(s.source_id,'community-excerpts','Community selected excerpts') ON CONFLICT DO NOTHING;
 SELECT dataset_id INTO STRICT dataset FROM sources.datasets WHERE source_id=s.source_id AND external_key='community-excerpts';
 payload:=jsonb_build_object('kind','selective_submitted_excerpt','contribution_id',s.contribution_id,'locator',e,
  'original_artifact_sha256',e->>'input_hash','normalized_claim',claim);
 digest:=encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 INSERT INTO sources.records(dataset_id,generated_locator,identity_method)
  VALUES(dataset,'community:'||s.contribution_id::text||':'||locator::text,'community_selected_excerpt') RETURNING record_id INTO record;
 INSERT INTO sources.record_versions(record_id,dataset_id,content_hash,raw_payload) VALUES(record,dataset,digest,payload) RETURNING record_version_id INTO version;
 INSERT INTO sources.captures(dataset_id,retrieved_at,artifact_uri,content_hash,media_type,retrieval_status,source_metadata_snapshot)
  VALUES(dataset,at,'egi:community-excerpt/'||s.contribution_id::text||'/'||locator::text,digest,'application/json','submitted_excerpt',
   s.source_metadata||jsonb_build_object('capture_kind','selective_excerpt','original_artifact_sha256',e->>'input_hash')) RETURNING capture_id INTO capture;
 INSERT INTO sources.capture_records(capture_id,record_version_id,dataset_id,observation_locator) VALUES(capture,version,dataset,'selected-excerpt');
 INSERT INTO sources.processing_runs(run_kind,capture_id,processor_version,config_hash,started_at,finished_at,status)
  VALUES('normalize',capture,'community-selection-1',s.item_version_id::text,at,at,'succeeded') RETURNING run_id INTO run;
 INSERT INTO sources.normalized_subjects(record_version_id,run_id,subject_kind,subject_locator,normalized_payload)
  VALUES(version,run,kind,locator::text,jsonb_build_object('field_path',e->>'path','value',claim)) RETURNING subject_id INTO subject;
 INSERT INTO sources.assertions(subject_id,attribute_code,raw_value,normalized_value,certainty,method,scope)
  VALUES(subject,e->>'path',jsonb_build_object('quote',e->'quote','span',e->'span'),claim,
   CASE WHEN e->>'kind'='stated' THEN 'stated' ELSE 'uncertain' END,'community_'||(e->>'kind'),
   jsonb_build_object('field_path',e->>'path','original_artifact_sha256',e->>'input_hash')) RETURNING assertion_id INTO assertion;
 INSERT INTO editorial.community_evidence(contribution_id,assertion_id,field_path,source_id,locator_id)
  VALUES(s.contribution_id,assertion,e->>'path',s.source_id,locator);
 RETURN assertion;
END $$;
CREATE FUNCTION editorial.community_observe(s editorial.community_snapshots,path text[],value jsonb,observation jsonb) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE pointer text:='/'||array_to_string(path,'/'); assertions jsonb; assertion uuid; source uuid;
BEGIN
 PERFORM preparation.closed(observation,ARRAY['paths','method','note'],ARRAY['paths','method']);
 IF jsonb_typeof(observation->'paths') IS DISTINCT FROM 'array' OR observation->>'method' IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_observation'; END IF;
 assertions:=editorial.record_observation(CASE WHEN path[1]='location' THEN 'location' ELSE 'service' END,
  jsonb_build_object(pointer,value),observation->>'method',observation->>'note');
 assertion:=(assertions->>pointer)::uuid;
 SELECT d.source_id INTO STRICT source FROM sources.assertions a JOIN sources.normalized_subjects n USING(subject_id)
 JOIN sources.record_versions v USING(record_version_id) JOIN sources.datasets d USING(dataset_id) WHERE a.assertion_id=assertion;
 INSERT INTO editorial.community_evidence(contribution_id,assertion_id,field_path,source_id) VALUES(s.contribution_id,assertion,pointer,source);
 RETURN assertion;
END $$;

-- Preserve trusted baseline proof when a complete private body omits canonical
-- evidence. Array components follow their stable identity, never a new position.
CREATE FUNCTION editorial.community_inherit_evidence(old_body jsonb,new_body jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb:=new_body; k text; v jsonb; prior jsonb; entry jsonb; n integer:=0;
BEGIN
 IF jsonb_typeof(new_body)='object' THEN
  FOR k,v IN SELECT * FROM jsonb_each(new_body) LOOP
   IF k<>'evidence' THEN result:=jsonb_set(result,ARRAY[k],editorial.community_inherit_evidence(old_body->k,v),true); END IF;
  END LOOP;
  IF old_body ? 'evidence' AND NOT new_body ? 'evidence' THEN result:=result||jsonb_build_object('evidence',old_body->'evidence'); END IF;
 ELSIF jsonb_typeof(new_body)='array' THEN
  result:='[]';
  FOR entry IN SELECT * FROM jsonb_array_elements(new_body) LOOP
   prior:=NULL;
   IF entry ? 'component_id' THEN
    SELECT value INTO prior FROM jsonb_array_elements(CASE WHEN jsonb_typeof(old_body)='array' THEN old_body ELSE '[]' END)
     WHERE value->>'component_id'=entry->>'component_id';
   ELSE
    SELECT value INTO prior FROM jsonb_array_elements(CASE WHEN jsonb_typeof(old_body)='array' THEN old_body ELSE '[]' END)
     WHERE editorial.community_without_evidence(value)=editorial.community_without_evidence(entry) LIMIT 1;
   END IF;
   result:=result||jsonb_build_array(editorial.community_inherit_evidence(prior,entry)); n:=n+1;
  END LOOP;
 END IF;
 RETURN result;
END $$;

-- Bind changed facts to selected submitted locators or an explicit human check.
-- Reuse a source-leaf index rather than rescanning every proposal for every fact.
CREATE FUNCTION editorial.bind_community_body(s editorial.community_snapshots,old_body jsonb,new_body jsonb,prefix text[],
 selected uuid[],observations jsonb,reason text) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb:=editorial.community_inherit_evidence(old_body,new_body); source jsonb:=jsonb_build_object('service',s.values->'service','location',s.values->'location');
 combined jsonb; index_values jsonb; leaf record; candidate jsonb; e jsonb; observation jsonb; observed_path jsonb;
 source_path text[]; full_path text[]; slot text[]; slot_key text; bound_slots jsonb:='{}'; asserted jsonb; assertion uuid;
 proven boolean; citation uuid; chosen jsonb; record_proof jsonb:=COALESCE(new_body#>'{evidence,record}','[]');
BEGIN
 IF jsonb_typeof(observations) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_observation'; END IF;
 FOR observation IN SELECT * FROM jsonb_array_elements(observations) LOOP
  PERFORM preparation.closed(observation,ARRAY['paths','method','note'],ARRAY['paths','method']);
  IF jsonb_typeof(observation->'paths') IS DISTINCT FROM 'array' OR observation->>'method' IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_observation'; END IF;
 END LOOP;
 SELECT COALESCE(jsonb_object_agg(k,entries),'{}') INTO index_values FROM (
  SELECT editorial.community_claim_key(path,value) AS k,jsonb_agg(jsonb_build_object('path',path,'value',value)) AS entries
  FROM editorial.community_leaves(source) GROUP BY editorial.community_claim_key(path,value)) facts;
 combined:=CASE WHEN prefix[1]='service' THEN jsonb_build_object('service',new_body,'location',s.values->'location')
  ELSE jsonb_build_object('service',s.values->'service','location',jsonb_build_object('kind','new','body',new_body)) END;
 FOR leaf IN SELECT * FROM editorial.community_leaves(editorial.community_without_evidence(new_body)) LOOP
  IF leaf.value IS NOT DISTINCT FROM editorial.community_without_evidence(old_body)#>leaf.path THEN CONTINUE; END IF;
  full_path:=prefix||leaf.path; slot:=editorial.community_evidence_slot(leaf.path);
  -- Visibility and layout/language annotations are explicit editorial choices,
  -- never inferred provider permissions or borrowed source claims.
  IF leaf.path[cardinality(leaf.path)] IN ('is_public','sort_order','original_language','location_kind','coordinate_state') OR
   (leaf.value='"unknown"'::jsonb AND leaf.path[cardinality(leaf.path)] IN ('operational_status','cost_state','state','completeness')) THEN
   CONTINUE;
  END IF;
  -- Only the server may bind a newly created location relationship to the
  -- evidence materialized for that same accepted location.
  IF full_path=ARRAY['service','place','location_id'] AND jsonb_array_length(COALESCE(new_body#>'{place,evidence}','[]'))>0 THEN CONTINUE; END IF;
  proven:=false; assertion:=NULL; chosen:=NULL;
  FOR candidate IN SELECT * FROM jsonb_array_elements(COALESCE(index_values->editorial.community_claim_key(full_path,leaf.value),'[]')) LOOP
   SELECT array_agg(p ORDER BY n) INTO source_path FROM jsonb_array_elements_text(candidate->'path') WITH ORDINALITY AS x(p,n);
   FOR e IN SELECT entry FROM jsonb_array_elements(s.evidence) entry WHERE (entry->>'id')::uuid=ANY(selected) LOOP
    IF editorial.community_locator_supports(source,combined,source_path,full_path,e) THEN
     citation:=(e->>'id')::uuid; assertion:=editorial.materialize_community_locator(s,citation); proven:=true; EXIT;
    END IF;
   END LOOP;
   EXIT WHEN proven;
  END LOOP;
  IF NOT proven THEN
   FOR observation IN SELECT * FROM jsonb_array_elements(observations) LOOP
    FOR observed_path IN SELECT * FROM jsonb_array_elements(observation->'paths') LOOP
     source_path:=editorial.community_path(observed_path#>>'{}');
     IF source_path=full_path[1:cardinality(source_path)] THEN
      assertion:=editorial.community_observe(s,full_path,leaf.value,observation); proven:=true; EXIT;
     END IF;
    END LOOP;
    EXIT WHEN proven;
   END LOOP;
  END IF;
  IF NOT proven THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='community_fact_needs_evidence_or_observation',DETAIL='/'||array_to_string(full_path,'/'); END IF;
  slot_key:=array_to_string(slot,'/');
  IF NOT bound_slots ? slot_key THEN asserted:='[]'; ELSE asserted:=bound_slots->slot_key; END IF;
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(asserted) a WHERE a->>'assertion_id'=assertion::text) THEN
   asserted:=asserted||jsonb_build_array(jsonb_build_object('assertion_id',assertion,'role','supporting')); END IF;
  bound_slots:=bound_slots||jsonb_build_object(slot_key,asserted);
  IF leaf.path[1] IN ('latitude','longitude') THEN
   bound_slots:=bound_slots||jsonb_build_object('evidence/'||leaf.path[1],jsonb_build_array(jsonb_build_object('assertion_id',assertion,'role','supporting')));
  END IF;
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(record_proof) a WHERE a->>'assertion_id'=assertion::text) THEN
   record_proof:=record_proof||jsonb_build_array(jsonb_build_object('assertion_id',assertion,'role','supporting')); END IF;
 END LOOP;
 -- Reset only touched decision containers; unrelated baseline proof survives.
 FOR slot_key,asserted IN SELECT * FROM jsonb_each(bound_slots) LOOP
  slot:=string_to_array(slot_key,'/');
  IF slot[1]='evidence' AND NOT result ? 'evidence' THEN result:=result||'{"evidence":{}}'; END IF;
  result:=jsonb_set(result,slot,asserted,true);
 END LOOP;
 IF NOT result ? 'evidence' THEN result:=result||'{"evidence":{}}'; END IF;
 result:=jsonb_set(result,'{evidence,record}',record_proof,true);
 RETURN result;
END $$;

CREATE FUNCTION editorial.accept_community_item(contribution uuid,decision jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE actor uuid:=preparation.actor(); s editorial.community_snapshots; c editorial.contributions;
 previous editorial.contributions; resolved editorial.community_resolutions; digest text:=preparation.digest(decision);
 service uuid; work uuid; public_head uuid; baseline jsonb:='{}'; body jsonb; operation jsonb; patch jsonb;
 selected uuid[]:=ARRAY[]::uuid[]; evidence_id jsonb; location jsonb; locbody jsonb; locold jsonb:='{}'; locid uuid; locrev uuid; locwork uuid; locpublic uuid;
 revision uuid; loc_selected uuid[]; observations jsonb; result jsonb; place jsonb; is_new boolean;
BEGIN
 IF key IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='request_key_required'; END IF;
 PERFORM preparation.closed(decision,ARRAY['schema_version','expected_service_work','expected_service_public','service_operations','location','reason','observations'],
  ARRAY['schema_version','expected_service_work','expected_service_public','service_operations','location','reason','observations']);
 IF decision->'schema_version'<>'1'::jsonb OR jsonb_typeof(decision->'reason') IS DISTINCT FROM 'string' OR COALESCE(btrim(decision->>'reason'),'')='' OR
  jsonb_typeof(decision->'service_operations') IS DISTINCT FROM 'array' OR jsonb_typeof(decision->'observations') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_decision'; END IF;
 PERFORM governance.lock_operation();
 SELECT * INTO s FROM editorial.community_snapshots WHERE contribution_id=contribution;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('community-item:'||s.item_id::text,0));
 SELECT * INTO resolved FROM editorial.community_resolutions WHERE contribution_id=contribution;
 IF FOUND THEN
  IF resolved.decision_digest<>digest THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='community_acceptance_conflict'; END IF;
  RETURN to_jsonb(resolved)||jsonb_build_object('already_accepted',true);
 END IF;
 c:=editorial.locked(contribution);
 service:=CASE WHEN s.values#>>'{target,kind}'='existing' THEN (s.values#>>'{target,service_id}')::uuid ELSE editorial.community_identity(contribution) END;
 IF service IS NOT NULL AND editorial.community_identity(contribution) IS NOT NULL AND service<>editorial.community_identity(contribution) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='community_item_identity_conflict'; END IF;
 IF service IS NULL AND s.parent_contribution_id IS NOT NULL THEN
  SELECT * INTO previous FROM editorial.contributions WHERE contribution_id=s.parent_contribution_id;
  IF previous.state<>'closed' OR previous.outcome NOT IN ('rejected','no_change') THEN
   RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_lineage_unresolved'; END IF;
 END IF;
 work:=(decision->>'expected_service_work')::uuid; public_head:=(decision->>'expected_service_public')::uuid;
 is_new:=service IS NULL;
 IF is_new THEN
  IF work IS NOT NULL OR public_head IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='stale_base'; END IF;
 ELSE
  IF s.values#>>'{target,kind}'='existing' AND (work IS DISTINCT FROM (s.values#>>'{target,expected_work}')::uuid OR
   public_head IS DISTINCT FROM (s.values#>>'{target,expected_public}')::uuid) THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='community_snapshot_heads_changed'; END IF;
  PERFORM governance.lock_expected(service,work,public_head);
  baseline:=editorial.revision_body(work);
 END IF;
 body:=baseline; observations:=decision->'observations';
 FOR operation IN SELECT * FROM jsonb_array_elements(decision->'service_operations') LOOP
  patch:=editorial.community_patch(body,operation); body:=patch->'body';
  FOR evidence_id IN SELECT * FROM jsonb_array_elements(operation->'evidence_ids') LOOP
   IF jsonb_typeof(evidence_id) IS DISTINCT FROM 'string' OR NOT EXISTS(SELECT FROM jsonb_array_elements(s.evidence) e WHERE e->>'id'=evidence_id#>>'{}') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_evidence_selection'; END IF;
   selected:=array_append(selected,(evidence_id#>>'{}')::uuid);
  END LOOP;
 END LOOP;
 PERFORM preparation.validate_body(editorial.community_without_evidence(body),'service');
 IF COALESCE(body->>'delivery_mode','') NOT IN ('in_person','telephone','online','itinerant') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='explicit_delivery_mode_required'; END IF;
 IF is_new AND COALESCE(btrim(body->>'name'),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='service_name_required'; END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(COALESCE(body->'contacts','[]')) entry WHERE NOT entry ? 'is_public') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contact_visibility_required'; END IF;
 location:=decision->'location';
 PERFORM preparation.closed(location,ARRAY['kind','location_id','expected_work','expected_public','action','body'],ARRAY['kind']);
 IF location->>'kind'='none' THEN
  PERFORM preparation.closed(location,ARRAY['kind'],ARRAY['kind']);
 ELSIF location->>'kind' IN ('new','existing') THEN
  IF location->>'kind'='new' THEN
   PERFORM preparation.closed(location,ARRAY['kind','body'],ARRAY['kind','body']);
  ELSE
   PERFORM preparation.closed(location,ARRAY['kind','location_id','expected_work','expected_public','action','body'],
    ARRAY['kind','location_id','expected_work','expected_public','action']);
   locid:=(location->>'location_id')::uuid; locwork:=(location->>'expected_work')::uuid; locpublic:=(location->>'expected_public')::uuid;
   IF NOT EXISTS(SELECT FROM data.locations WHERE entity_id=locid) OR location->>'action' NOT IN ('reuse','revise') OR
    (location->>'action'='reuse' AND location ? 'body') OR (location->>'action'='revise' AND NOT location ? 'body') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_location'; END IF;
   PERFORM governance.lock_expected(locid,locwork,locpublic);
   locold:=editorial.revision_body(locwork);
  END IF;
  IF location->>'kind'='new' OR location->>'action'='revise' THEN
   locbody:=location->'body'; PERFORM preparation.validate_body(locbody,'location');
   IF COALESCE(btrim(locbody->>'location_kind'),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='location_kind_required'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements(COALESCE(locbody->'contacts','[]')) entry WHERE NOT entry ? 'is_public') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contact_visibility_required'; END IF;
   SELECT COALESCE(array_agg((e->>'id')::uuid),ARRAY[]::uuid[]) INTO loc_selected FROM jsonb_array_elements(s.evidence) e WHERE starts_with(e->>'path','/location/body/');
   locbody:=editorial.bind_community_body(s,locold,locbody,ARRAY['location','body'],loc_selected,observations,decision->>'reason');
   locrev:=governance.save_revision('location',locid,locwork,locpublic,locbody,decision->>'reason');
   SELECT entity_id INTO locid FROM governance.entity_revisions WHERE revision_id=locrev;
  END IF;
  -- A chosen location explicitly changes the delivery context; it does not copy
  -- an unselected proposal or invent a location for a telephone/online service.
  place:=COALESCE(body->'place','{}');
  IF place ? 'location_id' AND EXISTS(SELECT FROM jsonb_array_elements(decision->'service_operations') op
   WHERE op->>'path'='/place' OR starts_with(op->>'path','/place/')) AND (place->>'location_id')::uuid<>locid THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='location_selection_conflict'; END IF;
  place:=(place-'territory_id'-'area_description'-'evidence')||jsonb_build_object('location_id',locid);
  IF locrev IS NOT NULL THEN
   SELECT COALESCE(jsonb_agg(jsonb_build_object('assertion_id',assertion_id,'role','supporting')),'[]') INTO result
    FROM editorial.community_evidence WHERE contribution_id=contribution AND starts_with(field_path,'/location/body/');
   IF jsonb_array_length(result)>0 THEN place:=place||jsonb_build_object('evidence',result); END IF;
  END IF;
  body:=jsonb_set(body,'{place}',place,true);
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_community_location'; END IF;
 -- The chosen location relationship is verified explicitly or supported by its
 -- submitted interpreted locator; the fact binder never borrows an unrelated quote.
 body:=editorial.bind_community_body(s,baseline,body,ARRAY['service'],selected,observations,decision->>'reason');
 revision:=governance.save_revision('service',service,work,public_head,body,decision->>'reason');
 SELECT entity_id INTO service FROM governance.entity_revisions WHERE revision_id=revision;
 INSERT INTO editorial.community_resolutions(contribution_id,service_id,initial_revision_id,accepted_by,request_key,decision_digest)
  VALUES(contribution,service,revision,actor,key,digest) RETURNING * INTO resolved;
 RETURN to_jsonb(resolved)||jsonb_build_object('already_accepted',false,'location_revision_id',locrev);
END $$;

CREATE OR REPLACE FUNCTION editorial.authorize_community_closure(contribution uuid,outcome text,publication uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE resolved editorial.community_resolutions; published governance.publications;
BEGIN
 IF outcome<>'published' THEN RETURN; END IF;
 SELECT * INTO resolved FROM editorial.community_resolutions WHERE contribution_id=contribution;
 SELECT * INTO published FROM governance.publications WHERE publication_id=publication;
 IF resolved.contribution_id IS NULL OR published.publication_id IS NULL OR published.entity_id<>resolved.service_id OR NOT EXISTS(
  WITH RECURSIVE lineage(revision_id) AS (
   SELECT published.revision_id UNION SELECT r.parent_revision_id FROM governance.entity_revisions r JOIN lineage l USING(revision_id) WHERE r.parent_revision_id IS NOT NULL)
  SELECT FROM lineage WHERE revision_id=resolved.initial_revision_id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='community_publication_required'; END IF;
END $$;
CREATE FUNCTION editorial.close_community_item(contribution uuid,outcome text,reason text,publication uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=preparation.actor();
BEGIN
 IF NOT EXISTS(SELECT FROM editorial.community_snapshots WHERE contribution_id=contribution) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 PERFORM editorial.close_contribution(contribution,outcome,reason,publication);
END $$;

-- Keep the original function's identity/grants. Replacing its body invalidates
-- cached plans; no old alias can bypass the new authoritative publication rule.
CREATE OR REPLACE FUNCTION governance.publication_diagnostics(target uuid) RETURNS TABLE(code text,field text)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT * FROM governance.prior_directory_diagnostics(target)
 UNION ALL SELECT 'unpublished_parent_location','parent_location_id' FROM data.location_revisions l WHERE l.revision_id=target AND l.parent_location_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=l.parent_location_id)
 UNION ALL SELECT DISTINCT 'community_source_not_admitted','source:'||ce.source_id::text
 FROM governance.value_decisions vd JOIN governance.value_evidence ve USING(value_decision_id)
 JOIN editorial.community_evidence ce USING(assertion_id)
 WHERE vd.revision_id=target AND NOT EXISTS(SELECT FROM governance.community_source_admissions a WHERE a.source_id=ce.source_id)
$$;

REVOKE ALL ON TABLE editorial.community_resolutions,editorial.community_evidence FROM PUBLIC,egi_editorial,egi_writer,egi_reader,egi_retention,egi_preparation_worker;
REVOKE ALL ON FUNCTION editorial.community_resolution_guard(),editorial.community_evidence_guard(),editorial.community_path(text),
 editorial.community_patch(jsonb,jsonb),editorial.community_inherit_evidence(jsonb,jsonb),editorial.community_without_evidence(jsonb),editorial.community_leaves(jsonb,text[]),
 editorial.community_normal_path(text[]),editorial.community_evidence_slot(text[]),editorial.community_claim_key(text[],jsonb),
 editorial.community_context_matches(jsonb,jsonb,text[],text[]),editorial.community_locator_supports(jsonb,jsonb,text[],text[],jsonb),
 editorial.materialize_community_locator(editorial.community_snapshots,uuid),editorial.community_observe(editorial.community_snapshots,text[],jsonb,jsonb),
 editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text),
 editorial.accept_community_item(uuid,jsonb,uuid),editorial.close_community_item(uuid,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.accept_community_item(uuid,jsonb,uuid),editorial.close_community_item(uuid,text,text,uuid) TO egi_editorial;
COMMIT;
