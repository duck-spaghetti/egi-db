-- Deploy egi_database:012_revision_body
-- requires: 011_editorial
-- EGI-83: read one service or location revision back as the body governance.save_revision
-- takes, evidence and component identifiers included. save_revision replaces the whole
-- aggregate, so an edit starts from this body and changes only what the moderator changed.
-- Same rules as sync's reader (egi-importer sync/db.py aggregate/_as_body), which can call
-- this function instead in B3.2.
BEGIN;

-- An object without its null fields: what a revision does not state is not in the body.
CREATE FUNCTION editorial.present(item jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT COALESCE(jsonb_object_agg(key,value) FILTER (WHERE jsonb_typeof(value)<>'null'),'{}'::jsonb) FROM jsonb_each(item)
$$;

-- A time as bodies write it: without zero seconds.
CREATE FUNCTION editorial.clock(value time) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN length(value::text)=8 AND right(value::text,3)=':00' THEN left(value::text,5) ELSE value::text END
$$;

CREATE FUNCTION editorial.revision_body(revision uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
 kind text; own jsonb; texts jsonb; supported jsonb; by_field jsonb; result jsonb; named text; evidence jsonb; field text;
BEGIN
 PERFORM governance.current_actor();
 SELECT entity_kind INTO kind FROM governance.entity_revisions WHERE revision_id=revision;
 IF kind IS NULL OR kind NOT IN ('service','location') THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='revision_not_found';
 END IF;

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

 -- Evidence per scalar field. An explicit empty list: save_revision must not borrow the
 -- record's evidence for a moderator's value.
 SELECT COALESCE(jsonb_object_agg(key,COALESCE(by_field->key,'[]')),'{}') INTO evidence
  FROM jsonb_each(result) WHERE jsonb_typeof(value) NOT IN ('array','object');
 FOREACH field IN ARRAY ARRAY['record','coordinates','territories'] LOOP
  IF by_field ? field THEN evidence:=evidence||jsonb_build_object(field,by_field->field); END IF;
 END LOOP;
 IF NOT evidence ? 'record' THEN
  evidence:=evidence||jsonb_build_object('record',COALESCE(by_field->(CASE kind WHEN 'service' THEN 'delivery_mode' ELSE 'location_kind' END),'[]'));
 END IF;
 RETURN result||jsonb_build_object('evidence',evidence);
END $$;

REVOKE ALL ON FUNCTION editorial.present(jsonb),editorial.clock(time),editorial.revision_body(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.revision_body(uuid) TO egi_editorial;
COMMIT;
