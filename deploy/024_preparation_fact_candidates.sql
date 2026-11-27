-- Deploy egi_database:024_preparation_fact_candidates
-- requires: 023_preparation_source_facts
-- EGI-114 provider completion: explicit job protocol and stable fact materialization.
BEGIN;
ALTER FUNCTION preparation.validate_job_result(preparation.jobs,jsonb) RENAME TO validate_job_result_v1;
ALTER FUNCTION preparation.merge_candidate(jsonb,jsonb,uuid,uuid) RENAME TO merge_candidate_v1;

CREATE FUNCTION preparation.literal_candidate_payload(candidate jsonb,input uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE fact jsonb; facts jsonb:='[]'; origins jsonb:='{}'; idx integer:=0;
BEGIN
 IF jsonb_typeof(candidate->'source_facts') IS DISTINCT FROM 'array' OR jsonb_array_length(candidate->'source_facts')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_facts'; END IF;
 FOR fact IN SELECT * FROM jsonb_array_elements(candidate->'source_facts') LOOP
  PERFORM preparation.closed(fact,ARRAY['fact_key','subject','kind','source_value'],ARRAY['fact_key','subject','kind','source_value']);
  IF jsonb_typeof(fact->'fact_key') IS DISTINCT FROM 'string' OR length(fact->>'fact_key') NOT BETWEEN 1 AND 100 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_fact_key'; END IF;
  facts:=facts||jsonb_build_array((fact-'fact_key')||jsonb_build_object('fact_id',gen_random_uuid(),'value',fact->'source_value'));
  origins:=origins||jsonb_build_object('/source_facts/'||idx||'/source_value',jsonb_build_object('state','generated','input_id',input,'job_id',job),
   '/source_facts/'||idx||'/value',jsonb_build_object('state','generated','input_id',input,'job_id',job));
  idx:=idx+1;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(candidate->'source_facts') f GROUP BY f->>'fact_key' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_source_fact_key'; END IF;
 RETURN jsonb_build_object('schema_version',2,'service',candidate->'service','location',candidate->'location',
  'target',jsonb_build_object('kind','new'),'outcome','review','field_origins',origins,'evidence',candidate->'evidence','source_facts',facts,'resolutions','[]'::jsonb);
END $$;

CREATE FUNCTION preparation.validate_job_result(j preparation.jobs,result jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE protocol jsonb; proxy jsonb; candidates jsonb:='[]'; c jsonb; mapped jsonb; locators jsonb; e jsonb;
BEGIN
 SELECT COALESCE(provider_config->'interpretation_version','1'::jsonb) INTO protocol FROM preparation.ai_configurations WHERE version=j.config_version;
 IF protocol NOT IN ('1'::jsonb,'2'::jsonb) OR result->'schema_version' IS DISTINCT FROM protocol THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_version_conflict'; END IF;
 IF protocol='1'::jsonb THEN PERFORM preparation.validate_job_result_v1(j,result); RETURN; END IF;
 PERFORM preparation.closed(result,ARRAY['schema_version','input_id','input_hash','config_version','state','candidates','mapping','diagnostics'],
  ARRAY['schema_version','input_id','input_hash','config_version','state','candidates','mapping','diagnostics']);
 IF jsonb_typeof(result->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(result->'candidates')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_candidates'; END IF;
 FOR c IN SELECT * FROM jsonb_array_elements(result->'candidates') LOOP
  PERFORM preparation.closed(c,ARRAY['candidate_key','service','location','evidence','diagnostics','source_facts'],
   ARRAY['candidate_key','service','location','evidence','diagnostics','source_facts']);
  -- Validate typed literal facts independently; UUIDs exist only in this private
  -- validation proxy. Materialization allocates the actual persisted identities.
  PERFORM preparation.validate_payload(j.workspace_id,preparation.literal_candidate_payload(c,j.input_id,j.id));
  IF jsonb_array_length(COALESCE(c#>'{service,organizations}','[]'))>0 OR
   jsonb_array_length(COALESCE(c#>'{service,classifications}','[]'))>0 OR
   jsonb_array_length(COALESCE(c#>'{location,body,organizations}','[]'))>0 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='provider_identity_or_permission_forbidden'; END IF;
  locators:='[]';
  FOR e IN SELECT * FROM jsonb_array_elements(c->'evidence') LOOP
   IF starts_with(e->>'path','/source_facts/') THEN e:=jsonb_set(e,'{path}','"/service/name"'); END IF;
   locators:=locators||jsonb_build_array(e);
  END LOOP;
  mapped:=(c-'source_facts')||jsonb_build_object('evidence',locators);
  candidates:=candidates||jsonb_build_array(mapped);
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(result->'candidates') AS candidate_rows(value)
  CROSS JOIN LATERAL jsonb_array_elements(candidate_rows.value->'evidence') AS evidence_rows(value)
  GROUP BY (evidence_rows.value->>'id')::uuid HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_candidate_evidence_id'; END IF;
 proxy:=result||jsonb_build_object('schema_version',1,'candidates',candidates);
 -- The baseline validator checks eligibility/redactions, identity, usage-adjacent
 -- result shape and diagnostics for all quotes, including the temporary locators.
 PERFORM preparation.validate_job_result_v1(j,proxy);
END $$;

CREATE FUNCTION preparation.merge_candidate(old jsonb,candidate jsonb,input uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE merged jsonb:=preparation.merge_candidate_v1(old,candidate,input,job); payload jsonb:=merged->'payload';
 incoming jsonb; fact jsonb; facts jsonb; evidence jsonb:=payload->'evidence'; origins jsonb:=payload->'field_origins';
 conflicts jsonb:=merged->'conflicts'; old_index integer; idx integer; new_index integer; e jsonb; current_fact jsonb;
 used uuid[]:=ARRAY[]::uuid[]; new_path text;
BEGIN
 IF NOT candidate ? 'source_facts' THEN RETURN merged; END IF;
 incoming:=preparation.literal_candidate_payload(candidate,input,job);
 facts:=COALESCE(old->'source_facts','[]');
 FOR fact,idx IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(incoming->'source_facts') WITH ORDINALITY LOOP
  -- Reuse a private fact only with the same typed literal AND exact source
  -- locator. Name similarity alone never collapses two organizations/claims.
  SELECT o.ordinality::integer-1 INTO old_index FROM jsonb_array_elements(COALESCE(old->'source_facts','[]')) WITH ORDINALITY o
   WHERE o.value->>'subject'=fact->>'subject' AND o.value->>'kind'=fact->>'kind' AND o.value->>'source_value'=fact->>'source_value'
   AND NOT (o.value->>'fact_id')::uuid=ANY(used) AND EXISTS(
    SELECT FROM jsonb_array_elements(old->'evidence') oe CROSS JOIN jsonb_array_elements(candidate->'evidence') ne
    WHERE oe->>'path'='/source_facts/'||(o.ordinality-1)||'/source_value' AND ne->>'path'='/source_facts/'||idx||'/source_value'
     AND oe->'input_id'=ne->'input_id' AND oe->'input_hash'=ne->'input_hash' AND oe->'span'=ne->'span' AND oe->'quote'=ne->'quote')
   ORDER BY o.ordinality LIMIT 1;
  IF old_index IS NOT NULL THEN
   current_fact:=old->'source_facts'->old_index; used:=array_append(used,(current_fact->>'fact_id')::uuid);
   IF old#>>ARRAY['field_origins','/source_facts/'||old_index||'/value','state'] IN ('manual','cleared') THEN
    conflicts:=conflicts||jsonb_build_array('/source_facts/'||old_index||'/value'); END IF;
   CONTINUE;
  END IF;
  new_index:=jsonb_array_length(facts); facts:=facts||jsonb_build_array(fact);
  new_path:='/source_facts/'||new_index;
  origins:=origins||jsonb_build_object(new_path||'/source_value',incoming#>ARRAY['field_origins','/source_facts/'||idx||'/source_value'],
   new_path||'/value',incoming#>ARRAY['field_origins','/source_facts/'||idx||'/value']);
  FOR e IN SELECT * FROM jsonb_array_elements(candidate->'evidence') WHERE value->>'path'='/source_facts/'||idx||'/source_value' LOOP
   evidence:=evidence||jsonb_build_array(e||jsonb_build_object('id',gen_random_uuid(),'path',new_path||'/source_value'));
  END LOOP;
 END LOOP;
 payload:=payload||jsonb_build_object('schema_version',2,'source_facts',facts,'resolutions',COALESCE(old->'resolutions','[]'),
  'evidence',evidence,'field_origins',origins);
 RETURN jsonb_build_object('payload',payload,'conflicts',conflicts);
END $$;
REVOKE ALL ON FUNCTION preparation.validate_job_result_v1(preparation.jobs,jsonb),preparation.validate_job_result(preparation.jobs,jsonb),
 preparation.literal_candidate_payload(jsonb,uuid,uuid),preparation.merge_candidate_v1(jsonb,jsonb,uuid,uuid),
 preparation.merge_candidate(jsonb,jsonb,uuid,uuid) FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
COMMIT;
