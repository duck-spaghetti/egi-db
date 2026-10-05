-- Deploy egi_database:shared_calendar [weekly_hours] to pg
BEGIN;
ALTER TABLE data.components DROP CONSTRAINT components_component_kind_check;
ALTER TABLE data.components ADD CONSTRAINT components_component_kind_check CHECK(component_kind IN ('contact','contact_link','address','condition','place','organization_role','coverage','schedule','interval','exception_effect'));
CREATE TABLE governance.exception_calendars (
 calendar_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE,
 name text NOT NULL CHECK(btrim(name)<>''), scope_territory_id uuid REFERENCES geo.territories,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE governance.calendar_event_versions (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL, entity_kind text NOT NULL DEFAULT 'calendar_event' CHECK(entity_kind='calendar_event'),
 calendar_id uuid NOT NULL REFERENCES governance.exception_calendars,
 date_from date NOT NULL,date_until date NOT NULL CHECK(date_until>=date_from),
 event_kind text NOT NULL DEFAULT 'advisory' CHECK(event_kind IN ('advisory','confirmed_change')),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 UNIQUE(revision_id,calendar_id)
);
CREATE TABLE data.schedule_calendar_links (
 revision_id uuid NOT NULL,schedule_id uuid NOT NULL,calendar_id uuid NOT NULL REFERENCES governance.exception_calendars,
 PRIMARY KEY(revision_id,schedule_id,calendar_id),
 FOREIGN KEY(revision_id,schedule_id) REFERENCES data.schedules(revision_id,component_id)
);
CREATE TABLE data.schedule_exception_effects (
 revision_id uuid NOT NULL,entity_id uuid NOT NULL,component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'exception_effect' CHECK(component_kind='exception_effect'),schedule_id uuid NOT NULL,
 calendar_id uuid NOT NULL,event_version_id uuid NOT NULL,effect_kind text NOT NULL CHECK(effect_kind IN ('closed','replace','add')),
 value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),UNIQUE(revision_id,schedule_id,event_version_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(revision_id,schedule_id,calendar_id) REFERENCES data.schedule_calendar_links,
 FOREIGN KEY(event_version_id,calendar_id) REFERENCES governance.calendar_event_versions(revision_id,calendar_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.exception_intervals (
 revision_id uuid NOT NULL,entity_id uuid NOT NULL,component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'interval' CHECK(component_kind='interval'),effect_id uuid NOT NULL,
 opens_at time NOT NULL CHECK(opens_at<'24:00'::time),closes_at time NOT NULL CHECK(closes_at<'24:00'::time),
 end_day_offset smallint NOT NULL DEFAULT 0 CHECK(end_day_offset IN (0,1)),value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 CHECK((end_day_offset=0 AND closes_at>opens_at) OR (end_day_offset=1 AND closes_at<=opens_at)),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(revision_id,effect_id) REFERENCES data.schedule_exception_effects(revision_id,component_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['governance.calendar_event_versions','data.schedule_calendar_links','data.schedule_exception_effects','data.exception_intervals'] LOOP
 EXECUTE format('CREATE TRIGGER open_revision BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision()',t);
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON governance.exception_calendars FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE FUNCTION governance.create_calendar(code text,name text,territory uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',CASE WHEN territory IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[territory] END);
 INSERT INTO governance.exception_calendars(code,name,scope_territory_id) VALUES(code,name,territory) RETURNING calendar_id INTO result;
 INSERT INTO audit.events(actor_id,action,details) VALUES(governance.current_actor(),'create_calendar',jsonb_build_object('calendar_id',result)); RETURN result;
END $$;
CREATE FUNCTION governance.save_calendar_event(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE territory uuid; field text; BEGIN
 SELECT scope_territory_id INTO STRICT territory FROM governance.exception_calendars WHERE calendar_id=(body->>'calendar_id')::uuid;
 PERFORM governance.require_capability('propose',CASE WHEN territory IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[territory] END);
 IF territory IS NOT NULL THEN INSERT INTO governance.revision_territories VALUES(rev,owner,territory) ON CONFLICT DO NOTHING; END IF;
 IF NOT EXISTS(SELECT FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=rev AND l.field_code='name' AND btrim(c.original_text)<>'') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='calendar_event_requires_name'; END IF;
 FOREACH field IN ARRAY ARRAY['calendar_id','date_from','date_until','event_kind','description'] LOOP
 IF body ? field THEN PERFORM governance.select_value(rev,owner,field,NULL,COALESCE(body->'evidence'->field,evidence),note); END IF; END LOOP;
 INSERT INTO governance.calendar_event_versions(revision_id,entity_id,calendar_id,date_from,date_until,event_kind) VALUES(rev,owner,(body->>'calendar_id')::uuid,(body->>'date_from')::date,(body->>'date_until')::date,COALESCE(body->>'event_kind','advisory'));
END $$;
CREATE FUNCTION governance.save_calendar_links(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE s jsonb; e jsonb; i jsonb; schedule uuid; effect uuid; component uuid; decision uuid; calendar uuid;
BEGIN
 FOR s IN SELECT value FROM jsonb_array_elements(COALESCE(body->'calendar_links','[]')) LOOP
 schedule:=(s->>'schedule_id')::uuid; calendar:=(s->>'calendar_id')::uuid;
 IF EXISTS(SELECT FROM governance.exception_calendars c WHERE c.calendar_id=calendar AND c.scope_territory_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.revision_territories r WHERE r.revision_id=rev AND r.territory_id=c.scope_territory_id)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='calendar_territory_mismatch'; END IF;
 INSERT INTO data.schedule_calendar_links VALUES(rev,schedule,calendar);
 FOR e IN SELECT value FROM jsonb_array_elements(COALESCE(s->'effects','[]')) LOOP
 IF NOT EXISTS(SELECT FROM governance.calendar_event_versions v JOIN governance.published_heads h USING(revision_id) WHERE v.revision_id=(e->>'event_version_id')::uuid AND v.event_kind='confirmed_change') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='approved_confirmed_event_required'; END IF;
 effect:=governance.owned_component(owner,'exception_effect',(e->>'component_id')::uuid);
 decision:=governance.select_value(rev,owner,'hours_exception',effect,COALESCE(e->'evidence',evidence),note);
 INSERT INTO data.schedule_exception_effects VALUES(rev,owner,effect,'exception_effect',schedule,calendar,(e->>'event_version_id')::uuid,e->>'kind',decision);
 FOR i IN SELECT value FROM jsonb_array_elements(COALESCE(e->'intervals','[]')) LOOP
 IF e->>'kind'='closed' THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='closed_effect_has_no_intervals'; END IF;
 component:=governance.owned_component(owner,'interval',(i->>'component_id')::uuid);
 decision:=governance.select_value(rev,owner,'hours_exception_interval',component,COALESCE(i->'evidence',e->'evidence',evidence),note);
 INSERT INTO data.exception_intervals VALUES(rev,owner,component,'interval',effect,(i->>'opens')::time,(i->>'closes')::time,COALESCE((i->>'end_day_offset')::smallint,0),decision);
 END LOOP;
 IF e->>'kind' IN ('replace','add') AND NOT EXISTS(SELECT FROM data.exception_intervals WHERE revision_id=rev AND effect_id=effect) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='exception_requires_intervals'; END IF;
 END LOOP;
 END LOOP;
END $$;
INSERT INTO governance.revision_extensions VALUES
 ('20_calendar_event',ARRAY['calendar_event'],ARRAY['calendar_id','date_from','date_until','event_kind','description'],'governance.save_calendar_event(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['governance.calendar_event_versions']),
 ('21_calendar_links',ARRAY['service','organization','location'],ARRAY['calendar_links'],'governance.save_calendar_links(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['data.schedule_calendar_links','data.schedule_exception_effects','data.exception_intervals']);
-- Effective predicate keeps uncertainty from advisory, missing interpretation or conflicts.
CREATE FUNCTION governance.calendar_state(rev uuid,scope text,contact uuid,instant timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE s data.schedules; local_time timestamp; event record; effect data.schedule_exception_effects; count_effects integer:=0; advisory boolean:=false; stale boolean:=false; result text; state text; start_day date; d integer; open_exception boolean:=false;
BEGIN
 result:=governance.weekly_state(rev,scope,contact,instant);
 IF (SELECT count(*) FROM governance.eligible_schedules(rev,scope,contact,instant))<>1 THEN RETURN jsonb_build_object('status','unknown','basis','missing_or_conflicting_schedule','contact_warning',false); END IF;
 SELECT * INTO s FROM governance.eligible_schedules(rev,scope,contact,instant);
 local_time:=instant AT TIME ZONE s.timezone_name;
 FOR event IN SELECT v.* FROM data.schedule_calendar_links l JOIN governance.calendar_event_versions v ON v.calendar_id=l.calendar_id JOIN governance.published_heads h ON h.revision_id=v.revision_id WHERE l.revision_id=rev AND l.schedule_id=s.component_id AND local_time::date BETWEEN v.date_from AND v.date_until+1 LOOP
 IF event.event_kind='advisory' THEN IF local_time::date<=event.date_until THEN advisory:=true; END IF; CONTINUE; END IF;
 SELECT * INTO effect FROM data.schedule_exception_effects WHERE revision_id=rev AND schedule_id=s.component_id AND event_version_id=event.revision_id;
 IF NOT FOUND THEN stale:=true; CONTINUE; END IF;
 IF local_time::date>event.date_until THEN
 IF effect.effect_kind='closed' OR NOT EXISTS(SELECT FROM data.exception_intervals i WHERE i.revision_id=rev AND i.effect_id=effect.component_id AND i.end_day_offset=1 AND local_time>=event.date_until+i.opens_at AND local_time<event.date_until+1+i.closes_at) THEN CONTINUE; END IF;
 count_effects:=count_effects+1;state:='open';CONTINUE;
 END IF;
 count_effects:=count_effects+1;
 IF effect.effect_kind='closed' THEN state:='closed'; ELSE
 open_exception:=false;
 FOR d IN 0..1 LOOP
 start_day:=local_time::date-d;
 IF start_day BETWEEN event.date_from AND event.date_until AND EXISTS(SELECT FROM data.exception_intervals i WHERE i.revision_id=rev AND i.effect_id=effect.component_id AND local_time>=start_day+i.opens_at AND local_time<start_day+i.end_day_offset+i.closes_at) THEN open_exception:=true; END IF;
 END LOOP;
 IF effect.effect_kind='replace' THEN state:=CASE WHEN open_exception THEN 'open' ELSE 'closed' END;
 ELSE state:=CASE WHEN open_exception THEN 'open' ELSE result END; END IF;
 END IF;
 END LOOP;
 IF stale OR count_effects>1 THEN result:='unknown'; ELSE IF count_effects=1 THEN result:=state; END IF; END IF;
 IF advisory THEN result:='unknown'; END IF;
 RETURN jsonb_build_object('status',result,'basis',CASE WHEN advisory THEN 'shared_calendar_advisory' WHEN stale THEN 'uninterpreted_calendar_change' WHEN count_effects>1 THEN 'conflicting_calendar_effects' WHEN count_effects=1 THEN 'confirmed_calendar_effect' ELSE 'weekly_local_clock' END,'contact_warning',advisory OR stale OR count_effects>1);
END $$;
CREATE FUNCTION api.opening(entity uuid,instant timestamptz,scope text DEFAULT 'service',contact uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE rev uuid; baseline jsonb; effective jsonb; s data.schedules; boundary timestamptz; transition timestamptz; next_state text; state text; operational text;
BEGIN
 baseline:=api.weekly_opening(entity,instant,scope,contact); IF baseline IS NULL THEN RETURN NULL; END IF;
 SELECT revision_id INTO rev FROM governance.published_heads WHERE entity_id=entity;
 IF scope IN ('service','intake') THEN
 SELECT operational_status INTO operational FROM data.service_revisions WHERE revision_id=rev;
 IF operational IN ('temporarily_closed','defunct') THEN RETURN baseline||jsonb_build_object('status','closed','certainty','declared','basis','operational_status','closes_at',NULL,'seconds_until_close',NULL,'next_transition_at',NULL,'next_status',NULL); END IF;
 END IF;
 effective:=governance.calendar_state(rev,scope,contact,instant); state:=effective->>'status';
 IF effective->>'basis'='weekly_local_clock' AND NOT EXISTS(SELECT FROM data.schedule_calendar_links WHERE revision_id=rev) THEN RETURN baseline||effective; END IF;
 SELECT * INTO s FROM data.schedules WHERE revision_id=rev AND scope_code=scope AND contact_component_id IS NOT DISTINCT FROM contact LIMIT 1;
 FOR boundary IN
 WITH schedules AS(SELECT * FROM data.schedules WHERE revision_id=rev AND scope_code=scope AND contact_component_id IS NOT DISTINCT FROM contact),
 dates AS(SELECT sc.*,p::date AS day FROM schedules sc CROSS JOIN LATERAL generate_series((instant AT TIME ZONE sc.timezone_name)::date::timestamp-interval '1 day',(instant AT TIME ZONE sc.timezone_name)::date::timestamp+interval '9 days',interval '1 day')p),
 bounds AS(SELECT timezone_name,day::timestamp civil FROM dates UNION SELECT d.timezone_name,d.day+i.opens_at FROM dates d JOIN data.schedule_intervals i ON i.revision_id=rev AND i.schedule_id=d.component_id AND i.iso_weekday=extract(isodow FROM d.day) UNION SELECT d.timezone_name,d.day+i.end_day_offset+i.closes_at FROM dates d JOIN data.schedule_intervals i ON i.revision_id=rev AND i.schedule_id=d.component_id AND i.iso_weekday=extract(isodow FROM d.day) UNION SELECT d.timezone_name,d.day+i.opens_at FROM dates d JOIN data.schedule_exception_effects e ON e.revision_id=rev AND e.schedule_id=d.component_id JOIN data.exception_intervals i ON i.revision_id=rev AND i.effect_id=e.component_id UNION SELECT d.timezone_name,d.day+i.end_day_offset+i.closes_at FROM dates d JOIN data.schedule_exception_effects e ON e.revision_id=rev AND e.schedule_id=d.component_id JOIN data.exception_intervals i ON i.revision_id=rev AND i.effect_id=e.component_id),
 candidates AS(SELECT p FROM bounds CROSS JOIN LATERAL governance.civil_occurrences(civil,timezone_name)p UNION SELECT p FROM schedules CROSS JOIN LATERAL governance.clock_changes(timezone_name,instant,instant+interval '9 days')p)
 SELECT DISTINCT p FROM candidates WHERE p>instant AND p<=instant+interval '8 days' ORDER BY p LOOP
 next_state:=governance.calendar_state(rev,scope,contact,boundary)->>'status'; IF next_state<>state THEN transition:=boundary; EXIT; END IF;
 END LOOP;
 RETURN baseline||effective||jsonb_build_object('certainty',CASE WHEN state='unknown' THEN 'uncertain' ELSE 'scheduled' END,'baseline_status',baseline->>'status','transition_search_until',instant+interval '8 days','next_transition_at',transition,'next_status',CASE WHEN transition IS NOT NULL THEN next_state END,'closes_at',CASE WHEN state='open' AND next_state='closed' THEN transition END,'seconds_until_close',CASE WHEN state='open' AND next_state='closed' THEN extract(epoch FROM transition-instant) END);
END $$;
CREATE FUNCTION governance.invalidate_calendar_consumers() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE affected record; territories uuid[]; BEGIN
 IF NOT EXISTS(SELECT FROM governance.calendar_event_versions WHERE revision_id=NEW.revision_id) THEN RETURN NEW; END IF;
 FOR affected IN SELECT DISTINCT h.entity_id,h.revision_id FROM governance.calendar_event_versions v JOIN data.schedule_calendar_links l USING(calendar_id) JOIN governance.published_heads h ON h.revision_id=l.revision_id WHERE v.revision_id=NEW.revision_id LOOP
 SELECT array_agg(t) INTO territories FROM governance.affected_territories(affected.entity_id,affected.revision_id)t;
 PERFORM governance.require_capability('publish',territories);
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(affected.entity_id,NEW.publication_id,'service','approved_calendar_change');
 END LOOP; RETURN NEW;
END $$;
CREATE TRIGGER calendar_consumers AFTER INSERT OR UPDATE ON governance.published_heads FOR EACH ROW EXECUTE FUNCTION governance.invalidate_calendar_consumers();
CREATE OR REPLACE FUNCTION governance.affected_territories(target_entity uuid, target_revision uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT territory_id FROM governance.revision_territories WHERE revision_id=target_revision
 UNION SELECT rt.territory_id FROM governance.working_heads wh JOIN governance.revision_territories rt ON rt.revision_id=wh.revision_id WHERE wh.entity_id=target_entity
 UNION SELECT rt.territory_id FROM governance.published_heads h JOIN governance.revision_territories rt ON rt.revision_id=h.revision_id WHERE h.entity_id=target_entity
 UNION SELECT m.territory_id FROM governance.published_heads h JOIN geo.service_memberships m ON m.revision_id=h.revision_id
 WHERE EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=target_entity)
 OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=target_entity)
 OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=target_entity)
 UNION SELECT m.territory_id FROM governance.calendar_event_versions ev JOIN data.schedule_calendar_links l ON l.calendar_id=ev.calendar_id JOIN governance.published_heads h ON h.revision_id=l.revision_id JOIN geo.service_memberships m ON m.revision_id=h.revision_id WHERE ev.entity_id=target_entity
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.opening(uuid,timestamptz,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.create_calendar(text,text,uuid) TO egi_writer;
GRANT EXECUTE ON FUNCTION api.opening(uuid,timestamptz,text,uuid) TO egi_reader;
COMMIT;
