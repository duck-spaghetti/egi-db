-- Deploy egi_database:publication [canonical] to pg
BEGIN;
CREATE TABLE governance.actor_grants (
 grant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL REFERENCES governance.actors,
 capability text NOT NULL CHECK(capability IN ('propose','approve','publish','verify')),
 territory_id uuid REFERENCES geo.territories, valid_from timestamptz NOT NULL DEFAULT '-infinity',
 valid_until timestamptz, CHECK(valid_until IS NULL OR valid_until>valid_from),
 UNIQUE NULLS NOT DISTINCT(actor_id,capability,territory_id)
);
CREATE TABLE governance.revision_territories (
 revision_id uuid NOT NULL, entity_id uuid NOT NULL, territory_id uuid NOT NULL REFERENCES geo.territories,
 PRIMARY KEY(revision_id,territory_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE TABLE governance.submissions (
 submission_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity_id uuid NOT NULL,
 proposed_revision_id uuid NOT NULL UNIQUE, base_public_revision_id uuid,
 actor_id uuid NOT NULL REFERENCES governance.actors, submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(proposed_revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(base_public_revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 UNIQUE(submission_id,proposed_revision_id)
);
CREATE TABLE governance.review_decisions (
 decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), decision_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE, submission_id uuid NOT NULL REFERENCES governance.submissions,
 target_revision_id uuid NOT NULL REFERENCES governance.entity_revisions,
 outcome text NOT NULL CHECK(outcome IN ('approved','needs_changes','rejected')),
 actor_id uuid NOT NULL REFERENCES governance.actors, decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 reason text NOT NULL CHECK(btrim(reason)<>''), UNIQUE(decision_id,target_revision_id,outcome),
 FOREIGN KEY(submission_id,target_revision_id) REFERENCES governance.submissions(submission_id,proposed_revision_id)
);
CREATE TABLE governance.publications (
 publication_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity_id uuid NOT NULL, revision_id uuid NOT NULL,
 review_decision_id uuid NOT NULL, review_outcome text NOT NULL DEFAULT 'approved' CHECK(review_outcome='approved'),
 actor_id uuid NOT NULL REFERENCES governance.actors, published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 previous_publication_id uuid, UNIQUE(publication_id,entity_id,revision_id), UNIQUE(publication_id,entity_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(review_decision_id,revision_id,review_outcome) REFERENCES governance.review_decisions(decision_id,target_revision_id,outcome),
 FOREIGN KEY(previous_publication_id,entity_id) REFERENCES governance.publications(publication_id,entity_id)
);
CREATE TABLE governance.published_heads (
 entity_id uuid PRIMARY KEY REFERENCES data.entities, revision_id uuid NOT NULL, publication_id uuid NOT NULL,
 FOREIGN KEY(publication_id,entity_id,revision_id) REFERENCES governance.publications(publication_id,entity_id,revision_id)
);
CREATE TABLE governance.verifications (
 verification_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity_id uuid NOT NULL, revision_id uuid NOT NULL,
 scope_kind text NOT NULL CHECK(scope_kind IN ('page','field','component')),
 field_code text, component_id uuid, actor_id uuid NOT NULL REFERENCES governance.actors,
 checked_at timestamptz NOT NULL, method text NOT NULL, evidence_ref text NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('confirmed','uncertain','incorrect')),
 CHECK((scope_kind='page' AND field_code IS NULL AND component_id IS NULL) OR
 (scope_kind='field' AND field_code IS NOT NULL AND component_id IS NULL) OR
 (scope_kind='component' AND component_id IS NOT NULL AND field_code IS NULL)),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id) REFERENCES data.components(component_id,owner_entity_id)
);
CREATE TABLE audit.public_changes (
 change_sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 entity_id uuid NOT NULL REFERENCES data.entities, publication_id uuid NOT NULL REFERENCES governance.publications,
 resource_kind text NOT NULL, changed_at timestamptz NOT NULL DEFAULT clock_timestamp(), reason text NOT NULL
);
CREATE FUNCTION governance.affected_territories(target_entity uuid, target_revision uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT territory_id FROM governance.revision_territories WHERE revision_id=target_revision
 UNION SELECT rt.territory_id FROM governance.working_heads wh JOIN governance.revision_territories rt ON rt.revision_id=wh.revision_id WHERE wh.entity_id=target_entity
 UNION SELECT rt.territory_id FROM governance.published_heads h JOIN governance.revision_territories rt ON rt.revision_id=h.revision_id WHERE h.entity_id=target_entity
 UNION SELECT m.territory_id FROM governance.published_heads h JOIN geo.service_memberships m ON m.revision_id=h.revision_id
 WHERE EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=target_entity)
 OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=target_entity)
 OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=target_entity)
$$;
CREATE FUNCTION governance.require_capability(cap text, territories uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=governance.current_actor(); territory uuid;
BEGIN
 IF EXISTS(SELECT FROM governance.actor_grants g WHERE g.actor_id=actor AND g.capability=cap AND g.territory_id IS NULL AND clock_timestamp()>=g.valid_from AND (g.valid_until IS NULL OR clock_timestamp()<g.valid_until)) THEN RETURN; END IF;
 IF COALESCE(cardinality(territories),0)=0 THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='global_scope_required'; END IF;
 FOREACH territory IN ARRAY territories LOOP
  IF NOT EXISTS(SELECT FROM governance.actor_grants g WHERE g.actor_id=actor AND g.capability=cap AND g.territory_id=territory AND clock_timestamp()>=g.valid_from AND (g.valid_until IS NULL OR clock_timestamp()<g.valid_until)) THEN
   RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='territory_permission_denied';
  END IF;
 END LOOP;
END $$;
CREATE FUNCTION governance.lock_expected(entity uuid, expected_work uuid, expected_public uuid, check_work boolean DEFAULT true) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE actual_work uuid; actual_public uuid;
BEGIN
 -- Serialize controlled edits/publications to keep shared-resource scope checks stable.
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='write_requires_read_committed'; END IF;
 PERFORM pg_advisory_xact_lock(1162303812,1);
 PERFORM 1 FROM data.entities WHERE entity_id=entity FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='unknown_entity'; END IF;
 SELECT revision_id INTO actual_work FROM governance.working_heads WHERE entity_id=entity;
 SELECT revision_id INTO actual_public FROM governance.published_heads WHERE entity_id=entity;
 IF (check_work AND actual_work IS DISTINCT FROM expected_work) OR actual_public IS DISTINCT FROM expected_public THEN
  RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='stale_base';
 END IF;
END $$;
CREATE FUNCTION governance.bind_original(rev uuid, owner uuid, field text, text_value text, language text, component uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE content uuid;
BEGIN
 IF text_value IS NULL THEN RETURN NULL; END IF;
 SELECT content_id INTO content FROM i18n.content_units WHERE owner_entity_id=owner AND field_code=field AND component_id IS NOT DISTINCT FROM component AND original_text=text_value AND original_language IS NOT DISTINCT FROM language ORDER BY content_id LIMIT 1;
 IF content IS NULL THEN
  INSERT INTO i18n.content_units(owner_entity_id,introduced_revision_id,field_code,component_id,original_language,original_text) VALUES(owner,rev,field,component,language,text_value) RETURNING content_id INTO content;
 END IF;
 INSERT INTO i18n.revision_content_links(revision_id,entity_id,field_code,component_scope,content_id) VALUES(rev,owner,field,COALESCE(component,'00000000-0000-0000-0000-000000000000'::uuid),content);
 RETURN content;
END $$;
CREATE FUNCTION governance.owned_component(owner uuid, kind text, wanted uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE result uuid:=COALESCE(wanted,gen_random_uuid());
BEGIN
 IF EXISTS(SELECT FROM data.components WHERE component_id=result) THEN
  IF NOT EXISTS(SELECT FROM data.components WHERE component_id=result AND owner_entity_id=owner AND component_kind=kind) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='component_owner_or_kind_mismatch'; END IF;
 ELSE INSERT INTO data.components(component_id,owner_entity_id,component_kind) VALUES(result,owner,kind); END IF;
 RETURN result;
END $$;
CREATE FUNCTION governance.select_value(rev uuid, owner uuid, field text, component uuid, evidence jsonb, note text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE decision uuid; item jsonb;
BEGIN
 INSERT INTO governance.value_decisions(revision_id,entity_id,field_code,component_id,selection_kind,actor_id,reason)
 VALUES(rev,owner,field,component,'select',governance.current_actor(),note) RETURNING value_decision_id INTO decision;
 FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(evidence,'[]'::jsonb)) LOOP
  INSERT INTO governance.value_evidence(value_decision_id,assertion_id,evidence_role) VALUES(decision,(item->>'assertion_id')::uuid,COALESCE(item->>'role','supporting'));
 END LOOP;
 RETURN decision;
END $$;
CREATE FUNCTION governance.save_revision(kind text, entity uuid, expected_work uuid, expected_public uuid, body jsonb, note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner uuid:=COALESCE(entity,gen_random_uuid()); rev uuid; actor uuid:=governance.current_actor();
 scopes uuid[]; item jsonb; component uuid; decision uuid; name_unit uuid; description_unit uuid;
 field text; allowed text[]; evidence jsonb:=COALESCE(body->'evidence'->'record','[]'::jsonb); n bigint;
BEGIN
 IF kind NOT IN ('service','organization','location','territory') THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='unsupported_entity_kind'; END IF;
 IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='body_must_be_object'; END IF;
 allowed:=ARRAY['name','original_language','contacts','territories','evidence']||CASE kind
 WHEN 'service' THEN ARRAY['description','delivery_mode','operational_status','cost_state','cost_note','valid_from','valid_until','closure_date','closure_reason','place','organizations','conditions','contact_links','languages','coverage']
 WHEN 'location' THEN ARRAY['location_kind','latitude','longitude','coordinate_state','selected_geocoding_result_id','parent_location_id','addresses','organizations']
 WHEN 'organization' THEN ARRAY['description','organization_type','website']
 ELSE ARRAY['code','timezone_name','country_code','boundary_wkt'] END;
 IF EXISTS(SELECT FROM jsonb_object_keys(body) k WHERE NOT k=ANY(allowed)) THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='unsupported_body_field'; END IF;
 FOREACH field IN ARRAY ARRAY['name','description','original_language','cost_note','closure_reason','website','organization_type','location_kind'] LOOP
  IF body ? field AND jsonb_typeof(body->field) NOT IN ('string','null') THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='text_field_requires_string'; END IF;
 END LOOP;

 SELECT COALESCE(array_agg(x::uuid),ARRAY[]::uuid[]) INTO scopes FROM jsonb_array_elements_text(COALESCE(body->'territories','[]')) x;
 IF kind='territory' THEN scopes:=array_append(scopes,owner); END IF;
 IF entity IS NULL THEN
  PERFORM governance.require_capability('propose',scopes);
  INSERT INTO data.entities(entity_id,entity_kind) VALUES(owner,kind);
  IF kind='service' THEN INSERT INTO data.services(entity_id) VALUES(owner);
  ELSIF kind='organization' THEN INSERT INTO data.organizations(entity_id) VALUES(owner);
  ELSIF kind='location' THEN INSERT INTO data.locations(entity_id) VALUES(owner);
  ELSE INSERT INTO geo.territories(entity_id,code) VALUES(owner,body->>'code'); END IF;
 END IF;
 PERFORM governance.lock_expected(owner,expected_work,expected_public);
 IF NOT EXISTS(SELECT FROM data.entities WHERE entity_id=owner AND entity_kind=kind) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='entity_kind_mismatch'; END IF;
 SELECT COALESCE(max(revision_number),0)+1 INTO n FROM governance.entity_revisions WHERE entity_id=owner;
 INSERT INTO governance.entity_revisions(entity_id,entity_kind,revision_number,parent_revision_id,actor_id,reason) VALUES(owner,kind,n,expected_work,actor,note) RETURNING revision_id INTO rev;
 INSERT INTO governance.revision_territories SELECT rev,owner,t FROM unnest(scopes) t;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(owner,rev) t;
 PERFORM governance.require_capability('propose',scopes);
 name_unit:=governance.bind_original(rev,owner,'name',body->>'name',body->>'original_language');
 description_unit:=governance.bind_original(rev,owner,'description',body->>'description',body->>'original_language');
 FOR field IN SELECT key FROM jsonb_each(body) WHERE key NOT IN ('evidence','territories','contacts','contact_links','conditions','organizations','place','addresses','languages','coverage') LOOP
  decision:=governance.select_value(rev,owner,field,NULL,COALESCE(body->'evidence'->field,evidence),note);
 END LOOP;
 IF kind='service' THEN
  INSERT INTO data.service_revisions(revision_id,entity_id,name_content_id,description_content_id,delivery_mode,operational_status,cost_state,cost_note_content_id,valid_from,valid_until,closure_date,closure_reason_content_id)
  VALUES(rev,owner,name_unit,description_unit,body->>'delivery_mode',COALESCE(body->>'operational_status','unknown'),COALESCE(body->>'cost_state','unknown'),governance.bind_original(rev,owner,'cost_note',body->>'cost_note',body->>'original_language'),(body->>'valid_from')::date,(body->>'valid_until')::date,(body->>'closure_date')::date,governance.bind_original(rev,owner,'closure_reason',body->>'closure_reason',body->>'original_language'));
 ELSIF kind='organization' THEN
  INSERT INTO data.organization_revisions(revision_id,entity_id,name_content_id,description_content_id,organization_type,website) VALUES(rev,owner,name_unit,description_unit,body->>'organization_type',body->>'website');
 ELSIF kind='location' THEN
  decision:=governance.select_value(rev,owner,'coordinates',NULL,COALESCE(body->'evidence'->'coordinates',evidence),note);
  INSERT INTO data.location_revisions(revision_id,entity_id,name_content_id,location_kind,latitude,longitude,coordinate_state,coordinate_decision_id,selected_geocoding_result_id,parent_location_id)
  VALUES(rev,owner,name_unit,body->>'location_kind',(body->>'latitude')::double precision,(body->>'longitude')::double precision,COALESCE(body->>'coordinate_state','unknown'),decision,(body->>'selected_geocoding_result_id')::uuid,(body->>'parent_location_id')::uuid);
 ELSE
  IF NOT EXISTS(SELECT FROM pg_timezone_names WHERE name=body->>'timezone_name') THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='unknown_timezone'; END IF;
  INSERT INTO geo.territory_revisions(revision_id,entity_id,name_content_id,timezone_name,country_code,boundary) VALUES(rev,owner,name_unit,body->>'timezone_name',body->>'country_code',CASE WHEN body->>'boundary_wkt' IS NOT NULL THEN public.ST_Multi(public.ST_GeomFromText(body->>'boundary_wkt',4326)) END);
 END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'contacts','[]')) LOOP
  component:=governance.owned_component(owner,'contact',(item->>'component_id')::uuid);
  decision:=governance.select_value(rev,owner,'contact',component,COALESCE(item->'evidence',evidence),note);
  INSERT INTO data.contact_entries(revision_id,entity_id,component_id,channel_type,value,normalized_value,purpose_code,label_content_id,sort_order,is_public,value_decision_id)
  VALUES(rev,owner,component,item->>'channel_type',item->>'value',item->>'normalized_value',item->>'purpose_code',governance.bind_original(rev,owner,'contact_label',item->>'label',body->>'original_language',component),COALESCE((item->>'sort_order')::integer,0),COALESCE((item->>'is_public')::boolean,true),decision);
 END LOOP;
 IF kind='location' THEN
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'addresses','[]')) LOOP
   component:=governance.owned_component(owner,'address',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'address',component,COALESCE(item->'evidence',evidence),note);
   INSERT INTO data.addresses(revision_id,entity_id,component_id,address_kind,formatted,line1,locality,postal_code,administrative_area,country_code,normalization_state,value_decision_id)
   VALUES(rev,owner,component,COALESCE(item->>'address_kind','physical'),item->>'formatted',item->>'line1',item->>'locality',item->>'postal_code',item->>'administrative_area',item->>'country_code',COALESCE(item->>'normalization_state','raw'),decision);
  END LOOP;
 END IF;
 IF kind IN ('location','service') THEN
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'organizations','[]')) LOOP
   component:=governance.owned_component(owner,'organization_role',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'organization_role',component,COALESCE(item->'evidence',evidence),note);
   IF kind='service' THEN INSERT INTO data.service_organizations(revision_id,entity_id,component_id,organization_id,role_code,value_decision_id) VALUES(rev,owner,component,(item->>'organization_id')::uuid,item->>'role_code',decision);
   ELSE INSERT INTO data.location_organizations(revision_id,entity_id,component_id,organization_id,role_code,value_decision_id) VALUES(rev,owner,component,(item->>'organization_id')::uuid,item->>'role_code',decision); END IF;
  END LOOP;
 END IF;
 IF kind='service' THEN
  IF body->'place' IS NOT NULL AND body->'place'<>'null'::jsonb THEN
   item:=body->'place';component:=governance.owned_component(owner,'place',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'place',component,COALESCE(item->'evidence',evidence),note);
   INSERT INTO data.service_places(revision_id,entity_id,component_id,location_id,territory_id,area_description_content_id,value_decision_id) VALUES(rev,owner,component,(item->>'location_id')::uuid,(item->>'territory_id')::uuid,governance.bind_original(rev,owner,'area_description',item->>'area_description',body->>'original_language',component),decision);
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'conditions','[]')) LOOP
   component:=governance.owned_component(owner,'condition',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'condition',component,COALESCE(item->'evidence',evidence),note);
   INSERT INTO data.access_conditions(revision_id,entity_id,component_id,condition_kind,requirement_state,details_content_id,value_decision_id) VALUES(rev,owner,component,item->>'condition_kind',item->>'requirement_state',governance.bind_original(rev,owner,'condition_details',item->>'details',body->>'original_language',component),decision);
  END LOOP;
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'contact_links','[]')) LOOP
   component:=governance.owned_component(owner,'contact_link',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'contact_link',component,COALESCE(item->'evidence',evidence),note);
   INSERT INTO data.service_contact_links(revision_id,entity_id,component_id,target_entity_id,target_contact_component_id,purpose_code,label_content_id,value_decision_id) VALUES(rev,owner,component,(item->>'target_entity_id')::uuid,(item->>'target_contact_component_id')::uuid,item->>'purpose_code',governance.bind_original(rev,owner,'contact_link_label',item->>'label',body->>'original_language',component),decision);
  END LOOP;
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'languages','[]')) LOOP
   decision:=governance.select_value(rev,owner,'service_language',NULL,COALESCE(item->'evidence',evidence),note);
   INSERT INTO data.service_languages(revision_id,entity_id,language_code,availability_kind,note_content_id,value_decision_id) VALUES(rev,owner,item->>'language_code',item->>'availability_kind',governance.bind_original(rev,owner,'language_'||(item->>'language_code')||'_'||(item->>'availability_kind'),item->>'note',body->>'original_language'),decision);
  END LOOP;
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'coverage','[]')) LOOP
   component:=governance.owned_component(owner,'coverage',(item->>'component_id')::uuid);
   decision:=governance.select_value(rev,owner,'coverage',component,COALESCE(item->'evidence',evidence),note);
   INSERT INTO geo.service_coverage(revision_id,entity_id,component_id,territory_id,geometry,description_content_id,value_decision_id) VALUES(rev,owner,component,(item->>'territory_id')::uuid,CASE WHEN item->>'geometry_wkt' IS NOT NULL THEN public.ST_Multi(public.ST_GeomFromText(item->>'geometry_wkt',4326)) END,governance.bind_original(rev,owner,'coverage_description',item->>'description',body->>'original_language',component),decision);
  END LOOP;
  FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'territories','[]')) LOOP
   decision:=governance.select_value(rev,owner,'membership',NULL,COALESCE(body->'evidence'->'territories',evidence),note);
   INSERT INTO geo.service_memberships VALUES(rev,owner,(item#>>'{}')::uuid,'explicit editorial selection',decision);
  END LOOP;
 END IF;
 UPDATE governance.entity_revisions SET sealed_at=clock_timestamp() WHERE revision_id=rev;
 INSERT INTO governance.working_heads VALUES(owner,rev) ON CONFLICT(entity_id) DO UPDATE SET revision_id=EXCLUDED.revision_id;
 INSERT INTO governance.submissions(entity_id,proposed_revision_id,base_public_revision_id,actor_id) VALUES(owner,rev,expected_public,actor);
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id) VALUES(actor,'save',owner,rev);
 RETURN rev;
END $$;
ALTER FUNCTION governance.publication_diagnostics(uuid) RENAME TO draft_diagnostics;
CREATE FUNCTION governance.publication_diagnostics(target uuid)
RETURNS TABLE(code text,field text) LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT d.code,d.field FROM governance.draft_diagnostics(target) d
 WHERE d.code<>'missing_channel' OR NOT EXISTS(
 SELECT FROM data.service_revisions s JOIN data.service_contact_links l ON l.revision_id=s.revision_id
 JOIN governance.published_heads h ON h.entity_id=l.target_entity_id JOIN data.contact_entries c ON c.revision_id=h.revision_id AND c.component_id=l.target_contact_component_id
 WHERE s.revision_id=target AND c.is_public AND ((s.delivery_mode='telephone' AND c.channel_type IN ('phone','whatsapp')) OR (s.delivery_mode='online' AND c.channel_type IN ('web','email'))))
 UNION ALL SELECT 'missing_organization_name','name' FROM data.organization_revisions r LEFT JOIN i18n.content_units c ON c.content_id=r.name_content_id WHERE r.revision_id=target AND COALESCE(btrim(c.original_text),'')=''
 UNION ALL SELECT 'missing_area_description','place' FROM data.service_places p JOIN i18n.content_units c ON c.content_id=p.area_description_content_id WHERE p.revision_id=target AND btrim(c.original_text)=''
 UNION ALL SELECT 'unpublished_location','place' FROM data.service_places p WHERE p.revision_id=target AND p.location_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=p.location_id)
 UNION ALL SELECT 'unidentifiable_location','place' FROM data.service_places p JOIN governance.published_heads h ON h.entity_id=p.location_id JOIN data.location_revisions l ON l.revision_id=h.revision_id LEFT JOIN i18n.content_units n ON n.content_id=l.name_content_id WHERE p.revision_id=target AND COALESCE(btrim(n.original_text),'')='' AND NOT EXISTS(SELECT FROM data.addresses a WHERE a.revision_id=l.revision_id)
 UNION ALL SELECT 'unpublished_organization','organizations' FROM data.service_organizations o WHERE o.revision_id=target AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=o.organization_id)
 UNION ALL SELECT 'invalid_shared_contact','contact_links' FROM data.service_contact_links l WHERE l.revision_id=target AND NOT EXISTS(SELECT FROM governance.published_heads h JOIN data.contact_entries c ON c.revision_id=h.revision_id WHERE h.entity_id=l.target_entity_id AND c.component_id=l.target_contact_component_id AND c.is_public)
$$;
CREATE FUNCTION governance.require_publishable(target uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE errors text;
BEGIN
 IF NOT EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=target AND sealed_at IS NOT NULL) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='revision_not_sealed'; END IF;
 SELECT string_agg(code,',' ORDER BY code) INTO errors FROM governance.publication_diagnostics(target);
 IF errors IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='publication_incomplete: '||errors; END IF;
END $$;
CREATE FUNCTION governance.review_revision(target uuid, expected_public uuid, outcome text, note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner uuid; decision uuid; scopes uuid[]; submission governance.submissions;
BEGIN
 SELECT * INTO STRICT submission FROM governance.submissions WHERE proposed_revision_id=target;
 owner:=submission.entity_id;
 PERFORM governance.lock_expected(owner,target,expected_public);
 IF submission.base_public_revision_id IS DISTINCT FROM expected_public THEN RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='stale_submission'; END IF;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(owner,target) t;
 PERFORM governance.require_capability('approve',scopes);
 IF submission.actor_id=governance.current_actor() THEN PERFORM governance.require_capability('propose',scopes); END IF;
 IF outcome='approved' THEN PERFORM governance.require_publishable(target); END IF;
 INSERT INTO governance.review_decisions(submission_id,target_revision_id,outcome,actor_id,reason)
 VALUES(submission.submission_id,target,outcome,governance.current_actor(),note) RETURNING decision_id INTO decision;
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'review',owner,target,jsonb_build_object('decision_id',decision,'outcome',outcome));
 RETURN decision;
END $$;
CREATE FUNCTION governance.publish_revision(target uuid, approved_decision uuid, expected_public uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner uuid; scopes uuid[]; publication uuid; previous uuid; submission governance.submissions; affected uuid;
BEGIN
 SELECT * INTO STRICT submission FROM governance.submissions WHERE proposed_revision_id=target; owner:=submission.entity_id;
 PERFORM governance.lock_expected(owner,target,expected_public);
 IF submission.base_public_revision_id IS DISTINCT FROM expected_public THEN RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='stale_submission'; END IF;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(owner,target) t;
 PERFORM governance.require_capability('publish',scopes);
 PERFORM governance.require_publishable(target);
 IF NOT EXISTS(SELECT FROM governance.review_decisions d WHERE d.decision_id=approved_decision AND d.target_revision_id=target AND d.outcome='approved') THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='exact_approval_required'; END IF;
 IF EXISTS(SELECT FROM governance.review_decisions d WHERE d.target_revision_id=target AND d.decision_sequence>(SELECT decision_sequence FROM governance.review_decisions WHERE decision_id=approved_decision) AND d.outcome<>'approved') THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='approval_superseded'; END IF;
 SELECT publication_id INTO previous FROM governance.published_heads WHERE entity_id=owner;
 INSERT INTO governance.publications(entity_id,revision_id,review_decision_id,actor_id,previous_publication_id) VALUES(owner,target,approved_decision,governance.current_actor(),previous) RETURNING publication_id INTO publication;
 INSERT INTO governance.published_heads VALUES(owner,target,publication) ON CONFLICT(entity_id) DO UPDATE SET revision_id=EXCLUDED.revision_id,publication_id=EXCLUDED.publication_id;
 -- Validate approved consumers against the new shared head before committing it.
 FOR affected IN SELECT h.revision_id FROM governance.published_heads h
 WHERE h.entity_id<>owner AND (EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=owner) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=owner) OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=owner)) LOOP
  PERFORM governance.require_publishable(affected);
 END LOOP;

 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) SELECT owner,publication,entity_kind,'direct_publication' FROM data.entities WHERE entity_id=owner;
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
 SELECT DISTINCT h.entity_id,publication,'service','shared_resource_publication' FROM governance.published_heads h
 WHERE h.entity_id<>owner AND (EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=owner) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=owner) OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=owner));
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'publish',owner,target,jsonb_build_object('publication_id',publication));
 RETURN publication;
END $$;
CREATE FUNCTION governance.restore_revision(source_revision uuid, expected_work uuid, expected_public uuid, note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE original governance.entity_revisions; owner uuid; rev uuid; scopes uuid[];
 d governance.value_decisions; new_decision uuid; decisions jsonb:='{}'; relation text; columns text; expression text;
BEGIN
 SELECT * INTO STRICT original FROM governance.entity_revisions WHERE revision_id=source_revision AND sealed_at IS NOT NULL; owner:=original.entity_id;
 PERFORM governance.lock_expected(owner,expected_work,expected_public);
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(owner,source_revision) t;
 PERFORM governance.require_capability('propose',scopes);
 INSERT INTO governance.entity_revisions(entity_id,entity_kind,revision_number,parent_revision_id,restored_from_revision_id,actor_id,reason)
 SELECT owner,original.entity_kind,max(revision_number)+1,expected_work,source_revision,governance.current_actor(),note FROM governance.entity_revisions WHERE entity_id=owner RETURNING revision_id INTO rev;
 FOR d IN SELECT * FROM governance.value_decisions WHERE revision_id=source_revision LOOP
  INSERT INTO governance.value_decisions(revision_id,entity_id,field_code,component_id,selection_kind,policy_version,actor_id,reason)
  VALUES(rev,owner,d.field_code,d.component_id,d.selection_kind,d.policy_version,governance.current_actor(),note) RETURNING value_decision_id INTO new_decision;
  decisions:=decisions||jsonb_build_object(d.value_decision_id::text,new_decision);
  INSERT INTO governance.value_evidence SELECT new_decision,assertion_id,evidence_role FROM governance.value_evidence WHERE value_decision_id=d.value_decision_id;
 END LOOP;
 INSERT INTO i18n.revision_content_links SELECT rev,entity_id,field_code,component_scope,content_id FROM i18n.revision_content_links WHERE revision_id=source_revision;
 FOREACH relation IN ARRAY ARRAY['governance.revision_territories','geo.territory_revisions','data.organization_revisions','data.location_revisions','data.service_revisions','data.service_places','data.service_organizations','data.location_organizations','data.contact_entries','data.service_contact_links','data.access_conditions','data.addresses','data.service_languages','geo.service_memberships','geo.service_coverage'] LOOP
  SELECT string_agg(quote_ident(a.attname),',' ORDER BY a.attnum),string_agg(CASE WHEN a.attname='revision_id' THEN '$2' WHEN a.attname IN ('value_decision_id','coordinate_decision_id') THEN format('($3->>old.%I::text)::uuid',a.attname) ELSE 'old.'||quote_ident(a.attname) END,',' ORDER BY a.attnum) INTO columns,expression FROM pg_attribute a WHERE a.attrelid=relation::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated='';
  EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM %s old WHERE old.revision_id=$1',relation,columns,expression,relation) USING source_revision,rev,decisions;
 END LOOP;
 UPDATE governance.entity_revisions SET sealed_at=clock_timestamp() WHERE revision_id=rev;
 INSERT INTO governance.working_heads VALUES(owner,rev) ON CONFLICT(entity_id) DO UPDATE SET revision_id=EXCLUDED.revision_id;
 INSERT INTO governance.submissions(entity_id,proposed_revision_id,base_public_revision_id,actor_id) VALUES(owner,rev,expected_public,governance.current_actor());
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'restore',owner,rev,jsonb_build_object('restored_from_revision_id',source_revision));
 RETURN rev;
END $$;
CREATE FUNCTION governance.verify_revision(target uuid, scope text, field text, component uuid, checked timestamptz, method text, evidence text, outcome text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner uuid; scopes uuid[]; verification uuid;
BEGIN
 SELECT entity_id INTO STRICT owner FROM governance.entity_revisions WHERE revision_id=target AND sealed_at IS NOT NULL;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(owner,target) t;
 PERFORM governance.require_capability('verify',scopes);
 IF checked>clock_timestamp() THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='verification_in_future'; END IF;
 IF scope='component' AND NOT EXISTS(SELECT FROM governance.value_decisions WHERE revision_id=target AND component_id=component) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='component_not_in_revision'; END IF;
 IF scope='field' AND NOT EXISTS(SELECT FROM governance.value_decisions WHERE revision_id=target AND field_code=field) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='field_not_in_revision'; END IF;
 INSERT INTO governance.verifications(entity_id,revision_id,scope_kind,field_code,component_id,actor_id,checked_at,method,evidence_ref,outcome)
 VALUES(owner,target,scope,field,component,governance.current_actor(),checked,method,evidence,outcome) RETURNING verification_id INTO verification;
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'verify',owner,target,jsonb_build_object('verification_id',verification));
 RETURN verification;
END $$;
CREATE VIEW api.published_services WITH(security_barrier=true) AS
 SELECT s.entity_id AS service_id,s.revision_id,n.original_text AS name,d.original_text AS description,s.delivery_mode,s.operational_status,s.cost_state,h.publication_id
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id
 LEFT JOIN i18n.content_units n ON n.content_id=s.name_content_id LEFT JOIN i18n.content_units d ON d.content_id=s.description_content_id;
CREATE VIEW api.discoverable_services WITH(security_barrier=true) AS SELECT * FROM api.published_services WHERE operational_status<>'defunct';
CREATE VIEW api.service_contacts WITH(security_barrier=true) AS
 SELECT s.entity_id AS service_id,c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,l.original_text AS label,c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.contact_entries c ON c.revision_id=s.revision_id LEFT JOIN i18n.content_units l ON l.content_id=c.label_content_id WHERE c.is_public
 UNION ALL SELECT s.entity_id,c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(ll.original_text,cl.original_text),c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.service_contact_links link ON link.revision_id=s.revision_id
 JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id
 JOIN data.entities e ON e.entity_id=c.entity_id LEFT JOIN i18n.content_units ll ON ll.content_id=link.label_content_id LEFT JOIN i18n.content_units cl ON cl.content_id=c.label_content_id WHERE c.is_public;
CREATE VIEW api.service_verification WITH(security_barrier=true) AS
 SELECT s.service_id,s.revision_id,v.scope_kind,v.field_code,v.component_id,v.checked_at,v.outcome
 FROM api.published_services s LEFT JOIN governance.verifications v ON v.revision_id=s.revision_id;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['governance.submissions','governance.review_decisions','governance.publications','governance.verifications','governance.revision_territories','audit.public_changes'] LOOP
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
CREATE TRIGGER open_revision BEFORE INSERT ON governance.revision_territories FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision();
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_writer') THEN CREATE ROLE egi_writer NOLOGIN; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_reader') THEN CREATE ROLE egi_reader NOLOGIN; END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA data,governance,audit,sources,geo,i18n,api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance,i18n,sources FROM PUBLIC;
GRANT USAGE ON SCHEMA governance TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.save_revision(text,uuid,uuid,uuid,jsonb,text),governance.review_revision(uuid,uuid,text,text),governance.publish_revision(uuid,uuid,uuid),governance.restore_revision(uuid,uuid,uuid,text),governance.verify_revision(uuid,text,text,uuid,timestamptz,text,text,text) TO egi_writer;
GRANT USAGE ON SCHEMA api TO egi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO egi_reader;
COMMIT;
