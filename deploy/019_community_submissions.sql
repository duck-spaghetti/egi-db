-- Deploy egi_database:019_community_submissions
-- requires: 018_preparation_candidates
-- EGI-105: attributable selective snapshots, independent of private trash lifetime.
BEGIN;
ALTER TABLE editorial.contributions DROP CONSTRAINT contributions_author_kind_check,
 ADD CONSTRAINT contributions_author_kind_check CHECK(author_kind IN ('visitor','reviewer','sync','community')),
 DROP CONSTRAINT contributions_check2,
 ADD CONSTRAINT contributions_public_target CHECK((service_id IS NULL)=(public_revision_id IS NULL) OR
  (author_kind='community' AND service_id IS NOT NULL AND public_revision_id IS NULL));
CREATE TABLE editorial.community_snapshots (
 contribution_id uuid PRIMARY KEY REFERENCES editorial.contributions,
 submitted_by uuid NOT NULL REFERENCES governance.actors,
 preparation_id uuid NOT NULL,
 item_id uuid NOT NULL,
 item_version_id uuid NOT NULL UNIQUE,
 source_id uuid NOT NULL REFERENCES sources.registry,
 submission_key uuid NOT NULL,
 parent_contribution_id uuid REFERENCES editorial.community_snapshots,
 values jsonb NOT NULL,
 evidence jsonb NOT NULL,
 source_metadata jsonb NOT NULL,
 submitted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX community_snapshots_item ON editorial.community_snapshots(item_id,submitted_at,contribution_id);
CREATE TRIGGER snapshots_immutable BEFORE UPDATE OR DELETE ON editorial.community_snapshots
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();

-- Replaced by the canonical acceptance provider once resolutions exist.
CREATE FUNCTION editorial.community_identity(parent uuid) RETURNS uuid
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$ SELECT NULL::uuid $$;
CREATE FUNCTION editorial.authorize_community_closure(contribution uuid,outcome text,publication uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF outcome='published' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_acceptance_required'; END IF;
END $$;

CREATE FUNCTION preparation.validate_references(payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE pair jsonb; field text; table_name regclass; column_name text; exists_value boolean; value uuid; territory jsonb; domain text[]; obj jsonb; opens time; closes time; offset_days integer;
BEGIN
 FOR pair IN SELECT jsonb_path_query(jsonb_build_object('service',payload->'service','location',payload->'location'),
  '$.** ? (@.type() == "object").keyvalue()') LOOP
  field:=pair->>'key'; table_name:=NULL; column_name:='entity_id';
  domain:=CASE field WHEN 'delivery_mode' THEN ARRAY['in_person','telephone','online','itinerant']
   WHEN 'operational_status' THEN ARRAY['active','inactive','temporarily_closed','defunct','unknown']
   WHEN 'cost_state' THEN ARRAY['free','paid','variable','unknown'] WHEN 'channel_type' THEN ARRAY['phone','email','web','whatsapp','other']
   WHEN 'condition_kind' THEN ARRAY['appointment','referral','document','eligibility','other']
   WHEN 'requirement_state' THEN ARRAY['required','not_required','conditional','unknown']
   WHEN 'normalization_state' THEN ARRAY['raw','normalized','uncertain'] WHEN 'coordinate_state' THEN ARRAY['known','unknown','uncertain']
   WHEN 'availability_kind' THEN ARRAY['spoken','interpreted'] WHEN 'scope' THEN ARRAY['service','intake','contact']
   WHEN 'completeness' THEN ARRAY['complete','partial','unknown'] WHEN 'state' THEN ARRAY['intervals','closed','unknown'] END;
  IF domain IS NOT NULL AND NOT (pair->>'value')=ANY(domain) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_vocabulary',DETAIL=field; END IF;
  IF (CASE field WHEN 'weekday' THEN (pair->>'value')::integer NOT BETWEEN 1 AND 7
   WHEN 'end_day_offset' THEN (pair->>'value')::integer NOT IN (0,1)
   WHEN 'latitude' THEN (pair->>'value')::numeric NOT BETWEEN -90 AND 90
   WHEN 'longitude' THEN (pair->>'value')::numeric NOT BETWEEN -180 AND 180 ELSE false END) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_value',DETAIL=field; END IF;
  IF field IN ('opens','closes') THEN
   IF (pair->>'value')::time>='24:00'::time THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_value',DETAIL=field; END IF;
  END IF;
  CASE field
   WHEN 'organization_id' THEN table_name:='data.organizations'::regclass;
   WHEN 'location_id' THEN table_name:='data.locations'::regclass;
   WHEN 'parent_location_id' THEN table_name:='data.locations'::regclass;
   WHEN 'territory_id' THEN table_name:='geo.territories'::regclass;
   WHEN 'target_entity_id' THEN table_name:='data.entities'::regclass;
   WHEN 'target_contact_component_id' THEN table_name:='data.components'::regclass; column_name:='component_id';
   WHEN 'calendar_id' THEN table_name:='governance.exception_calendars'::regclass; column_name:='calendar_id';
   WHEN 'event_version_id' THEN table_name:='governance.calendar_event_versions'::regclass; column_name:='revision_id';
   WHEN 'adoption_id' THEN table_name:='taxonomy.territory_adoptions'::regclass; column_name:='adoption_id';
   WHEN 'term_id' THEN table_name:='taxonomy.terms'::regclass;
   WHEN 'selected_geocoding_result_id' THEN table_name:='geo.geocoding_results'::regclass; column_name:='result_id';
   ELSE NULL;
  END CASE;
  IF table_name IS NOT NULL THEN
   value:=(pair->>'value')::uuid;
   EXECUTE format('SELECT EXISTS(SELECT FROM %s WHERE %I=$1)',table_name,column_name) INTO exists_value USING value;
   IF NOT exists_value THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unresolved_preparation_reference',DETAIL=field; END IF;
  END IF;
 END LOOP;
 FOR territory IN SELECT jsonb_path_query(payload,'$.service.territories[*]') UNION ALL
  SELECT jsonb_path_query(payload,'$.location.body.territories[*]') LOOP
  IF NOT EXISTS(SELECT FROM geo.territories WHERE entity_id=(territory#>>'{}')::uuid) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unresolved_preparation_reference',DETAIL='territories'; END IF;
 END LOOP;
 FOR obj IN SELECT jsonb_path_query(jsonb_build_object('service',payload->'service','location',payload->'location'),
  '$.** ? (@.type() == "object")') LOOP
  IF obj ?& ARRAY['target_entity_id','target_contact_component_id'] AND NOT EXISTS(
   SELECT FROM data.components WHERE component_id=(obj->>'target_contact_component_id')::uuid
    AND owner_entity_id=(obj->>'target_entity_id')::uuid AND component_kind='contact') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contact_reference_conflict'; END IF;
  IF obj ?& ARRAY['adoption_id','term_id'] AND NOT EXISTS(SELECT FROM taxonomy.territory_adoptions a
   JOIN taxonomy.release_terms t ON t.release_id=a.release_id AND t.term_id=(obj->>'term_id')::uuid
   WHERE a.adoption_id=(obj->>'adoption_id')::uuid) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='classification_reference_conflict'; END IF;
  IF obj ?& ARRAY['opens','closes'] THEN
   opens:=(obj->>'opens')::time; closes:=(obj->>'closes')::time; offset_days:=COALESCE((obj->>'end_day_offset')::integer,0);
   IF NOT ((offset_days=0 AND closes>opens) OR (offset_days=1 AND closes<=opens)) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_interval'; END IF;
  END IF;
  IF obj->>'state' IN ('closed','unknown') AND jsonb_array_length(COALESCE(obj->'intervals','[]'))>0 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_day'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(COALESCE(payload#>'{location,body,schedules}','[]')) s
  WHERE s ? 'scope' AND s->>'scope'<>'contact') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_location_schedule_scope'; END IF;
 IF payload#>>'{service,place,location_id}' IS NOT NULL AND
  (payload#>>'{location,kind}'<>'existing' OR payload#>>'{service,place,location_id}' IS DISTINCT FROM payload#>>'{location,location_id}') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='location_selection_conflict'; END IF;
END $$;
CREATE FUNCTION editorial.community_diagnostics(proposed jsonb,evidence jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb:='[]'; field text;
BEGIN
 FOREACH field IN ARRAY ARRAY['delivery_mode','description'] LOOP
  IF COALESCE(btrim(proposed#>>ARRAY['service',field]),'')='' THEN
   result:=result||jsonb_build_array(jsonb_build_object('code','missing_value','path','/service/'||field)); END IF;
 END LOOP;
 IF jsonb_array_length(evidence)=0 THEN result:=result||jsonb_build_array(jsonb_build_object('code','missing_value','path','/evidence')); END IF;
 RETURN result;
END $$;

CREATE FUNCTION preparation.submit_item(id uuid,item uuid,expected uuid,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); i preparation.items; v preparation.item_versions;
 previous editorial.community_snapshots; existing editorial.community_snapshots; contribution uuid; target uuid; published uuid; working uuid;
 body jsonb:=jsonb_build_object('item',item,'expected',expected); r jsonb; snapshot_values jsonb; metadata jsonb; kind text;
BEGIN
 r:=preparation.replay(id,'submit_item',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT * INTO i FROM preparation.items WHERE items.id=item AND workspace_id=id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
 SELECT * INTO existing FROM editorial.community_snapshots WHERE item_id=item AND item_version_id=expected AND preparation_id=id;
 IF FOUND THEN
  r:=jsonb_build_object('status','already_submitted','contribution_id',existing.contribution_id,'submitted_by',existing.submitted_by,'item_id',item,'version_id',expected);
  RETURN preparation.receipt(id,'submit_item',body,key,r);
 END IF;
 IF i.current_version_id IS DISTINCT FROM expected THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='item_version_conflict'; END IF;
 SELECT * INTO v FROM preparation.item_versions WHERE item_versions.id=expected AND item_id=item;
 IF v.outcome<>'confirmed' OR i.trashed_at IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='item_not_confirmed'; END IF;
 PERFORM preparation.validate_payload(id,v.payload);
 PERFORM preparation.validate_references(v.payload);
 IF COALESCE(btrim(v.payload#>>'{service,name}'),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='service_name_required'; END IF;
 SELECT * INTO previous FROM editorial.community_snapshots WHERE item_id=item AND preparation_id=id ORDER BY submitted_at DESC,contribution_id DESC LIMIT 1;
 target:=CASE WHEN v.payload#>>'{target,kind}'='existing' THEN (v.payload#>>'{target,service_id}')::uuid ELSE editorial.community_identity(previous.contribution_id) END;
 IF previous.contribution_id IS NOT NULL AND previous.values#>>'{target,kind}'='existing' AND
  (target IS NULL OR target IS DISTINCT FROM (previous.values#>>'{target,service_id}')::uuid) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='item_identity_conflict'; END IF;
 snapshot_values:=v.payload-'evidence';
 IF target IS NOT NULL THEN
  IF v.payload#>>'{target,kind}'='existing' THEN
   working:=(v.payload#>>'{target,expected_work}')::uuid; published:=(v.payload#>>'{target,expected_public}')::uuid;
  ELSE
   SELECT revision_id INTO working FROM governance.working_heads WHERE entity_id=target;
   SELECT revision_id INTO published FROM governance.published_heads WHERE entity_id=target;
   snapshot_values:=jsonb_set(snapshot_values,'{target}',jsonb_build_object('kind','existing','service_id',target,'expected_work',working,'expected_public',published));
  END IF;
  IF working IS NULL OR NOT EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=working AND entity_id=target) OR
   (published IS NOT NULL AND NOT EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=published AND entity_id=target)) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_target'; END IF;
  kind:='report';
 ELSE kind:='new_service'; END IF;
 SELECT to_jsonb(s) INTO metadata FROM sources.registry s WHERE source_id=w.source_id;
 INSERT INTO editorial.contributions(kind,category,service_id,public_revision_id,author_kind)
  VALUES(kind,CASE WHEN kind='report' THEN 'other' END,target,published,'community') RETURNING contribution_id INTO contribution;
 -- Selective evidence is the operator-visible current card's locators/quotes;
 -- never copy original_bytes, sibling cards, jobs, history or an artifact URI.
 INSERT INTO editorial.community_snapshots(contribution_id,submitted_by,preparation_id,item_id,item_version_id,source_id,submission_key,
  parent_contribution_id,values,evidence,source_metadata)
  VALUES(contribution,preparation.actor(),id,item,expected,w.source_id,key,previous.contribution_id,snapshot_values,v.evidence,metadata);
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(contribution,preparation.actor(),'submitted',jsonb_build_object('kind',kind,'source_id',w.source_id));
 r:=jsonb_build_object('status','submitted','contribution_id',contribution,'submitted_by',preparation.actor(),'item_id',item,'version_id',expected,
  'diagnostics',editorial.community_diagnostics(snapshot_values,v.evidence));
 RETURN preparation.receipt(id,'submit_item',body,key,r);
END $$;
CREATE FUNCTION editorial.read_community_snapshot(contribution uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=preparation.actor(); s editorial.community_snapshots;
BEGIN
 SELECT * INTO s FROM editorial.community_snapshots WHERE contribution_id=contribution;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 RETURN jsonb_build_object('snapshot',to_jsonb(s),'diagnostics',editorial.community_diagnostics(s.values,s.evidence),
  'resolved_service_id',editorial.community_identity(s.contribution_id));
END $$;

-- Preserve the public intake limits independently of authenticated submissions.
CREATE OR REPLACE FUNCTION editorial.submit_contribution(kind text,service uuid,category text,message text,contact text,
 contact_consent boolean,proposals jsonb,trap text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE settings editorial.intake_settings; revision uuid; result uuid; item jsonb;
BEGIN
 -- One intake at a time, so the global counts are exact.
 PERFORM pg_advisory_xact_lock(1162303812,2);
 SELECT * INTO settings FROM editorial.intake_settings;
 IF NOT settings.open THEN RETURN 'closed'; END IF;
 IF COALESCE(btrim(trap),'')<>'' THEN RETURN 'trapped'; END IF;
 IF (SELECT count(*) FROM editorial.contributions c WHERE c.author_kind<>'community' AND c.created_at>clock_timestamp()-settings.window_length)>=settings.window_limit
  OR (SELECT count(*) FROM editorial.contributions c WHERE c.author_kind<>'community' AND c.created_at>clock_timestamp()-interval '1 day')>=settings.daily_limit THEN
  RETURN 'limited';
 END IF;
 IF contact IS NOT NULL AND NOT COALESCE(contact_consent,false) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contact_requires_consent';
 END IF;
 proposals:=COALESCE(proposals,'[]'::jsonb);
 IF jsonb_typeof(proposals)<>'array' OR jsonb_array_length(proposals)>10
  OR EXISTS(SELECT FROM jsonb_array_elements(proposals) p WHERE jsonb_typeof(p)<>'object'
   OR jsonb_typeof(p->'field')<>'string' OR jsonb_typeof(p->'value')<>'string'
   OR char_length(p->>'value') NOT BETWEEN 1 AND 1000) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='proposals_invalid';
 END IF;
 IF kind='new_service' THEN
  IF service IS NOT NULL OR category IS NOT NULL
   OR NOT EXISTS(SELECT FROM jsonb_array_elements(proposals) p WHERE p->>'field'='name') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='new_service_requires_name';
  END IF;
 ELSIF kind IN ('report','still_valid') THEN
  SELECT h.revision_id INTO revision FROM governance.published_heads h
   JOIN data.services s ON s.entity_id=h.entity_id WHERE h.entity_id=service;
  IF revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='service_not_public'; END IF;
  IF kind='still_valid' AND (category IS NOT NULL OR message IS NOT NULL OR jsonb_array_length(proposals)>0) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='still_valid_carries_nothing';
  END IF;
 ELSE
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contribution_kind_invalid';
 END IF;
 INSERT INTO editorial.contributions(kind,category,service_id,public_revision_id,text,contact)
  VALUES(kind,category,service,revision,NULLIF(btrim(message),''),NULLIF(btrim(contact),''))
  RETURNING contribution_id INTO result;
 FOR item IN SELECT * FROM jsonb_array_elements(proposals) LOOP
  INSERT INTO editorial.proposals(contribution_id,field,value) VALUES(result,item->>'field',item->'value');
 END LOOP;
 INSERT INTO editorial.events(contribution_id,action,details)
  VALUES(result,'submitted',jsonb_build_object('kind',kind,'proposals',jsonb_array_length(proposals)));
 RETURN 'stored';
END $$;

CREATE OR REPLACE FUNCTION editorial.close_contribution(contribution uuid,outcome text,reason text DEFAULT NULL,publication uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE me uuid:=governance.current_actor(); c editorial.contributions:=editorial.locked(contribution); published uuid;
BEGIN
 IF c.author_kind='community' THEN PERFORM editorial.authorize_community_closure(contribution,outcome,publication); END IF;
 IF outcome NOT IN ('published','no_change','rejected','duplicate') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='outcome_invalid';
 END IF;
 IF outcome='published' THEN
  SELECT p.entity_id INTO published FROM governance.publications p JOIN data.services s ON s.entity_id=p.entity_id
   WHERE p.publication_id=publication;
  IF published IS NULL OR (c.service_id IS NOT NULL AND published<>c.service_id) THEN
   RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='publication_required';
  END IF;
 ELSIF COALESCE(btrim(reason),'')='' OR publication IS NOT NULL THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reason_required';
 END IF;
 UPDATE editorial.proposals SET decision='rejected',decision_note='closed: '||outcome,decided_by=me,decided_at=clock_timestamp()
  WHERE contribution_id=contribution AND decision IS NULL;
 UPDATE editorial.contributions SET state='closed',waiting_reason=NULL,outcome=close_contribution.outcome,
  outcome_reason=NULLIF(btrim(reason),''),publication_id=publication,closed_by=me,closed_at=clock_timestamp()
  WHERE contribution_id=contribution;
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(contribution,me,'closed',jsonb_build_object('outcome',outcome,'publication_id',publication));
END $$;


REVOKE ALL ON TABLE editorial.community_snapshots FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
REVOKE ALL ON FUNCTION editorial.community_identity(uuid),editorial.authorize_community_closure(uuid,text,uuid),
 preparation.validate_references(jsonb),editorial.community_diagnostics(jsonb,jsonb),
 preparation.submit_item(uuid,uuid,uuid,uuid),editorial.read_community_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.submit_item(uuid,uuid,uuid,uuid),editorial.read_community_snapshot(uuid) TO egi_editorial;
COMMIT;
