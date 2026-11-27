-- Deploy egi_database:026_community_reference_acceptance
-- requires: 025_preparation_reference_catalog
-- EGI-117: literal evidence, explicit human relationships and atomic draft creation.
BEGIN;
CREATE TABLE editorial.community_fact_resolutions (
 contribution_id uuid NOT NULL REFERENCES editorial.community_snapshots(contribution_id),
 fact_id uuid NOT NULL, organization_id uuid REFERENCES data.organizations(entity_id), organization_revision_id uuid,
 selection jsonb NOT NULL, subject text NOT NULL, fact_value text NOT NULL,
 actor_id uuid NOT NULL REFERENCES governance.actors, item_version_id uuid NOT NULL,
 decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(contribution_id,fact_id),
 FOREIGN KEY(organization_revision_id,organization_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE TRIGGER fact_resolutions_immutable BEFORE UPDATE OR DELETE ON editorial.community_fact_resolutions
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
REVOKE ALL ON editorial.community_fact_resolutions FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;

-- A selected literal supplies the name/label only. Relationship identity and role
-- get an attributed editorial observation from the explicit acceptance decision.
CREATE FUNCTION editorial.apply_community_facts(s editorial.community_snapshots,decision jsonb,body jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE action jsonb; fact jsonb; chosen jsonb; target jsonb; previous editorial.community_fact_resolutions;
 org uuid; revision uuid; orgbody jsonb; assertions jsonb; proof jsonb; locator jsonb; assertion uuid;
 list jsonb; entry jsonb; observations jsonb:='[]'; location jsonb:=decision->'location'; prefix text; name text; subject text; at_index integer;
 field record; seen uuid[]:=ARRAY[]::uuid[]; old_target jsonb;
BEGIN
 IF decision->'schema_version'='1'::jsonb THEN RETURN jsonb_build_object('body',body,'observations',observations); END IF;
 IF jsonb_array_length(decision->'fact_actions')>1000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_fact_actions'; END IF;
 FOR action IN SELECT * FROM jsonb_array_elements(decision->'fact_actions') LOOP
  PERFORM preparation.closed(action,ARRAY['fact_id','action','context','selected','note','reconcile'],ARRAY['fact_id','action']);
  SELECT f INTO fact FROM jsonb_array_elements(COALESCE(s.values->'source_facts','[]')) f WHERE f->>'fact_id'=action->>'fact_id';
  IF fact IS NULL OR (action->>'fact_id')::uuid=ANY(seen) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_fact_action'; END IF;
  seen:=array_append(seen,(action->>'fact_id')::uuid);
  IF action->>'action'='keep' THEN
   PERFORM preparation.closed(action,ARRAY['fact_id','action'],ARRAY['fact_id','action']); CONTINUE;
  END IF;
  IF action->>'action' NOT IN ('select','create') OR NOT action ?& ARRAY['context','selected','note','reconcile'] OR NOT fact ? 'value' OR
   jsonb_typeof(action->'note') IS DISTINCT FROM 'string' OR length(btrim(action->>'note')) NOT BETWEEN 1 AND 1000 OR
   (jsonb_typeof(action->'reconcile') IS DISTINCT FROM 'string' OR action->>'reconcile' NOT IN ('retain','replace')) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='explicit_fact_decision_required'; END IF;
  chosen:=action->'selected'; target:=chosen->'target'; subject:=fact->>'subject';
  PERFORM preparation.closed(chosen,ARRAY['target','role'],ARRAY['target']);
  IF (action->>'action'='create') IS DISTINCT FROM (target->>'kind'='new_organization') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_fact_action'; END IF;
  SELECT r.* INTO previous FROM editorial.community_fact_resolutions r JOIN editorial.community_snapshots p USING(contribution_id)
   WHERE p.item_id=s.item_id AND r.fact_id=(fact->>'fact_id')::uuid ORDER BY r.decided_at DESC,r.contribution_id LIMIT 1;
  IF previous.organization_id IS NULL OR previous.selection->'target' IS DISTINCT FROM target OR target->>'kind'<>'new_organization' THEN
   PERFORM preparation.validate_reference(fact,action->'context',target);
  END IF;
  IF previous.subject IS NOT NULL AND previous.subject<>subject THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_fact_action'; END IF;
  SELECT e INTO locator FROM jsonb_array_elements(s.evidence) e WHERE e->>'path'='/source_facts/'||
   (SELECT (n-1)::text FROM jsonb_array_elements(s.values->'source_facts') WITH ORDINALITY f(v,n) WHERE v->>'fact_id'=fact->>'fact_id')||'/source_value' LIMIT 1;
  IF locator IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='submitted_evidence_required'; END IF;
  assertion:=editorial.materialize_community_locator(s,(locator->>'id')::uuid);
  IF fact->>'kind'='organization_name' THEN
   IF jsonb_typeof(chosen->'role') IS DISTINCT FROM 'string' OR length(btrim(chosen->>'role')) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='explicit_organization_role_required'; END IF;
   IF target->>'kind'='new_organization' THEN
    orgbody:=target->'body';
    IF previous.organization_id IS NOT NULL THEN
     IF previous.selection->'target' IS DISTINCT FROM target THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='organization_reconciliation_required'; END IF;
     org:=previous.organization_id; revision:=previous.organization_revision_id;
     PERFORM governance.lock_expected(org,revision,NULL);
    ELSE
     assertions:=editorial.record_observation('organization',orgbody,'other',action->>'note');
     FOR field IN SELECT key,value FROM jsonb_each_text(assertions) LOOP
      INSERT INTO editorial.community_evidence(contribution_id,assertion_id,field_path,source_id)
       SELECT s.contribution_id,field.value::uuid,'/organization/body/'||field.key,d.source_id
       FROM sources.assertions a JOIN sources.normalized_subjects n USING(subject_id)
       JOIN sources.record_versions rv USING(record_version_id) JOIN sources.datasets d USING(dataset_id)
       WHERE a.assertion_id=field.value::uuid;
     END LOOP;
     SELECT COALESCE(jsonb_object_agg(k,jsonb_build_array(jsonb_build_object('assertion_id',v,'role','supporting'))),'{}') INTO proof FROM jsonb_each(assertions) x(k,v);
     IF orgbody->>'name'=fact->>'source_value' AND fact->>'value'=fact->>'source_value' THEN
      proof:=proof||jsonb_build_object('name',jsonb_build_array(jsonb_build_object('assertion_id',assertion,'role','supporting')));
     END IF;
     proof:=proof||jsonb_build_object('record',jsonb_build_array(jsonb_build_object('assertion_id',assertion,'role','supporting')));
     orgbody:=orgbody||jsonb_build_object('evidence',proof);
     revision:=governance.save_revision('organization',NULL,NULL,NULL,orgbody,decision->>'reason');
     SELECT entity_id INTO org FROM governance.entity_revisions WHERE revision_id=revision;
    END IF;
   ELSE
    org:=(target->>'organization_id')::uuid; revision:=(target->>'expected_work')::uuid;
    PERFORM governance.lock_expected(org,revision,(target->>'expected_public')::uuid);
   END IF;
   name:='organizations'; entry:=jsonb_build_object('organization_id',org,'role_code',chosen->'role');
  ELSE
   IF chosen ? 'role' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_fact_action'; END IF;
   org:=NULL; revision:=NULL; name:='classifications'; entry:=jsonb_build_object('adoption_id',target->'adoption_id','term_id',target->'term_id');
  END IF;
  IF subject='location' THEN
   IF location->>'kind' NOT IN ('new','existing') OR (location->>'kind'='existing' AND location->>'action'<>'revise') OR NOT location ? 'body' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='location_revision_required_for_fact'; END IF;
   list:=COALESCE(location#>ARRAY['body',name],'[]'); prefix:='/location/body/';
  ELSE list:=COALESCE(body->name,'[]'); prefix:='/service/'; END IF;
  IF previous.contribution_id IS NOT NULL AND action->>'reconcile'='replace' THEN
   old_target:=previous.selection->'target';
   SELECT COALESCE(jsonb_agg(x ORDER BY n),'[]') INTO list FROM jsonb_array_elements(list) WITH ORDINALITY v(x,n)
    WHERE NOT (CASE WHEN name='organizations' THEN x->>'organization_id'=previous.organization_id::text AND x->'role_code'=previous.selection->'role'
     ELSE x->'adoption_id'=old_target->'adoption_id' AND x->'term_id'=old_target->'term_id' END);
  END IF;
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(list) x WHERE (CASE WHEN name='organizations' THEN x->'organization_id'=entry->'organization_id' AND x->'role_code'=entry->'role_code'
   ELSE x->'adoption_id'=entry->'adoption_id' AND x->'term_id'=entry->'term_id' END)) THEN
   at_index:=jsonb_array_length(list); list:=list||jsonb_build_array(entry);
   observations:=observations||jsonb_build_array(jsonb_build_object('paths',jsonb_build_array(prefix||name||'/'||at_index),'method','other','note',action->>'note'));
  END IF;
  IF subject='location' THEN location:=jsonb_set(location,ARRAY['body',name],list); ELSE body:=jsonb_set(body,ARRAY[name],list); END IF;
  INSERT INTO editorial.community_fact_resolutions(contribution_id,fact_id,organization_id,organization_revision_id,selection,subject,fact_value,actor_id,item_version_id)
   VALUES(s.contribution_id,(fact->>'fact_id')::uuid,org,revision,chosen,subject,fact->>'value',preparation.actor(),s.item_version_id);
 END LOOP;
 RETURN jsonb_build_object('body',body,'observations',observations,'location',location);
END $$;

CREATE OR REPLACE FUNCTION editorial.record_observation(subject_kind text,observed jsonb,method text,note text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
 actor uuid:=governance.current_actor(); at timestamptz:=clock_timestamp(); payload jsonb; digest text;
 dataset uuid; record uuid; version uuid; capture uuid; run uuid; subject uuid; assertion uuid; item record; result jsonb:='{}';
BEGIN
 PERFORM governance.require_capability('propose',NULL);
 IF subject_kind IS NULL OR subject_kind NOT IN ('service','location','organization') THEN
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

CREATE OR REPLACE FUNCTION editorial.revision_body(revision uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
 kind text; own jsonb; texts jsonb; supported jsonb; by_field jsonb; result jsonb; named text; evidence jsonb; field text;
BEGIN
 PERFORM governance.current_actor();
 SELECT entity_kind INTO kind FROM governance.entity_revisions WHERE revision_id=revision;
 IF kind IS NULL OR kind NOT IN ('service','location','organization') THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='revision_not_found';
 END IF;

 IF kind='organization' AND NOT EXISTS(SELECT FROM governance.entity_revisions r LEFT JOIN governance.published_heads p ON p.revision_id=r.revision_id
  WHERE r.revision_id=revision AND (p.entity_id IS NOT NULL OR preparation.organization_visible(r.entity_id))) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='revision_not_found'; END IF;

 -- Original texts, and the evidence of every value decision of this revision.
 SELECT COALESCE(jsonb_object_agg(c.content_id::text,jsonb_build_array(c.original_text,c.original_language)),'{}')
  INTO texts FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=revision;
 SELECT COALESCE(jsonb_object_agg(d.value_decision_id::text,COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'assertion_id',e.assertion_id,'role',e.evidence_role) ORDER BY e.assertion_id,e.evidence_role)
   FROM governance.value_evidence e WHERE e.value_decision_id=d.value_decision_id),'[]')),'{}'),
  COALESCE(jsonb_object_agg(d.field_code,COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'assertion_id',e.assertion_id,'role',e.evidence_role) ORDER BY e.assertion_id,e.evidence_role)
   FROM governance.value_evidence e WHERE e.value_decision_id=d.value_decision_id),'[]'))
   FILTER (WHERE d.component_id IS NULL),'{}')
  INTO supported,by_field FROM governance.value_decisions d WHERE d.revision_id=revision;

 IF kind='service' THEN
  SELECT to_jsonb(t) INTO own FROM data.service_revisions t WHERE t.revision_id=revision;
  result:=editorial.present(jsonb_build_object(
   'delivery_mode',own->'delivery_mode','operational_status',own->'operational_status','cost_state',own->'cost_state',
   'valid_from',own->'valid_from','valid_until',own->'valid_until','closure_date',own->'closure_date',
   'name',texts->(own->>'name_content_id')->0,'description',texts->(own->>'description_content_id')->0,
   'cost_note',texts->(own->>'cost_note_content_id')->0,'closure_reason',texts->(own->>'closure_reason_content_id')->0));
  named:=COALESCE(own->>'name_content_id',own->>'description_content_id');
 ELSIF kind='organization' THEN
  SELECT to_jsonb(t) INTO own FROM data.organization_revisions t WHERE t.revision_id=revision;
  result:=editorial.present(jsonb_build_object('name',texts->(own->>'name_content_id')->0,
   'description',texts->(own->>'description_content_id')->0,'organization_type',own->'organization_type','website',own->'website'));
  named:=own->>'name_content_id';
 ELSE
  SELECT to_jsonb(t) INTO own FROM data.location_revisions t WHERE t.revision_id=revision;
  result:=editorial.present(jsonb_build_object(
   'location_kind',own->'location_kind','latitude',own->'latitude','longitude',own->'longitude',
   'coordinate_state',own->'coordinate_state','selected_geocoding_result_id',own->'selected_geocoding_result_id',
   'parent_location_id',own->'parent_location_id','name',texts->(own->>'name_content_id')->0));
  named:=own->>'name_content_id';
 END IF;
 -- An unnamed place has its language on its contact labels.
 named:=COALESCE(named,(SELECT min(k COLLATE "C") FROM jsonb_object_keys(texts) k));
 IF named IS NOT NULL AND COALESCE(texts->named->>1,'')<>'' THEN
  result:=result||jsonb_build_object('original_language',texts->named->>1);
 END IF;

 result:=result||jsonb_build_object('contacts',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
   'component_id',t.component_id,'channel_type',t.channel_type,'value',t.value,'normalized_value',t.normalized_value,
   'purpose_code',t.purpose_code,'sort_order',t.sort_order,'is_public',t.is_public,
   'label',texts->(t.label_content_id::text)->0,'evidence',supported->(t.value_decision_id::text)))
   ORDER BY t.sort_order,t.component_id::text COLLATE "C") FROM data.contact_entries t WHERE t.revision_id=revision),'[]'));

 IF kind='service' THEN
  result:=result||jsonb_build_object(
   'organizations',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'organization_id',t.organization_id,'role_code',t.role_code,
     'evidence',supported->(t.value_decision_id::text))) ORDER BY t.component_id)
     FROM data.service_organizations t WHERE t.revision_id=revision),'[]'),
   'conditions',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'condition_kind',t.condition_kind,'requirement_state',t.requirement_state,
     'details',texts->(t.details_content_id::text)->0,'evidence',supported->(t.value_decision_id::text))) ORDER BY t.component_id)
     FROM data.access_conditions t WHERE t.revision_id=revision),'[]'),
   'contact_links',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'target_entity_id',t.target_entity_id,
     'target_contact_component_id',t.target_contact_component_id,'purpose_code',t.purpose_code,
     'label',texts->(t.label_content_id::text)->0,'evidence',supported->(t.value_decision_id::text))) ORDER BY t.component_id)
     FROM data.service_contact_links t WHERE t.revision_id=revision),'[]'),
   'languages',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'language_code',t.language_code,'availability_kind',t.availability_kind,
     'note',texts->(t.note_content_id::text)->0,'evidence',supported->(t.value_decision_id::text)))
     ORDER BY t.language_code,t.availability_kind)
     FROM data.service_languages t WHERE t.revision_id=revision),'[]'),
   'coverage',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'territory_id',t.territory_id,'geometry_wkt',public.ST_AsText(t.geometry),
     'description',texts->(t.description_content_id::text)->0,'evidence',supported->(t.value_decision_id::text)))
     ORDER BY t.component_id) FROM geo.service_coverage t WHERE t.revision_id=revision),'[]'),
   'classifications',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'adoption_id',t.adoption_id,'term_id',t.term_id,'evidence',supported->(t.value_decision_id::text)))
     ORDER BY t.adoption_id,t.term_id) FROM taxonomy.assignments t WHERE t.revision_id=revision),'[]'),
   'territories',COALESCE((SELECT jsonb_agg(t.territory_id ORDER BY t.territory_id::text COLLATE "C")
     FROM geo.service_memberships t WHERE t.revision_id=revision),'[]'));
  result:=result||COALESCE((SELECT jsonb_build_object('place',editorial.present(jsonb_build_object(
    'component_id',t.component_id,'location_id',t.location_id,'territory_id',t.territory_id,
    'area_description',texts->(t.area_description_content_id::text)->0,'evidence',supported->(t.value_decision_id::text))))
    FROM data.service_places t WHERE t.revision_id=revision ORDER BY t.component_id DESC LIMIT 1),'{}');
  by_field:=by_field||COALESCE((SELECT jsonb_build_object('territories',supported->(t.value_decision_id::text))
    FROM geo.service_memberships t WHERE t.revision_id=revision ORDER BY t.territory_id DESC LIMIT 1),'{}');
 ELSIF kind='organization' THEN
  result:=result||jsonb_build_object('territories',COALESCE((SELECT jsonb_agg(t.territory_id ORDER BY t.territory_id)
    FROM governance.revision_territories t WHERE t.revision_id=revision),'[]'));
 ELSE
  result:=result||jsonb_build_object(
   'organizations',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'organization_id',t.organization_id,'role_code',t.role_code,
     'evidence',supported->(t.value_decision_id::text))) ORDER BY t.component_id)
     FROM data.location_organizations t WHERE t.revision_id=revision),'[]'),
   'addresses',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
     'component_id',t.component_id,'address_kind',t.address_kind,'formatted',t.formatted,'line1',t.line1,
     'locality',t.locality,'postal_code',t.postal_code,'administrative_area',t.administrative_area,
     'country_code',t.country_code,'normalization_state',t.normalization_state,
     'evidence',supported->(t.value_decision_id::text))) ORDER BY t.component_id::text COLLATE "C")
     FROM data.addresses t WHERE t.revision_id=revision),'[]'),
   'territories',COALESCE((SELECT jsonb_agg(t.territory_id ORDER BY t.territory_id::text COLLATE "C")
     FROM governance.revision_territories t WHERE t.revision_id=revision),'[]'));
 END IF;

 -- Weekly hours: schedules by component, days by weekday, intervals by time.
 result:=result||jsonb_build_object('schedules',COALESCE((SELECT jsonb_agg(editorial.present(jsonb_build_object(
   'component_id',s.component_id,'scope',s.scope_code,'timezone',s.timezone_name,
   'contact_component_id',s.contact_component_id,'valid_from',s.valid_from,'valid_until',s.valid_until,
   'completeness',s.completeness,'evidence',supported->(s.value_decision_id::text),
   'days',COALESCE((SELECT jsonb_agg(jsonb_build_object('weekday',d.iso_weekday,'state',d.day_state,
     'completeness',d.completeness,'intervals',COALESCE((SELECT jsonb_agg(jsonb_build_object(
       'component_id',i.component_id,'opens',editorial.clock(i.opens_at),'closes',editorial.clock(i.closes_at),
       'end_day_offset',i.end_day_offset,'evidence',supported->(i.value_decision_id::text)) ORDER BY i.opens_at,i.closes_at)
       FROM data.schedule_intervals i WHERE i.revision_id=revision AND i.schedule_id=s.component_id
        AND i.iso_weekday=d.iso_weekday),'[]')) ORDER BY d.iso_weekday)
     FROM data.schedule_days d WHERE d.revision_id=revision AND d.schedule_id=s.component_id),'[]')))
   ORDER BY s.component_id::text COLLATE "C") FROM data.schedules s WHERE s.revision_id=revision),'[]'));

 -- Shared calendars each schedule follows, with the exceptions they apply.
 result:=result||jsonb_build_object('calendar_links',COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'schedule_id',l.schedule_id,'calendar_id',l.calendar_id,'effects',COALESCE((SELECT jsonb_agg(jsonb_build_object(
     'component_id',f.component_id,'event_version_id',f.event_version_id,'kind',f.effect_kind,
     'evidence',supported->(f.value_decision_id::text),'intervals',COALESCE((SELECT jsonb_agg(jsonb_build_object(
       'component_id',x.component_id,'opens',editorial.clock(x.opens_at),'closes',editorial.clock(x.closes_at),
       'end_day_offset',x.end_day_offset,'evidence',supported->(x.value_decision_id::text)) ORDER BY x.opens_at,x.closes_at)
       FROM data.exception_intervals x WHERE x.revision_id=revision AND x.effect_id=f.component_id),'[]'))
     ORDER BY f.component_id) FROM data.schedule_exception_effects f
     WHERE f.revision_id=revision AND f.schedule_id=l.schedule_id AND f.calendar_id=l.calendar_id),'[]'))
   ORDER BY l.schedule_id,l.calendar_id) FROM data.schedule_calendar_links l WHERE l.revision_id=revision),'[]'));

 IF kind='organization' THEN result:=result-'schedules'-'calendar_links'; END IF;

 -- Evidence per scalar field. An explicit empty list: save_revision must not borrow the
 -- record's evidence for a moderator's value.
 SELECT COALESCE(jsonb_object_agg(key,COALESCE(by_field->key,'[]')),'{}') INTO evidence
  FROM jsonb_each(result) WHERE jsonb_typeof(value) NOT IN ('array','object');
 FOREACH field IN ARRAY ARRAY['record','coordinates','territories'] LOOP
  IF by_field ? field THEN evidence:=evidence||jsonb_build_object(field,by_field->field); END IF;
 END LOOP;
 IF NOT evidence ? 'record' THEN
  evidence:=evidence||jsonb_build_object('record',COALESCE(by_field->(CASE kind WHEN 'service' THEN 'delivery_mode' WHEN 'organization' THEN 'name' ELSE 'location_kind' END),'[]'));
 END IF;
 RETURN result||jsonb_build_object('evidence',evidence);
END $$;

CREATE OR REPLACE FUNCTION editorial.materialize_community_locator(s editorial.community_snapshots,locator uuid) RETURNS uuid
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
 kind:=CASE WHEN path[1]='source_facts' AND s.values#>>ARRAY['source_facts',path[2],'kind']='organization_name' THEN 'organization'
  WHEN path[1]='location' THEN 'location' ELSE 'service' END;
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

CREATE OR REPLACE FUNCTION editorial.accept_community_item(contribution uuid,decision jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE actor uuid:=preparation.actor(); s editorial.community_snapshots; c editorial.contributions;
 previous editorial.contributions; resolved editorial.community_resolutions; digest text:=preparation.digest(decision);
 service uuid; work uuid; public_head uuid; baseline jsonb:='{}'; body jsonb; operation jsonb; patch jsonb;
 selected uuid[]:=ARRAY[]::uuid[]; evidence_id jsonb; location jsonb; locbody jsonb; locold jsonb:='{}'; locid uuid; locrev uuid; locwork uuid; locpublic uuid;
 fact_result jsonb; revision uuid; loc_selected uuid[]; observations jsonb; result jsonb; place jsonb; is_new boolean;
BEGIN
 IF key IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='request_key_required'; END IF;
 PERFORM preparation.closed(decision,ARRAY['schema_version','expected_service_work','expected_service_public','service_operations','location','reason','observations','fact_actions'],
  ARRAY['schema_version','expected_service_work','expected_service_public','service_operations','location','reason','observations']);
 IF decision->'schema_version' NOT IN ('1'::jsonb,'2'::jsonb) OR (decision->'schema_version'='1'::jsonb AND decision ? 'fact_actions') OR (decision->'schema_version'='2'::jsonb AND jsonb_typeof(decision->'fact_actions') IS DISTINCT FROM 'array') OR jsonb_typeof(decision->'reason') IS DISTINCT FROM 'string' OR COALESCE(btrim(decision->>'reason'),'')='' OR
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
 fact_result:=editorial.apply_community_facts(s,decision,body);
 body:=fact_result->'body'; observations:=(fact_result->'observations')||observations;
 location:=COALESCE(fact_result->'location',decision->'location');
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
REVOKE ALL ON FUNCTION editorial.apply_community_facts(editorial.community_snapshots,jsonb,jsonb) FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
COMMIT;
