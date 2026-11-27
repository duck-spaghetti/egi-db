-- Deploy egi_database:013_editorial_observations
-- requires: 012_revision_body
-- EGI-84: what a moderator verified becomes a source, so a service or location created
-- in the workspace can cite evidence like any imported one. The source is "Redazione
-- EGI"; each observation is a record of who observed what, how and when. Publication
-- still requires supporting evidence; this gives a moderator's own check an accountable
-- origin instead of relaxing that rule. The source is created by the first observation:
-- a structural deployment seeds no source (tests/contract/00-clean.sql).
BEGIN;

-- Record one observation as the verified person and return its assertions by attribute.
-- `observed` maps attribute codes to the values the person checked; `method` is how.
-- Notes are kept with the source record: no personal data of third parties.
CREATE FUNCTION editorial.record_observation(subject_kind text,observed jsonb,method text,note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
 actor uuid:=governance.current_actor(); at timestamptz:=clock_timestamp(); payload jsonb; digest text;
 dataset uuid; record uuid; version uuid; capture uuid; run uuid; subject uuid; assertion uuid; item record; result jsonb:='{}';
BEGIN
 PERFORM governance.require_capability('propose',NULL);
 IF subject_kind IS NULL OR subject_kind NOT IN ('service','location') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_subject_kind';
 END IF;
 IF method IS NULL OR method NOT IN ('phone_call','official_website','site_visit','document','other') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_method';
 END IF;
 IF jsonb_typeof(observed) IS DISTINCT FROM 'object' OR observed='{}' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='nothing_observed';
 END IF;
 note:=NULLIF(btrim(note),'');
 IF length(note)>1000 THEN RAISE EXCEPTION USING ERRCODE='22001',MESSAGE='note_too_long'; END IF;

 INSERT INTO sources.registry(code,name,publisher,source_kind) VALUES('egi_editorial','Redazione EGI','EGI','editorial')
  ON CONFLICT(code) DO NOTHING;
 INSERT INTO sources.datasets(source_id,external_key,name)
  SELECT source_id,'observations','Verifiche della redazione' FROM sources.registry WHERE code='egi_editorial'
  ON CONFLICT(source_id,external_key) DO NOTHING;
 SELECT d.dataset_id INTO STRICT dataset FROM sources.datasets d JOIN sources.registry r USING(source_id)
  WHERE r.code='egi_editorial' AND d.external_key='observations';
 payload:=jsonb_build_object('subject_kind',subject_kind,'method',method,'note',note,'values',observed,
  'actor_id',actor,'observed_at',at);
 digest:=encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 INSERT INTO sources.records(dataset_id,generated_locator,identity_method)
 VALUES(dataset,'observation:'||gen_random_uuid(),'editorial_observation') RETURNING record_id INTO record;
 INSERT INTO sources.record_versions(record_id,dataset_id,content_hash,raw_payload)
 VALUES(record,dataset,digest,payload) RETURNING record_version_id INTO version;
 INSERT INTO sources.captures(dataset_id,retrieved_at,artifact_uri,content_hash,media_type,retrieval_status,source_metadata_snapshot)
 VALUES(dataset,at,'egi:editorial-observation/'||record,digest,'application/json','observed',jsonb_build_object('method',method))
 RETURNING capture_id INTO capture;
 INSERT INTO sources.capture_records(capture_id,record_version_id,dataset_id,observation_locator)
 VALUES(capture,version,dataset,'observation');
 INSERT INTO sources.processing_runs(run_kind,capture_id,processor_version,config_hash,started_at,finished_at,status)
 VALUES('normalize',capture,'editorial-observation-1','none',at,at,'succeeded') RETURNING run_id INTO run;
 INSERT INTO sources.normalized_subjects(record_version_id,run_id,subject_kind,subject_locator,normalized_payload)
 VALUES(version,run,subject_kind,'observation',observed) RETURNING subject_id INTO subject;
 FOR item IN SELECT key,value FROM jsonb_each(observed) ORDER BY key LOOP
  INSERT INTO sources.assertions(subject_id,attribute_code,raw_value,normalized_value,certainty,method)
  VALUES(subject,item.key,item.value,item.value,'stated','editorial_'||method) RETURNING assertion_id INTO assertion;
  result:=result||jsonb_build_object(item.key,assertion);
 END LOOP;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION editorial.record_observation(text,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.record_observation(text,jsonb,text,text) TO egi_editorial;

COMMIT;
