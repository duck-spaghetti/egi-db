-- Deploy egi_database:aggregate_extensions [publication] to pg
BEGIN;
-- Administrator-owned integration registry; app writers cannot register SQL handlers.
CREATE TABLE governance.revision_extensions (
 code text PRIMARY KEY, entity_kinds text[] NOT NULL, body_fields text[] NOT NULL,
 save_handler regprocedure NOT NULL, restore_tables text[] NOT NULL
);
CREATE FUNCTION governance.lock_operation() RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='write_requires_read_committed'; END IF;
 PERFORM pg_advisory_xact_lock(1162303812,1);
END $$;
REVOKE ALL ON FUNCTION governance.lock_operation() FROM PUBLIC;
CREATE FUNCTION governance.apply_revision_extensions(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE extension governance.revision_extensions; schema_name text; function_name text;
BEGIN
 FOR extension IN SELECT * FROM governance.revision_extensions WHERE kind=ANY(entity_kinds) ORDER BY code LOOP
  SELECT n.nspname,p.proname INTO STRICT schema_name,function_name FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.oid=extension.save_handler;
  EXECUTE format('SELECT %I.%I($1,$2,$3,$4,$5,$6)',schema_name,function_name) USING rev,owner,kind,body,evidence,note;
 END LOOP;
END $$;
REVOKE ALL ON governance.revision_extensions FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.apply_revision_extensions(uuid,uuid,text,jsonb,jsonb,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION governance.save_revision(kind text, entity uuid, expected_work uuid, expected_public uuid, body jsonb, note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner uuid:=COALESCE(entity,gen_random_uuid()); rev uuid; actor uuid:=governance.current_actor();
 scopes uuid[]; item jsonb; component uuid; decision uuid; name_unit uuid; description_unit uuid;
 field text; allowed text[]; evidence jsonb:=COALESCE(body->'evidence'->'record','[]'::jsonb); n bigint;
BEGIN
 IF kind NOT IN ('service','organization','location','territory') AND NOT EXISTS(SELECT FROM governance.revision_extensions WHERE kind=ANY(entity_kinds)) THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='unsupported_entity_kind'; END IF;
 IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='body_must_be_object'; END IF;
 allowed:=CASE WHEN kind IN ('service','organization','location','territory') THEN ARRAY['name','original_language','contacts','territories','evidence'] ELSE ARRAY['name','original_language','territories','evidence'] END||CASE kind
 WHEN 'service' THEN ARRAY['description','delivery_mode','operational_status','cost_state','cost_note','valid_from','valid_until','closure_date','closure_reason','place','organizations','conditions','contact_links','languages','coverage']
 WHEN 'location' THEN ARRAY['location_kind','latitude','longitude','coordinate_state','selected_geocoding_result_id','parent_location_id','addresses','organizations']
 WHEN 'organization' THEN ARRAY['description','organization_type','website']
 WHEN 'territory' THEN ARRAY['code','timezone_name','country_code','boundary_wkt'] ELSE ARRAY[]::text[] END;
 SELECT allowed||COALESCE(array_agg(f),ARRAY[]::text[]) INTO allowed FROM governance.revision_extensions e CROSS JOIN unnest(e.body_fields) f WHERE kind=ANY(e.entity_kinds);
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
  ELSIF kind='territory' THEN INSERT INTO geo.territories(entity_id,code) VALUES(owner,body->>'code'); END IF;
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
 FOR field IN SELECT key FROM jsonb_each(body) WHERE NOT EXISTS(SELECT FROM governance.revision_extensions e WHERE kind=ANY(e.entity_kinds) AND key=ANY(e.body_fields)) AND key NOT IN ('evidence','territories','contacts','contact_links','conditions','organizations','place','addresses','languages','coverage') LOOP
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
 ELSIF kind='territory' THEN
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
 PERFORM governance.apply_revision_extensions(rev,owner,kind,body,evidence,note);
 UPDATE governance.entity_revisions SET sealed_at=clock_timestamp() WHERE revision_id=rev;
 INSERT INTO governance.working_heads VALUES(owner,rev) ON CONFLICT(entity_id) DO UPDATE SET revision_id=EXCLUDED.revision_id;
 INSERT INTO governance.submissions(entity_id,proposed_revision_id,base_public_revision_id,actor_id) VALUES(owner,rev,expected_public,actor);
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id) VALUES(actor,'save',owner,rev);
 RETURN rev;
END $$;
CREATE OR REPLACE FUNCTION governance.restore_revision(source_revision uuid, expected_work uuid, expected_public uuid, note text) RETURNS uuid
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
 FOREACH relation IN ARRAY ARRAY['governance.revision_territories','geo.territory_revisions','data.organization_revisions','data.location_revisions','data.service_revisions','data.service_places','data.service_organizations','data.location_organizations','data.contact_entries','data.service_contact_links','data.access_conditions','data.addresses','data.service_languages','geo.service_memberships','geo.service_coverage']||(SELECT COALESCE(array_agg(r ORDER BY e.code,n),ARRAY[]::text[]) FROM governance.revision_extensions e CROSS JOIN unnest(e.restore_tables) WITH ORDINALITY x(r,n)) LOOP
  SELECT string_agg(quote_ident(a.attname),',' ORDER BY a.attnum),string_agg(CASE WHEN a.attname='revision_id' THEN '$2' WHEN a.attname IN ('value_decision_id','coordinate_decision_id') THEN format('($3->>old.%I::text)::uuid',a.attname) ELSE 'old.'||quote_ident(a.attname) END,',' ORDER BY a.attnum) INTO columns,expression FROM pg_attribute a WHERE a.attrelid=relation::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated='';
  EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM %s old WHERE old.revision_id=$1',relation,columns,expression,relation) USING source_revision,rev,decisions;
 END LOOP;
 UPDATE governance.entity_revisions SET sealed_at=clock_timestamp() WHERE revision_id=rev;
 INSERT INTO governance.working_heads VALUES(owner,rev) ON CONFLICT(entity_id) DO UPDATE SET revision_id=EXCLUDED.revision_id;
 INSERT INTO governance.submissions(entity_id,proposed_revision_id,base_public_revision_id,actor_id) VALUES(owner,rev,expected_public,governance.current_actor());
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'restore',owner,rev,jsonb_build_object('restored_from_revision_id',source_revision));
 RETURN rev;
END $$;

COMMIT;
