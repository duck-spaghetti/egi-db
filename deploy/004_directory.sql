-- Deploy egi_database:004_directory
BEGIN;

-- ============================================================================
-- Weekly Hours
-- ============================================================================
CREATE TABLE data.schedules (
 revision_id uuid NOT NULL, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'schedule' CHECK(component_kind='schedule'),
 scope_code text NOT NULL CHECK(scope_code IN ('service','intake','contact')),
 contact_component_id uuid, timezone_name text NOT NULL, valid_from date, valid_until date,
 completeness text NOT NULL CHECK(completeness IN ('complete','partial','unknown')),
 value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 CHECK((scope_code='contact')=(contact_component_id IS NOT NULL)),
 CHECK(valid_until IS NULL OR valid_from IS NULL OR valid_until>=valid_from),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(revision_id,contact_component_id) REFERENCES data.contact_entries(revision_id,component_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.schedule_days (
 revision_id uuid NOT NULL, schedule_id uuid NOT NULL, iso_weekday smallint NOT NULL CHECK(iso_weekday BETWEEN 1 AND 7),
 day_state text NOT NULL CHECK(day_state IN ('intervals','closed','unknown')),
 completeness text NOT NULL CHECK(completeness IN ('complete','partial','unknown')),
 PRIMARY KEY(revision_id,schedule_id,iso_weekday),
 FOREIGN KEY(revision_id,schedule_id) REFERENCES data.schedules(revision_id,component_id)
);
CREATE TABLE data.schedule_intervals (
 revision_id uuid NOT NULL, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'interval' CHECK(component_kind='interval'),
 schedule_id uuid NOT NULL, iso_weekday smallint NOT NULL,
 opens_at time NOT NULL CHECK(opens_at<'24:00'::time), closes_at time NOT NULL CHECK(closes_at<'24:00'::time),
 end_day_offset smallint NOT NULL DEFAULT 0 CHECK(end_day_offset IN (0,1)),value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 CHECK((end_day_offset=0 AND closes_at>opens_at) OR (end_day_offset=1 AND closes_at<=opens_at)),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(revision_id,schedule_id,iso_weekday) REFERENCES data.schedule_days(revision_id,schedule_id,iso_weekday),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE FUNCTION governance.check_schedule() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM pg_timezone_names WHERE name=NEW.timezone_name) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unknown_timezone'; END IF;
 IF NEW.scope_code<>'contact' AND NOT EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=NEW.revision_id AND entity_kind='service') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='service_schedule_requires_service'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER schedule_semantics BEFORE INSERT ON data.schedules FOR EACH ROW EXECUTE FUNCTION governance.check_schedule();
CREATE FUNCTION governance.check_schedule_interval() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM data.schedule_days WHERE revision_id=NEW.revision_id AND schedule_id=NEW.schedule_id AND iso_weekday=NEW.iso_weekday AND day_state='intervals') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='interval_requires_interval_day'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER interval_semantics BEFORE INSERT ON data.schedule_intervals FOR EACH ROW EXECUTE FUNCTION governance.check_schedule_interval();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['schedules','schedule_days','schedule_intervals'] LOOP
 EXECUTE format('CREATE TRIGGER open_revision BEFORE INSERT ON data.%I FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision()',t);
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON data.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
CREATE FUNCTION governance.save_schedules(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE s jsonb; d jsonb; i jsonb; schedule uuid; component uuid; decision uuid;
BEGIN
 FOR s IN SELECT value FROM jsonb_array_elements(COALESCE(body->'schedules','[]')) LOOP
 schedule:=governance.owned_component(owner,'schedule',(s->>'component_id')::uuid);
 decision:=governance.select_value(rev,owner,'hours',schedule,COALESCE(s->'evidence',body->'evidence'->'hours',evidence),note);
 INSERT INTO data.schedules VALUES(rev,owner,schedule,'schedule',COALESCE(s->>'scope','service'),(s->>'contact_component_id')::uuid,s->>'timezone',(s->>'valid_from')::date,(s->>'valid_until')::date,COALESCE(s->>'completeness','unknown'),decision);
 FOR d IN SELECT value FROM jsonb_array_elements(COALESCE(s->'days','[]')) LOOP
 INSERT INTO data.schedule_days VALUES(rev,schedule,(d->>'weekday')::smallint,d->>'state',COALESCE(d->>'completeness','unknown'));
 FOR i IN SELECT value FROM jsonb_array_elements(COALESCE(d->'intervals','[]')) LOOP
 component:=governance.owned_component(owner,'interval',(i->>'component_id')::uuid);
 decision:=governance.select_value(rev,owner,'hours_interval',component,COALESCE(i->'evidence',s->'evidence',body->'evidence'->'hours',evidence),note);
 INSERT INTO data.schedule_intervals VALUES(rev,owner,component,'interval',schedule,(d->>'weekday')::smallint,(i->>'opens')::time,(i->>'closes')::time,COALESCE((i->>'end_day_offset')::smallint,0),decision);
 END LOOP;
 IF d->>'state'='intervals' AND NOT EXISTS(SELECT FROM data.schedule_intervals WHERE revision_id=rev AND schedule_id=schedule AND iso_weekday=(d->>'weekday')::smallint) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='interval_day_requires_interval'; END IF;
 END LOOP;
 END LOOP;
END $$;
INSERT INTO governance.revision_extensions VALUES('10_hours',ARRAY['service','organization','location'],ARRAY['schedules'],'governance.save_schedules(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['data.schedules','data.schedule_days','data.schedule_intervals']);
CREATE FUNCTION governance.eligible_schedules(rev uuid,scope text,contact uuid,instant timestamptz) RETURNS SETOF data.schedules
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT s.* FROM data.schedules s CROSS JOIN LATERAL(SELECT instant AT TIME ZONE s.timezone_name AS civil)x
 WHERE s.revision_id=rev AND s.scope_code=scope AND s.contact_component_id IS NOT DISTINCT FROM contact
 AND (s.valid_from IS NULL OR x.civil::date>=s.valid_from)
 AND (s.valid_until IS NULL OR x.civil::date<=s.valid_until OR (x.civil::date=s.valid_until+1 AND (
 EXISTS(SELECT FROM data.schedule_intervals i WHERE i.revision_id=rev AND i.schedule_id=s.component_id AND i.iso_weekday=extract(isodow FROM s.valid_until) AND i.end_day_offset=1 AND x.civil<s.valid_until+1+i.closes_at)
 OR s.completeness<>'complete' OR NOT EXISTS(SELECT FROM data.schedule_days d WHERE d.revision_id=rev AND d.schedule_id=s.component_id AND d.iso_weekday=extract(isodow FROM s.valid_until) AND d.completeness='complete' AND d.day_state<>'unknown')
 )))
$$;
-- Pure civil-clock predicate: no persisted current-open flag and no UTC guessing.
CREATE FUNCTION governance.weekly_state(rev uuid,scope text,contact uuid,instant timestamptz) RETURNS text
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE s data.schedules; local_time timestamp; day date; offset_day integer; rule data.schedule_days; start_day date; uncertain boolean:=false; matches integer:=0; result text;
BEGIN
 FOR s IN SELECT * FROM governance.eligible_schedules(rev,scope,contact,instant) LOOP
 local_time:=instant AT TIME ZONE s.timezone_name; day:=local_time::date;
 IF (s.valid_from IS NOT NULL AND day<s.valid_from) OR (s.valid_until IS NOT NULL AND day>s.valid_until+1) THEN CONTINUE; END IF;
 matches:=matches+1; result:='closed'; uncertain:=false;
 FOR offset_day IN 0..1 LOOP
 start_day:=day-offset_day;
 IF (s.valid_from IS NOT NULL AND start_day<s.valid_from) OR (s.valid_until IS NOT NULL AND start_day>s.valid_until) THEN CONTINUE; END IF;
 SELECT * INTO rule FROM data.schedule_days WHERE revision_id=rev AND schedule_id=s.component_id AND iso_weekday=extract(isodow FROM start_day);
 IF NOT FOUND OR rule.day_state='unknown' OR rule.completeness<>'complete' OR s.completeness<>'complete' THEN uncertain:=true; END IF;
 IF EXISTS(SELECT FROM data.schedule_intervals i WHERE i.revision_id=rev AND i.schedule_id=s.component_id AND i.iso_weekday=extract(isodow FROM start_day) AND local_time>=start_day+i.opens_at AND local_time<start_day+i.end_day_offset+i.closes_at) THEN result:='open'; END IF;
 END LOOP;
 IF result<>'open' AND uncertain THEN result:='unknown'; END IF;
 END LOOP;
 IF matches<>1 THEN RETURN 'unknown'; END IF;
 RETURN result;
END $$;
-- Return every real occurrence of a civil boundary (zero for a skipped time).
CREATE FUNCTION governance.civil_occurrences(civil timestamp,zone text) RETURNS SETOF timestamptz
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 WITH offsets AS (
 SELECT DISTINCT (p AT TIME ZONE zone)-(p AT TIME ZONE 'UTC') AS delta
 FROM generate_series((civil AT TIME ZONE 'UTC')-interval '2 days',(civil AT TIME ZONE 'UTC')+interval '2 days',interval '1 hour') p
 ), candidates AS (SELECT (civil-delta) AT TIME ZONE 'UTC' AS instant FROM offsets)
 SELECT instant FROM candidates WHERE instant AT TIME ZONE zone=civil
$$;
-- Clock jumps themselves are boundaries even when a civil endpoint is skipped.
CREATE FUNCTION governance.clock_changes(zone text,lo timestamptz,hi timestamptz) RETURNS SETOF timestamptz
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE a timestamptz; b timestamptz; m timestamptz; cursor_at timestamptz; old_offset interval; new_offset interval;
BEGIN
 cursor_at:=lo;
 WHILE cursor_at<hi LOOP
 a:=cursor_at; b:=least(cursor_at+interval '6 hours',hi);
 old_offset:=(a AT TIME ZONE zone)-(a AT TIME ZONE 'UTC');
 new_offset:=(b AT TIME ZONE zone)-(b AT TIME ZONE 'UTC');
 IF old_offset<>new_offset THEN
 WHILE b-a>interval '1 microsecond' LOOP
 m:=a+(b-a)/2;
 IF (m AT TIME ZONE zone)-(m AT TIME ZONE 'UTC')=old_offset THEN a:=m; ELSE b:=m; END IF;
 END LOOP;
 RETURN NEXT b;
 END IF;
 cursor_at:=least(cursor_at+interval '6 hours',hi);
 END LOOP;
END $$;
CREATE FUNCTION api.weekly_opening(entity uuid,instant timestamptz,scope text DEFAULT 'service',contact uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE rev uuid; state text; next_state text; boundary timestamptz; transition timestamptz; zone text;
BEGIN
 IF instant IS NULL OR NOT isfinite(instant) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='finite_instant_required'; END IF;
 SELECT revision_id INTO rev FROM governance.published_heads WHERE entity_id=entity;
 IF rev IS NULL THEN RETURN NULL; END IF;
 IF scope='contact' AND NOT EXISTS(SELECT FROM data.contact_entries WHERE revision_id=rev AND component_id=contact AND is_public) THEN RETURN NULL; END IF;
 state:=governance.weekly_state(rev,scope,contact,instant);
 FOR boundary IN
 WITH schedules AS (SELECT * FROM data.schedules WHERE revision_id=rev AND scope_code=scope AND contact_component_id IS NOT DISTINCT FROM contact),
 civil_dates AS (SELECT s.*,d::date AS day FROM schedules s CROSS JOIN LATERAL generate_series((instant AT TIME ZONE s.timezone_name)::date::timestamp,((instant AT TIME ZONE s.timezone_name)::date+9)::timestamp,interval '1 day') d),
 civil_bounds AS (
 SELECT timezone_name,day::timestamp AS civil FROM civil_dates
 UNION SELECT d.timezone_name,d.day+i.opens_at FROM civil_dates d JOIN data.schedule_intervals i ON i.revision_id=rev AND i.schedule_id=d.component_id AND i.iso_weekday=extract(isodow FROM d.day)
 UNION SELECT d.timezone_name,d.day+i.end_day_offset+i.closes_at FROM civil_dates d JOIN data.schedule_intervals i ON i.revision_id=rev AND i.schedule_id=d.component_id AND i.iso_weekday=extract(isodow FROM d.day)
 ), candidates AS (
 SELECT p FROM civil_bounds CROSS JOIN LATERAL governance.civil_occurrences(civil,timezone_name) p
 UNION SELECT p FROM schedules CROSS JOIN LATERAL governance.clock_changes(timezone_name,instant,instant+interval '9 days') p
 ) SELECT DISTINCT p FROM candidates WHERE p>instant AND p<=instant+interval '8 days' ORDER BY p
 LOOP
 next_state:=governance.weekly_state(rev,scope,contact,boundary);
 IF next_state<>state THEN transition:=boundary; EXIT; END IF;
 END LOOP;
 SELECT CASE WHEN count(*)=1 THEN min(timezone_name) END INTO zone FROM governance.eligible_schedules(rev,scope,contact,instant);
 RETURN jsonb_build_object('status',state,'certainty',CASE WHEN state='unknown' THEN 'uncertain' ELSE 'scheduled' END,'basis','weekly_local_clock','timezone',zone,'transition_search_until',instant+interval '8 days','next_transition_at',transition,'next_status',CASE WHEN transition IS NOT NULL THEN next_state END,'closes_at',CASE WHEN state='open' AND next_state='closed' THEN transition END,'seconds_until_close',CASE WHEN state='open' AND next_state='closed' THEN extract(epoch FROM transition-instant) END);
END $$;
CREATE VIEW api.weekly_hours WITH(security_barrier=true) AS
SELECT h.entity_id,h.revision_id,s.component_id AS schedule_id,s.scope_code,s.contact_component_id,s.timezone_name,s.valid_from,s.valid_until,s.completeness,d.iso_weekday,d.day_state,d.completeness AS day_completeness,i.component_id AS interval_id,i.opens_at,i.closes_at,i.end_day_offset
FROM governance.published_heads h JOIN data.schedules s USING(revision_id) JOIN data.schedule_days d ON d.revision_id=s.revision_id AND d.schedule_id=s.component_id LEFT JOIN data.schedule_intervals i ON i.revision_id=d.revision_id AND i.schedule_id=d.schedule_id AND i.iso_weekday=d.iso_weekday
WHERE s.scope_code<>'contact' OR EXISTS(SELECT FROM data.contact_entries c WHERE c.revision_id=s.revision_id AND c.component_id=s.contact_component_id AND c.is_public);
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.weekly_opening(uuid,timestamptz,text,uuid) FROM PUBLIC;
GRANT SELECT ON api.weekly_hours TO egi_reader;
GRANT EXECUTE ON FUNCTION api.weekly_opening(uuid,timestamptz,text,uuid) TO egi_reader;

-- ============================================================================
-- Shared Calendar
-- ============================================================================
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

-- ============================================================================
-- Territorial Taxonomy
-- ============================================================================
CREATE TABLE taxonomy.vocabularies (
 entity_id uuid PRIMARY KEY,entity_kind text NOT NULL DEFAULT 'taxonomy_vocabulary' CHECK(entity_kind='taxonomy_vocabulary'),code text NOT NULL UNIQUE,
 origin_vocabulary_id uuid REFERENCES taxonomy.vocabularies,origin_release_id uuid,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE taxonomy.vocabulary_revisions (
 revision_id uuid PRIMARY KEY,entity_id uuid NOT NULL,entity_kind text NOT NULL DEFAULT 'taxonomy_vocabulary' CHECK(entity_kind='taxonomy_vocabulary'),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES taxonomy.vocabularies,UNIQUE(revision_id,entity_id)
);
CREATE TABLE taxonomy.axes (
 axis_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),vocabulary_id uuid NOT NULL REFERENCES taxonomy.vocabularies,code text NOT NULL,
 UNIQUE(vocabulary_id,code),UNIQUE(axis_id,vocabulary_id)
);
CREATE TABLE taxonomy.terms (
 entity_id uuid PRIMARY KEY,entity_kind text NOT NULL DEFAULT 'taxonomy_term' CHECK(entity_kind='taxonomy_term'),
 vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,code text NOT NULL,external_uri text,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind),
 FOREIGN KEY(axis_id,vocabulary_id) REFERENCES taxonomy.axes(axis_id,vocabulary_id),
 UNIQUE(vocabulary_id,axis_id,code),UNIQUE(entity_id,vocabulary_id,axis_id)
);
CREATE TABLE taxonomy.term_revisions (
 revision_id uuid PRIMARY KEY,entity_id uuid NOT NULL,entity_kind text NOT NULL DEFAULT 'taxonomy_term' CHECK(entity_kind='taxonomy_term'),active boolean NOT NULL,
 presentation_metadata jsonb NOT NULL DEFAULT '{}',
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES taxonomy.terms,UNIQUE(revision_id,entity_id)
);
CREATE TABLE taxonomy.releases (
 release_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),vocabulary_id uuid NOT NULL REFERENCES taxonomy.vocabularies,vocabulary_revision_id uuid NOT NULL,
 sealed_at timestamptz,version text NOT NULL,actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(vocabulary_revision_id,vocabulary_id) REFERENCES taxonomy.vocabulary_revisions(revision_id,entity_id),
 UNIQUE(vocabulary_id,version),UNIQUE(release_id,vocabulary_id)
);
ALTER TABLE taxonomy.vocabularies ADD FOREIGN KEY(origin_release_id,origin_vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id);
ALTER TABLE taxonomy.vocabularies ADD CHECK((origin_vocabulary_id IS NULL)=(origin_release_id IS NULL));
CREATE TABLE taxonomy.release_axes (
 release_id uuid NOT NULL,vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,label text NOT NULL,sort_order integer NOT NULL DEFAULT 0,
 PRIMARY KEY(release_id,axis_id),
 FOREIGN KEY(release_id,vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id),
 FOREIGN KEY(axis_id,vocabulary_id) REFERENCES taxonomy.axes(axis_id,vocabulary_id)
);
CREATE TABLE taxonomy.release_terms (
 release_id uuid NOT NULL,vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,term_id uuid NOT NULL,term_revision_id uuid NOT NULL,
 PRIMARY KEY(release_id,term_id),UNIQUE(release_id,term_id,axis_id),
 FOREIGN KEY(release_id,axis_id) REFERENCES taxonomy.release_axes,
 FOREIGN KEY(term_id,vocabulary_id,axis_id) REFERENCES taxonomy.terms(entity_id,vocabulary_id,axis_id),
 FOREIGN KEY(term_revision_id,term_id) REFERENCES taxonomy.term_revisions(revision_id,entity_id)
);
CREATE TABLE taxonomy.broader_links (
 release_id uuid NOT NULL,axis_id uuid NOT NULL,child_term_id uuid NOT NULL,parent_term_id uuid NOT NULL,
 PRIMARY KEY(release_id,child_term_id,parent_term_id),CHECK(child_term_id<>parent_term_id),
 FOREIGN KEY(release_id,child_term_id,axis_id) REFERENCES taxonomy.release_terms(release_id,term_id,axis_id),
 FOREIGN KEY(release_id,parent_term_id,axis_id) REFERENCES taxonomy.release_terms(release_id,term_id,axis_id)
);
CREATE TABLE taxonomy.territory_adoptions (
 adoption_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),territory_id uuid NOT NULL REFERENCES geo.territories,vocabulary_id uuid NOT NULL,release_id uuid NOT NULL,
 effective_from date NOT NULL,effective_until date,CHECK(effective_until IS NULL OR effective_until>=effective_from),
 actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(release_id,vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id),
 UNIQUE(adoption_id,release_id),UNIQUE(adoption_id,territory_id)
);
CREATE TABLE taxonomy.assignments (
 revision_id uuid NOT NULL REFERENCES data.service_revisions,entity_id uuid NOT NULL,territory_id uuid NOT NULL,adoption_id uuid NOT NULL,release_id uuid NOT NULL,term_id uuid NOT NULL,
 value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,adoption_id,term_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(adoption_id,release_id) REFERENCES taxonomy.territory_adoptions(adoption_id,release_id),
 FOREIGN KEY(adoption_id,territory_id) REFERENCES taxonomy.territory_adoptions(adoption_id,territory_id),
 FOREIGN KEY(release_id,term_id) REFERENCES taxonomy.release_terms,
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE FUNCTION governance.check_taxonomy_edge() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(WITH RECURSIVE ancestors(t) AS(SELECT NEW.parent_term_id UNION SELECT b.parent_term_id FROM taxonomy.broader_links b JOIN ancestors a ON b.child_term_id=a.t WHERE b.release_id=NEW.release_id) SELECT FROM ancestors WHERE t=NEW.child_term_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_cycle'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER acyclic BEFORE INSERT ON taxonomy.broader_links FOR EACH ROW EXECUTE FUNCTION governance.check_taxonomy_edge();
CREATE FUNCTION governance.check_taxonomy_adoption() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT FROM taxonomy.territory_adoptions a WHERE a.territory_id=NEW.territory_id AND daterange(a.effective_from,a.effective_until,'[]') && daterange(NEW.effective_from,NEW.effective_until,'[]') AND EXISTS(SELECT FROM taxonomy.release_axes olda JOIN taxonomy.axes ax ON ax.axis_id=olda.axis_id JOIN taxonomy.release_axes newa ON newa.release_id=NEW.release_id JOIN taxonomy.axes bx ON bx.axis_id=newa.axis_id WHERE olda.release_id=a.release_id AND ax.code=bx.code)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='overlapping_taxonomy_adoption'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER no_overlap BEFORE INSERT ON taxonomy.territory_adoptions FOR EACH ROW EXECUTE FUNCTION governance.check_taxonomy_adoption();
CREATE FUNCTION governance.save_taxonomy_entity(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE field text;
BEGIN
 FOR field IN SELECT key FROM jsonb_each(body) WHERE key NOT IN ('name','original_language','territories','evidence') LOOP
 PERFORM governance.select_value(rev,owner,field,NULL,COALESCE(body->'evidence'->field,evidence),note); END LOOP;
 IF NOT EXISTS(SELECT FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=rev AND l.field_code='name' AND btrim(c.original_text)<>'') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_name_required'; END IF;
 IF kind='taxonomy_vocabulary' THEN
 INSERT INTO taxonomy.vocabularies(entity_id,code,origin_vocabulary_id,origin_release_id) VALUES(owner,body->>'code',(body->>'origin_vocabulary_id')::uuid,(body->>'origin_release_id')::uuid) ON CONFLICT(entity_id) DO NOTHING;
 IF NOT EXISTS(SELECT FROM taxonomy.vocabularies WHERE entity_id=owner AND code=body->>'code' AND origin_vocabulary_id IS NOT DISTINCT FROM (body->>'origin_vocabulary_id')::uuid AND origin_release_id IS NOT DISTINCT FROM (body->>'origin_release_id')::uuid) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='immutable_vocabulary_identity'; END IF;
 INSERT INTO taxonomy.vocabulary_revisions(revision_id,entity_id) VALUES(rev,owner);
 ELSE
 INSERT INTO taxonomy.terms(entity_id,vocabulary_id,axis_id,code,external_uri) VALUES(owner,(body->>'vocabulary_id')::uuid,(body->>'axis_id')::uuid,body->>'code',body->>'external_uri') ON CONFLICT(entity_id) DO NOTHING;
 IF NOT EXISTS(SELECT FROM taxonomy.terms WHERE entity_id=owner AND vocabulary_id=(body->>'vocabulary_id')::uuid AND axis_id=(body->>'axis_id')::uuid AND code=body->>'code' AND external_uri IS NOT DISTINCT FROM body->>'external_uri') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='immutable_term_identity'; END IF;
 INSERT INTO taxonomy.term_revisions(revision_id,entity_id,active,presentation_metadata) VALUES(rev,owner,COALESCE((body->>'active')::boolean,true),COALESCE(body->'presentation_metadata','{}'));
 END IF;
END $$;
CREATE FUNCTION governance.create_taxonomy_axis(vocabulary uuid,code text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; scopes uuid[]; rev uuid; BEGIN
 PERFORM governance.lock_operation();
 SELECT revision_id INTO STRICT rev FROM governance.published_heads WHERE entity_id=vocabulary;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(vocabulary,rev)t;
 PERFORM governance.require_capability('propose',scopes);
 INSERT INTO taxonomy.axes(vocabulary_id,code) VALUES(vocabulary,code) RETURNING axis_id INTO result; RETURN result;
END $$;
CREATE FUNCTION governance.freeze_taxonomy_release(vocabulary_revision uuid,version text,axes jsonb,terms jsonb,edges jsonb,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; vocabulary uuid; scopes uuid[]; item jsonb; child uuid; parent uuid; axis uuid; BEGIN
 PERFORM governance.lock_operation();
 SELECT v.entity_id INTO STRICT vocabulary FROM taxonomy.vocabulary_revisions v JOIN governance.published_heads h USING(revision_id) WHERE revision_id=vocabulary_revision;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(vocabulary,vocabulary_revision)t;
 PERFORM governance.require_capability('propose',scopes); PERFORM governance.require_capability('approve',scopes); PERFORM governance.require_capability('publish',scopes);
 INSERT INTO taxonomy.releases(vocabulary_id,vocabulary_revision_id,version,actor_id,reason) VALUES(vocabulary,vocabulary_revision,version,governance.current_actor(),note) RETURNING release_id INTO result;
 FOR item IN SELECT value FROM jsonb_array_elements(axes) LOOP
 INSERT INTO taxonomy.release_axes VALUES(result,vocabulary,(item->>'axis_id')::uuid,item->>'label',COALESCE((item->>'sort_order')::integer,0)); END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(terms) LOOP
 IF NOT EXISTS(SELECT FROM taxonomy.term_revisions t JOIN governance.published_heads h USING(revision_id) WHERE t.revision_id=(item->>'revision_id')::uuid AND t.entity_id=(item->>'term_id')::uuid AND t.active) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='approved_active_term_required'; END IF;
 SELECT axis_id INTO STRICT axis FROM taxonomy.terms WHERE entity_id=(item->>'term_id')::uuid;
 INSERT INTO taxonomy.release_terms VALUES(result,vocabulary,axis,(item->>'term_id')::uuid,(item->>'revision_id')::uuid); END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(edges) LOOP
 child:=(item->>'child')::uuid;parent:=(item->>'parent')::uuid;
 SELECT axis_id INTO STRICT axis FROM taxonomy.terms WHERE entity_id=child;
 INSERT INTO taxonomy.broader_links VALUES(result,axis,child,parent); END LOOP;
 UPDATE taxonomy.releases SET sealed_at=clock_timestamp() WHERE release_id=result;
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'approve_and_freeze_taxonomy_release',vocabulary,vocabulary_revision,jsonb_build_object('release_id',result,'reason',note)); RETURN result;
END $$;
CREATE FUNCTION governance.adopt_taxonomy_release(territory uuid,release uuid,date_from date,date_until date,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; vocabulary uuid; BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',ARRAY[territory]);PERFORM governance.require_capability('approve',ARRAY[territory]);PERFORM governance.require_capability('publish',ARRAY[territory]);
 SELECT vocabulary_id INTO STRICT vocabulary FROM taxonomy.releases WHERE release_id=release AND sealed_at IS NOT NULL;
 IF EXISTS(SELECT FROM taxonomy.assignments a JOIN governance.published_heads h USING(revision_id) JOIN taxonomy.territory_adoptions old ON old.adoption_id=a.adoption_id WHERE a.territory_id=territory AND old.vocabulary_id=vocabulary AND NOT EXISTS(SELECT FROM taxonomy.release_terms t WHERE t.release_id=release AND t.term_id=a.term_id)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_assignment_migration_required'; END IF;
 INSERT INTO taxonomy.territory_adoptions(territory_id,vocabulary_id,release_id,effective_from,effective_until,actor_id,reason) VALUES(territory,vocabulary,release,date_from,date_until,governance.current_actor(),note) RETURNING adoption_id INTO result;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'approve_taxonomy_adoption',territory,jsonb_build_object('adoption_id',result,'release_id',release,'reason',note)); RETURN result;
END $$;
CREATE FUNCTION governance.fork_taxonomy_release(source_release uuid,target_territory uuid,new_code text,new_version text,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE source taxonomy.releases; target_revision uuid; target uuid; revision uuid; owner uuid; decision uuid; item record; axis uuid; axis_map jsonb:='{}'; term_map jsonb:='{}'; axes jsonb:='[]'; terms jsonb:='[]'; edges jsonb:='[]'; body jsonb; evidence jsonb; result uuid;
BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',ARRAY[target_territory]);PERFORM governance.require_capability('approve',ARRAY[target_territory]);PERFORM governance.require_capability('publish',ARRAY[target_territory]);
 SELECT * INTO STRICT source FROM taxonomy.releases WHERE release_id=source_release AND sealed_at IS NOT NULL;
 SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('assertion_id',e.assertion_id,'role',e.evidence_role)),'[]') INTO evidence FROM governance.value_decisions d JOIN governance.value_evidence e USING(value_decision_id) WHERE d.revision_id=source.vocabulary_revision_id;
 SELECT jsonb_build_object('code',new_code,'name',c.original_text,'original_language',c.original_language,'origin_vocabulary_id',source.vocabulary_id,'origin_release_id',source.release_id,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='name';
 SELECT body||jsonb_build_object('description',c.original_text) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='description';
 -- SELECT INTO with no description would null the body; rebuild optional text safely.
 IF body IS NULL THEN
 SELECT jsonb_build_object('code',new_code,'name',c.original_text,'original_language',c.original_language,'origin_vocabulary_id',source.vocabulary_id,'origin_release_id',source.release_id,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='name'; END IF;
 target_revision:=governance.save_revision('taxonomy_vocabulary',NULL,NULL,NULL,body,note);SELECT entity_id INTO target FROM governance.entity_revisions WHERE revision_id=target_revision;
 decision:=governance.review_revision(target_revision,NULL,'approved',note);PERFORM governance.publish_revision(target_revision,decision,NULL);
 FOR item IN SELECT ra.*,ax.code FROM taxonomy.release_axes ra JOIN taxonomy.axes ax USING(axis_id) WHERE ra.release_id=source_release ORDER BY ra.axis_id LOOP
 axis:=governance.create_taxonomy_axis(target,item.code);axis_map:=axis_map||jsonb_build_object(item.axis_id::text,axis);
 axes:=axes||jsonb_build_array(jsonb_build_object('axis_id',axis,'label',item.label,'sort_order',item.sort_order));END LOOP;
 FOR item IN SELECT rt.*,t.code,t.external_uri,tr.presentation_metadata FROM taxonomy.release_terms rt JOIN taxonomy.terms t ON t.entity_id=rt.term_id JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id WHERE rt.release_id=source_release ORDER BY rt.term_id LOOP
 SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('assertion_id',e.assertion_id,'role',e.evidence_role)),'[]') INTO evidence FROM governance.value_decisions d JOIN governance.value_evidence e USING(value_decision_id) WHERE d.revision_id=item.term_revision_id;
 SELECT jsonb_build_object('code',item.code,'name',c.original_text,'description',(SELECT d.original_text FROM i18n.revision_content_links dl JOIN i18n.content_units d USING(content_id) WHERE dl.revision_id=item.term_revision_id AND dl.field_code='description'),'original_language',c.original_language,'vocabulary_id',target,'axis_id',(axis_map->>item.axis_id::text)::uuid,'external_uri',item.external_uri,'active',true,'presentation_metadata',item.presentation_metadata,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=item.term_revision_id AND l.field_code='name';
 revision:=governance.save_revision('taxonomy_term',NULL,NULL,NULL,body,note);SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=revision;
 decision:=governance.review_revision(revision,NULL,'approved',note);PERFORM governance.publish_revision(revision,decision,NULL);
 term_map:=term_map||jsonb_build_object(item.term_id::text,owner);terms:=terms||jsonb_build_array(jsonb_build_object('term_id',owner,'revision_id',revision));
 END LOOP;
 FOR item IN SELECT * FROM taxonomy.broader_links WHERE release_id=source_release ORDER BY child_term_id,parent_term_id LOOP
 edges:=edges||jsonb_build_array(jsonb_build_object('child',(term_map->>item.child_term_id::text)::uuid,'parent',(term_map->>item.parent_term_id::text)::uuid));END LOOP;
 result:=governance.freeze_taxonomy_release(target_revision,new_version,axes,terms,edges,note);
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'fork_taxonomy_release',target,target_revision,jsonb_build_object('source_release_id',source_release,'target_release_id',result,'term_identity_map',term_map,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.save_classifications(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE item jsonb; adoption taxonomy.territory_adoptions; decision uuid; BEGIN
 FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'classifications','[]')) LOOP
 SELECT * INTO STRICT adoption FROM taxonomy.territory_adoptions WHERE adoption_id=(item->>'adoption_id')::uuid;
 IF NOT EXISTS(SELECT FROM geo.service_memberships WHERE revision_id=rev AND territory_id=adoption.territory_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='classification_requires_map_membership'; END IF;
 decision:=governance.select_value(rev,owner,'classification',NULL,COALESCE(item->'evidence',evidence),note);
 INSERT INTO taxonomy.assignments VALUES(rev,owner,adoption.territory_id,adoption.adoption_id,adoption.release_id,(item->>'term_id')::uuid,decision);
 END LOOP;
END $$;
INSERT INTO governance.revision_extensions VALUES
 ('30_vocabulary',ARRAY['taxonomy_vocabulary'],ARRAY['code','origin_vocabulary_id','origin_release_id','description'],'governance.save_taxonomy_entity(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.vocabulary_revisions']),
 ('31_term',ARRAY['taxonomy_term'],ARRAY['vocabulary_id','axis_id','code','external_uri','active','presentation_metadata','description'],'governance.save_taxonomy_entity(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.term_revisions']),
 ('32_classification',ARRAY['service'],ARRAY['classifications'],'governance.save_classifications(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.assignments']);
CREATE FUNCTION api.taxonomy_search(territory uuid,selections jsonb,at_date date DEFAULT current_date) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH RECURSIVE requested AS(SELECT key AS axis_code,value FROM jsonb_each(selections)),
 expanded(axis_code,release_id,term_id) AS (
 SELECT r.axis_code,a.release_id,t.entity_id FROM requested r CROSS JOIN LATERAL jsonb_array_elements_text(r.value)x JOIN taxonomy.terms t ON t.entity_id=x::uuid JOIN taxonomy.axes ax ON ax.axis_id=t.axis_id AND ax.code=r.axis_code JOIN taxonomy.territory_adoptions a ON a.territory_id=territory AND a.release_id IN(SELECT release_id FROM taxonomy.release_terms WHERE term_id=t.entity_id) AND at_date>=a.effective_from AND (a.effective_until IS NULL OR at_date<=a.effective_until)
 UNION SELECT e.axis_code,e.release_id,b.child_term_id FROM expanded e JOIN taxonomy.broader_links b ON b.release_id=e.release_id AND b.parent_term_id=e.term_id
 ), matched AS(SELECT DISTINCT a.entity_id,e.axis_code FROM expanded e JOIN taxonomy.assignments a ON a.release_id=e.release_id AND a.term_id=e.term_id AND a.territory_id=territory JOIN api.discoverable_services s ON s.revision_id=a.revision_id)
 SELECT s.service_id FROM api.discoverable_services s JOIN geo.service_memberships m ON m.revision_id=s.revision_id AND m.territory_id=territory
 WHERE NOT EXISTS(SELECT FROM requested r WHERE NOT EXISTS(SELECT FROM matched q WHERE q.entity_id=s.service_id AND q.axis_code=r.axis_code))
$$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['vocabularies','vocabulary_revisions','axes','terms','term_revisions','release_axes','release_terms','broader_links','territory_adoptions','assignments'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['vocabulary_revisions','term_revisions','assignments'] LOOP
 EXECUTE format('CREATE TRIGGER open_revision BEFORE INSERT ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision()',t); END LOOP;
END $$;
CREATE FUNCTION governance.protect_taxonomy_release() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.sealed_at IS NULL AND NEW.sealed_at IS NOT NULL AND to_jsonb(NEW)-'sealed_at'=to_jsonb(OLD)-'sealed_at' THEN RETURN NEW; END IF;
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='immutable_taxonomy_release';
END $$;
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON taxonomy.releases FOR EACH ROW EXECUTE FUNCTION governance.protect_taxonomy_release();
CREATE FUNCTION governance.check_open_taxonomy_release() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT FROM taxonomy.releases WHERE release_id=NEW.release_id AND sealed_at IS NOT NULL) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='sealed_taxonomy_release'; END IF;RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['release_axes','release_terms','broader_links'] LOOP
 EXECUTE format('CREATE TRIGGER open_release BEFORE INSERT ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.check_open_taxonomy_release()',t);END LOOP;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.taxonomy_search(uuid,jsonb,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.fork_taxonomy_release(uuid,uuid,text,text,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.create_taxonomy_axis(uuid,text),governance.freeze_taxonomy_release(uuid,text,jsonb,jsonb,jsonb,text),governance.adopt_taxonomy_release(uuid,uuid,date,date,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION api.taxonomy_search(uuid,jsonb,date) TO egi_reader;

-- ============================================================================
-- Dynamic Translations
-- ============================================================================
CREATE TABLE i18n.languages (
 language_code text PRIMARY KEY CHECK(language_code ~ '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$'),native_name text NOT NULL,english_name text NOT NULL,direction text NOT NULL CHECK(direction IN('ltr','rtl'))
);
CREATE TABLE i18n.translations (
 translation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),content_id uuid NOT NULL REFERENCES i18n.content_units,language_code text NOT NULL REFERENCES i18n.languages,
 translated_text text NOT NULL CHECK(btrim(translated_text)<>''),translation_class text NOT NULL CHECK(translation_class IN('human','ai','ai_verified')),
 actor_id uuid NOT NULL REFERENCES governance.actors,model_version text,supersedes_id uuid REFERENCES i18n.translations,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((translation_class='human' AND model_version IS NULL) OR (translation_class IN('ai','ai_verified') AND model_version IS NOT NULL)),
 UNIQUE(translation_id,content_id,language_code)
);
CREATE TABLE i18n.translation_reviews (
 review_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),translation_id uuid NOT NULL REFERENCES i18n.translations,outcome text NOT NULL CHECK(outcome IN('approved','needs_changes')),
 review_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(review_id,translation_id,outcome)
);
CREATE TABLE i18n.translation_publications (
 publication_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),content_id uuid NOT NULL,language_code text NOT NULL,translation_id uuid NOT NULL,
 review_id uuid NOT NULL,outcome text NOT NULL DEFAULT 'approved' CHECK(outcome='approved'),actor_id uuid NOT NULL REFERENCES governance.actors,published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(translation_id,content_id,language_code) REFERENCES i18n.translations(translation_id,content_id,language_code),
 FOREIGN KEY(review_id,translation_id,outcome) REFERENCES i18n.translation_reviews(review_id,translation_id,outcome),
 UNIQUE(publication_id,content_id,language_code)
);
CREATE TABLE i18n.translation_heads (
 content_id uuid NOT NULL,language_code text NOT NULL,publication_id uuid NOT NULL,
 PRIMARY KEY(content_id,language_code),FOREIGN KEY(publication_id,content_id,language_code) REFERENCES i18n.translation_publications(publication_id,content_id,language_code)
);
CREATE TABLE i18n.territory_language_priorities (
 territory_id uuid NOT NULL REFERENCES geo.territories,language_code text NOT NULL REFERENCES i18n.languages,priority integer NOT NULL,enabled_for_translation_work boolean NOT NULL DEFAULT true,
 PRIMARY KEY(territory_id,language_code)
);
CREATE TABLE i18n.translation_update_requests (
 request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),entity_id uuid NOT NULL,field_code text NOT NULL,component_scope uuid NOT NULL,language_code text NOT NULL REFERENCES i18n.languages,
 required_content_id uuid NOT NULL,previous_translation_id uuid REFERENCES i18n.translations,reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(required_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),UNIQUE(entity_id,field_code,component_scope,language_code,required_content_id)
);
CREATE FUNCTION governance.public_content(content uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT FROM i18n.content_units c JOIN i18n.revision_content_links l USING(content_id) JOIN governance.published_heads h USING(revision_id) WHERE c.content_id=content AND NOT EXISTS(SELECT FROM data.contact_entries p WHERE p.revision_id=h.revision_id AND p.component_id=c.component_id AND NOT p.is_public))
 OR EXISTS(SELECT FROM taxonomy.release_terms rt JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id JOIN taxonomy.territory_adoptions a USING(release_id) WHERE l.content_id=content)
$$;
CREATE VIEW governance.translation_work AS
SELECT q.*,CASE WHEN NOT governance.public_content(q.required_content_id) THEN 'superseded' WHEN EXISTS(SELECT FROM i18n.translation_heads WHERE content_id=q.required_content_id AND language_code=q.language_code) THEN 'resolved' ELSE 'open' END AS status
FROM i18n.translation_update_requests q;
CREATE FUNCTION governance.translation_scope(content uuid) RETURNS uuid[] LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT array_agg(t) FROM i18n.content_units c LEFT JOIN governance.published_heads h ON h.entity_id=c.owner_entity_id CROSS JOIN LATERAL governance.affected_territories(c.owner_entity_id,COALESCE(h.revision_id,c.introduced_revision_id))t WHERE c.content_id=content
$$;
CREATE FUNCTION governance.propose_translation(content uuid,language text,text_value text,class text,model text,previous uuid,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',governance.translation_scope(content));
 IF previous IS NOT NULL AND NOT EXISTS(SELECT FROM i18n.translations WHERE translation_id=previous AND content_id=content AND language_code=language) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='translation_origin_mismatch'; END IF;
 IF class='ai_verified' THEN
 IF previous IS NULL OR NOT EXISTS(SELECT FROM i18n.translations WHERE translation_id=previous AND translation_class IN('ai','ai_verified') AND model_version=model) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='verified_ai_requires_origin'; END IF;
 PERFORM governance.require_capability('verify',governance.translation_scope(content)); END IF;
 INSERT INTO i18n.translations(content_id,language_code,translated_text,translation_class,actor_id,model_version,supersedes_id) VALUES(content,language,text_value,class,governance.current_actor(),model,previous) RETURNING translation_id INTO result;
 INSERT INTO audit.events(actor_id,action,details) VALUES(governance.current_actor(),'propose_translation',jsonb_build_object('translation_id',result,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.review_translation(translation uuid,outcome text,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate i18n.translations; result uuid; BEGIN
 PERFORM governance.lock_operation();SELECT * INTO STRICT candidate FROM i18n.translations WHERE translation_id=translation;
 PERFORM governance.require_capability('approve',governance.translation_scope(candidate.content_id));
 IF candidate.actor_id=governance.current_actor() THEN PERFORM governance.require_capability('propose',governance.translation_scope(candidate.content_id)); END IF;
 INSERT INTO i18n.translation_reviews(translation_id,outcome,actor_id,reason) VALUES(translation,outcome,governance.current_actor(),note) RETURNING review_id INTO result;RETURN result;
END $$;
CREATE FUNCTION governance.publish_translation(translation uuid,review uuid,expected_publication uuid,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate i18n.translations; head uuid; result uuid; owner uuid; affected record; BEGIN
 PERFORM governance.lock_operation();SELECT * INTO STRICT candidate FROM i18n.translations WHERE translation_id=translation;
 PERFORM governance.require_capability('publish',governance.translation_scope(candidate.content_id));
 SELECT publication_id INTO head FROM i18n.translation_heads WHERE content_id=candidate.content_id AND language_code=candidate.language_code;
 IF head IS DISTINCT FROM expected_publication THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='stale_translation_base'; END IF;
 IF NOT EXISTS(SELECT FROM i18n.translation_reviews WHERE review_id=review AND translation_id=translation AND outcome='approved' AND review_sequence=(SELECT max(review_sequence) FROM i18n.translation_reviews WHERE translation_id=translation)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='exact_translation_approval_required'; END IF;
 IF NOT governance.public_content(candidate.content_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='original_not_current'; END IF;
 INSERT INTO i18n.translation_publications(content_id,language_code,translation_id,review_id,actor_id) VALUES(candidate.content_id,candidate.language_code,translation,review,governance.current_actor()) RETURNING publication_id INTO result;
 INSERT INTO i18n.translation_heads VALUES(candidate.content_id,candidate.language_code,result) ON CONFLICT(content_id,language_code) DO UPDATE SET publication_id=EXCLUDED.publication_id;
 SELECT owner_entity_id INTO owner FROM i18n.content_units WHERE content_id=candidate.content_id;
 FOR affected IN SELECT h.entity_id,h.publication_id FROM governance.published_heads h WHERE h.entity_id=owner OR EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=owner) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=owner) OR EXISTS(SELECT FROM data.service_contact_links l WHERE l.revision_id=h.revision_id AND l.target_entity_id=owner) LOOP
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(affected.entity_id,affected.publication_id,'translated_content','approved_translation_change'); END LOOP;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'publish_translation',owner,jsonb_build_object('translation_id',translation,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.queue_translation_updates() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO i18n.translation_update_requests(entity_id,field_code,component_scope,language_code,required_content_id,previous_translation_id,reason)
 SELECT NEW.entity_id,l.field_code,l.component_scope,target.language_code,l.content_id,previous.translation_id,'published_original_changed'
 FROM i18n.revision_content_links l CROSS JOIN LATERAL (
 SELECT p.language_code FROM governance.affected_territories(NEW.entity_id,NEW.revision_id)t JOIN i18n.territory_language_priorities p ON p.territory_id=t WHERE p.enabled_for_translation_work
 UNION SELECT h.language_code FROM i18n.content_units c JOIN i18n.translation_heads h USING(content_id) WHERE c.owner_entity_id=NEW.entity_id AND c.field_code=l.field_code AND COALESCE(c.component_id,'00000000-0000-0000-0000-000000000000'::uuid)=l.component_scope
 )target
 LEFT JOIN LATERAL (SELECT pub.translation_id FROM i18n.content_units c JOIN i18n.translation_heads h USING(content_id) JOIN i18n.translation_publications pub USING(publication_id) WHERE c.owner_entity_id=NEW.entity_id AND c.field_code=l.field_code AND COALESCE(c.component_id,'00000000-0000-0000-0000-000000000000'::uuid)=l.component_scope AND h.language_code=target.language_code ORDER BY pub.published_at DESC LIMIT 1)previous ON true
 WHERE l.revision_id=NEW.revision_id AND NOT EXISTS(SELECT FROM i18n.translation_heads h WHERE h.content_id=l.content_id AND h.language_code=target.language_code)
 ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER translation_updates AFTER INSERT OR UPDATE ON governance.published_heads FOR EACH ROW EXECUTE FUNCTION governance.queue_translation_updates();
CREATE FUNCTION api.resolve_text(content uuid,preferred text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,'direction',COALESCE(lang.direction,orig.direction),'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class,'content_id',c.content_id)
 FROM i18n.content_units c LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred LEFT JOIN i18n.translation_publications p USING(publication_id) LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id LEFT JOIN i18n.languages lang ON lang.language_code=t.language_code LEFT JOIN i18n.languages orig ON orig.language_code=c.original_language
 WHERE c.content_id=content AND governance.public_content(content)
$$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['translations','translation_reviews','translation_publications','translation_update_requests'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON i18n.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);END LOOP;
END $$;
CREATE FUNCTION governance.register_language(code text,native_name text,english_name text,direction text,note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',ARRAY[]::uuid[]);PERFORM governance.require_capability('approve',ARRAY[]::uuid[]);
 INSERT INTO i18n.languages VALUES(code,native_name,english_name,direction);
 INSERT INTO audit.events(actor_id,action,details) VALUES(governance.current_actor(),'register_content_language',jsonb_build_object('language',code,'reason',note));
END $$;
CREATE FUNCTION governance.prioritize_language(territory uuid,language text,priority integer,enabled boolean,note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',ARRAY[territory]);PERFORM governance.require_capability('approve',ARRAY[territory]);
 INSERT INTO i18n.territory_language_priorities VALUES(territory,language,priority,enabled) ON CONFLICT(territory_id,language_code) DO UPDATE SET priority=EXCLUDED.priority,enabled_for_translation_work=EXCLUDED.enabled_for_translation_work;
 IF enabled THEN
 INSERT INTO i18n.translation_update_requests(entity_id,field_code,component_scope,language_code,required_content_id,reason)
 SELECT h.entity_id,l.field_code,l.component_scope,language,l.content_id,'territory_language_prioritized' FROM governance.published_heads h JOIN i18n.revision_content_links l USING(revision_id)
 WHERE territory=ANY(governance.translation_scope(l.content_id)) AND governance.public_content(l.content_id) AND NOT EXISTS(SELECT FROM i18n.translation_heads th WHERE th.content_id=l.content_id AND th.language_code=language)
 ON CONFLICT DO NOTHING;
 END IF;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'prioritize_content_language',territory,jsonb_build_object('language',language,'priority',priority,'enabled',enabled,'reason',note));
END $$;
CREATE FUNCTION governance.translation_worklist(territory uuid DEFAULT NULL) RETURNS SETOF governance.translation_work
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.require_capability('propose',CASE WHEN territory IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[territory] END);
 RETURN QUERY SELECT w.* FROM governance.translation_work w WHERE territory IS NULL OR territory=ANY(governance.translation_scope(w.required_content_id));
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_text(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.translation_worklist(uuid) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.register_language(text,text,text,text,text),governance.prioritize_language(uuid,text,integer,boolean,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.propose_translation(uuid,text,text,text,text,uuid,text),governance.review_translation(uuid,text,text),governance.publish_translation(uuid,uuid,uuid,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION api.resolve_text(uuid,text) TO egi_reader;

-- ============================================================================
-- Public Directory
-- ============================================================================
ALTER FUNCTION governance.publication_diagnostics(uuid) RENAME TO prior_directory_diagnostics;
CREATE FUNCTION governance.publication_diagnostics(target uuid) RETURNS TABLE(code text,field text)
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT * FROM governance.prior_directory_diagnostics(target)
 UNION ALL SELECT 'unpublished_parent_location','parent_location_id' FROM data.location_revisions l WHERE l.revision_id=target AND l.parent_location_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=l.parent_location_id)
$$;
CREATE VIEW api.public_territories WITH(security_barrier=true) AS
SELECT t.entity_id AS territory_id,t.code,r.revision_id,r.name_content_id,c.original_text AS name,r.timezone_name,r.country_code,public.ST_AsGeoJSON(r.boundary)::jsonb AS boundary
FROM geo.territories t JOIN governance.published_heads h USING(entity_id) JOIN geo.territory_revisions r USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=r.name_content_id;
CREATE VIEW api.public_taxonomy WITH(security_barrier=true) AS
SELECT a.territory_id,a.adoption_id,a.release_id,a.effective_from,a.effective_until,ra.axis_id,ax.code AS axis_code,ra.label AS axis_label,rt.term_id,rt.term_revision_id,l.content_id AS name_content_id,c.original_text AS name,tr.presentation_metadata
FROM taxonomy.territory_adoptions a JOIN taxonomy.release_axes ra USING(release_id) JOIN taxonomy.axes ax USING(axis_id) JOIN taxonomy.release_terms rt ON rt.release_id=a.release_id AND rt.axis_id=ra.axis_id JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id JOIN i18n.revision_content_links l ON l.revision_id=tr.revision_id AND l.field_code='name' LEFT JOIN i18n.content_units c USING(content_id);
CREATE VIEW api.source_attributions WITH(security_barrier=true) AS
SELECT DISTINCT h.entity_id,h.revision_id,r.source_id,r.name,r.homepage,r.license,c.retrieved_at,c.published_at
FROM governance.published_heads h JOIN governance.value_decisions d ON d.revision_id=h.revision_id JOIN governance.value_evidence e USING(value_decision_id) JOIN sources.assertions a USING(assertion_id) JOIN sources.normalized_subjects n USING(subject_id) JOIN sources.processing_runs p USING(run_id) JOIN sources.captures c ON c.capture_id=p.capture_id JOIN sources.datasets ds USING(dataset_id) JOIN sources.registry r USING(source_id) WHERE e.evidence_role='supporting';
CREATE VIEW api.public_sequence WITH(security_barrier=true) AS SELECT COALESCE(max(change_sequence),0) AS snapshot_sequence FROM audit.public_changes;
CREATE TABLE api.export_manifests (
 export_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),format text NOT NULL CHECK(format IN('hsds','sqlite')),
 snapshot_sequence bigint NOT NULL,schema_version text NOT NULL,policy_version text NOT NULL,territories uuid[] NOT NULL,languages text[] NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),checksum text,status text NOT NULL CHECK(status IN('building','ready','failed'))
);
-- A public text endpoint may never expose a private contact's label.
CREATE OR REPLACE FUNCTION api.resolve_text(content uuid,preferred text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,'direction',CASE WHEN t.translation_id IS NULL THEN orig.direction ELSE lang.direction END,'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class,'content_id',c.content_id)
 FROM i18n.content_units c LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred LEFT JOIN i18n.translation_publications p USING(publication_id) LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id LEFT JOIN i18n.languages lang ON lang.language_code=t.language_code LEFT JOIN i18n.languages orig ON orig.language_code=c.original_language WHERE c.content_id=content AND governance.public_content(content)
$$;
CREATE FUNCTION api.service_detail(service uuid,preferred text DEFAULT NULL,instant timestamptz DEFAULT statement_timestamp(),review_after interval DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('service_id',s.entity_id,'revision_id',s.revision_id,'publication_id',h.publication_id,'snapshot_sequence',(SELECT snapshot_sequence FROM api.public_sequence),
 'name',api.resolve_text(s.name_content_id,preferred),'description',api.resolve_text(s.description_content_id,preferred),'delivery_mode',s.delivery_mode,'operational_status',s.operational_status,'cost',jsonb_build_object('state',s.cost_state,'note',api.resolve_text(s.cost_note_content_id,preferred)),
 'valid_from',s.valid_from,'valid_until',s.valid_until,'closure_date',s.closure_date,'closure_reason',api.resolve_text(s.closure_reason_content_id,preferred),
 'place',(SELECT jsonb_build_object('location_id',p.location_id,'territory_id',p.territory_id,'area_description',api.resolve_text(p.area_description_content_id,preferred),'location_revision_id',l.revision_id,'name',api.resolve_text(l.name_content_id,preferred),'coordinate_state',l.coordinate_state,'latitude',l.latitude,'longitude',l.longitude,'parent_location_id',l.parent_location_id,'addresses',COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',a.address_kind,'formatted',a.formatted,'line1',a.line1,'locality',a.locality,'postal_code',a.postal_code,'administrative_area',a.administrative_area,'country_code',a.country_code) ORDER BY a.component_id) FROM data.addresses a WHERE a.revision_id=l.revision_id),'[]'::jsonb)) FROM data.service_places p LEFT JOIN governance.published_heads lh ON lh.entity_id=p.location_id LEFT JOIN data.location_revisions l ON l.revision_id=lh.revision_id WHERE p.revision_id=s.revision_id),
 'organizations',COALESCE((SELECT jsonb_agg(jsonb_build_object('organization_id',o.organization_id,'role',o.role_code,'revision_id',org.revision_id,'name',api.resolve_text(org.name_content_id,preferred),'description',api.resolve_text(org.description_content_id,preferred),'website',org.website) ORDER BY o.component_id) FROM data.service_organizations o JOIN governance.published_heads oh ON oh.entity_id=o.organization_id JOIN data.organization_revisions org ON org.revision_id=oh.revision_id WHERE o.revision_id=s.revision_id),'[]'::jsonb),
 'contacts',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',ep.component_id,'link_component_id',ep.link_component_id,'subject_entity_id',ep.subject_entity_id,'scope',ep.subject_scope,'channel',ep.channel_type,'value',ep.value,'purpose',ep.purpose_code,'label',api.resolve_text(ep.label_content_id,preferred),'opening',api.opening(ep.subject_entity_id,instant,'contact',ep.component_id),
 'verification',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'component_id',v.component_id,'field',v.field_code,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END)) FROM governance.verifications v JOIN governance.published_heads vh ON vh.revision_id=v.revision_id WHERE vh.entity_id=ep.subject_entity_id AND (v.scope_kind='page' OR v.component_id=ep.component_id OR (v.scope_kind='field' AND v.field_code='contact'))),'[]'::jsonb)) ORDER BY ep.sort_order,ep.component_id,ep.link_component_id)
 FROM (
 SELECT c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,c.label_content_id,c.sort_order,NULL::uuid AS link_component_id FROM data.contact_entries c WHERE c.revision_id=s.revision_id AND c.is_public
 UNION ALL
 SELECT c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(link.label_content_id,c.label_content_id),c.sort_order,link.component_id FROM data.service_contact_links link JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id JOIN data.entities e ON e.entity_id=c.entity_id WHERE link.revision_id=s.revision_id AND c.is_public
 )ep),'[]'::jsonb),
 'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,'kind',c.condition_kind,'state',c.requirement_state,'details',api.resolve_text(c.details_content_id,preferred)) ORDER BY c.component_id) FROM data.access_conditions c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'service_languages',COALESCE((SELECT jsonb_agg(jsonb_build_object('language',l.language_code,'availability',l.availability_kind,'note',api.resolve_text(l.note_content_id,preferred))) FROM data.service_languages l WHERE l.revision_id=s.revision_id),'[]'::jsonb),
 'territories',COALESCE((SELECT jsonb_agg(m.territory_id ORDER BY m.territory_id) FROM geo.service_memberships m WHERE m.revision_id=s.revision_id),'[]'::jsonb),
 'coverage',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',c.territory_id,'geometry',public.ST_AsGeoJSON(c.geometry)::jsonb,'description',api.resolve_text(c.description_content_id,preferred))) FROM geo.service_coverage c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'classifications',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',a.territory_id,'adoption_id',a.adoption_id,'release_id',a.release_id,'term_id',a.term_id,'axis',ax.code,'label',api.resolve_text(l.content_id,preferred))) FROM taxonomy.assignments a JOIN taxonomy.release_terms rt USING(release_id,term_id) JOIN taxonomy.terms t ON t.entity_id=a.term_id JOIN taxonomy.axes ax ON ax.axis_id=t.axis_id JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name' WHERE a.revision_id=s.revision_id),'[]'::jsonb),
 'weekly_hours',COALESCE((SELECT jsonb_agg(to_jsonb(w)-'entity_id'-'revision_id' ORDER BY w.schedule_id,w.iso_weekday,w.opens_at) FROM api.weekly_hours w WHERE w.revision_id=s.revision_id),'[]'::jsonb),'opening',api.opening(s.entity_id,instant),
 'sources',COALESCE((SELECT jsonb_agg(to_jsonb(a)-'entity_id'-'revision_id') FROM api.source_attributions a WHERE a.entity_id=s.entity_id),'[]'::jsonb),
 'verification',jsonb_build_object('checks',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'field',v.field_code,'component_id',v.component_id,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END) ORDER BY v.checked_at) FROM governance.verifications v WHERE v.revision_id=s.revision_id),'[]'::jsonb),'page_state',CASE WHEN EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id AND v.scope_kind='page' AND v.outcome='confirmed') THEN 'verified_with_scope' ELSE 'unverified' END,'warning',CASE WHEN NOT EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id) THEN 'no_verification' WHEN review_after IS NULL THEN 'threshold_not_configured' ELSE NULL END))
 FROM governance.published_heads h JOIN data.service_revisions s USING(revision_id) WHERE s.entity_id=service
$$;
CREATE VIEW api.public_locations WITH(security_barrier=true) AS
SELECT l.entity_id AS location_id,l.revision_id,l.name_content_id,c.original_text AS name,l.location_kind,l.parent_location_id,l.latitude,l.longitude,l.coordinate_state,
COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',a.address_kind,'formatted',a.formatted,'line1',a.line1,'locality',a.locality,'postal_code',a.postal_code,'country_code',a.country_code)) FROM data.addresses a WHERE a.revision_id=l.revision_id),'[]'::jsonb) AS addresses
FROM governance.published_heads h JOIN data.location_revisions l USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=l.name_content_id;
CREATE VIEW api.public_organizations WITH(security_barrier=true) AS
SELECT o.entity_id AS organization_id,o.revision_id,o.name_content_id,o.description_content_id,c.original_text AS name,o.organization_type,o.website
FROM governance.published_heads h JOIN data.organization_revisions o USING(revision_id) LEFT JOIN i18n.content_units c ON c.content_id=o.name_content_id;
CREATE FUNCTION api.reference_closure(territory uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
WITH RECURSIVE services AS(SELECT s.service_id,s.revision_id FROM api.discoverable_services s JOIN geo.service_memberships m USING(revision_id) WHERE m.territory_id=territory),
locations(id) AS(SELECT p.location_id FROM services s JOIN data.service_places p USING(revision_id) WHERE p.location_id IS NOT NULL UNION SELECT c.target_entity_id FROM services s JOIN data.service_contact_links c USING(revision_id) JOIN api.public_locations pl ON pl.location_id=c.target_entity_id UNION SELECT l.parent_location_id FROM locations p JOIN api.public_locations l ON l.location_id=p.id WHERE l.parent_location_id IS NOT NULL),
organizations(id) AS(SELECT o.organization_id FROM services s JOIN data.service_organizations o USING(revision_id) UNION SELECT c.target_entity_id FROM services s JOIN data.service_contact_links c USING(revision_id) JOIN api.public_organizations o ON o.organization_id=c.target_entity_id UNION SELECT o.organization_id FROM locations l JOIN api.public_locations pl ON pl.location_id=l.id JOIN data.location_organizations o ON o.revision_id=pl.revision_id),
territories(id) AS(SELECT territory UNION SELECT m.territory_id FROM services s JOIN geo.service_memberships m USING(revision_id) UNION SELECT c.territory_id FROM services s JOIN geo.service_coverage c USING(revision_id) WHERE c.territory_id IS NOT NULL)
SELECT jsonb_build_object('locations',COALESCE((SELECT jsonb_agg(to_jsonb(l)) FROM api.public_locations l JOIN locations p ON p.id=l.location_id),'[]'::jsonb),
'organizations',COALESCE((SELECT jsonb_agg(to_jsonb(o)) FROM api.public_organizations o JOIN organizations p ON p.id=o.organization_id),'[]'::jsonb),
'location_organizations',COALESCE((SELECT jsonb_agg(jsonb_build_object('location_id',l.location_id,'organization_id',o.organization_id,'role',o.role_code)) FROM api.public_locations l JOIN locations p ON p.id=l.location_id JOIN data.location_organizations o ON o.revision_id=l.revision_id),'[]'::jsonb),
'territories',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',t.id,'published',pt.territory_id IS NOT NULL,'details',to_jsonb(pt))) FROM territories t LEFT JOIN api.public_territories pt ON pt.territory_id=t.id),'[]'::jsonb))
$$;
CREATE FUNCTION api.directory_snapshot(territory uuid,preferred text DEFAULT NULL,selections jsonb DEFAULT '{}',instant timestamptz DEFAULT statement_timestamp(),only_open boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('schema_version','egi-directory-v1','snapshot_sequence',(SELECT snapshot_sequence FROM api.public_sequence),'territory_id',territory,'language_preference',preferred,'evaluated_at',instant,
 'services',COALESCE((SELECT jsonb_agg(api.service_detail(s,preferred,instant) ORDER BY s) FROM api.taxonomy_search(territory,selections,(instant AT TIME ZONE COALESCE((SELECT timezone_name FROM api.public_territories WHERE territory_id=territory),'UTC'))::date)s WHERE NOT only_open OR api.opening(s,instant)->>'status'='open'),'[]'::jsonb),
 'taxonomy',COALESCE((SELECT jsonb_agg(jsonb_build_object('adoption_id',t.adoption_id,'release_id',t.release_id,'axis_id',t.axis_id,'axis_code',t.axis_code,'axis_label',t.axis_label,'term_id',t.term_id,'term_revision_id',t.term_revision_id,'name',api.resolve_text(t.name_content_id,preferred),'presentation',t.presentation_metadata,'effective_from',t.effective_from,'effective_until',t.effective_until)) FROM api.public_taxonomy t WHERE t.territory_id=territory),'[]'::jsonb),
 'taxonomy_edges',COALESCE((SELECT jsonb_agg(jsonb_build_object('release_id',b.release_id,'child',b.child_term_id,'parent',b.parent_term_id)) FROM taxonomy.broader_links b WHERE EXISTS(SELECT FROM taxonomy.territory_adoptions a WHERE a.release_id=b.release_id AND a.territory_id=territory)),'[]'::jsonb),
 'references',api.reference_closure(territory),
 'territory',(SELECT to_jsonb(t) FROM api.public_territories t WHERE t.territory_id=territory))
 WHERE EXISTS(SELECT FROM api.public_territories WHERE territory_id=territory)
$$;
CREATE FUNCTION governance.invalidate_verification_consumers() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT FROM governance.published_heads WHERE entity_id=NEW.entity_id AND revision_id=NEW.revision_id) THEN RETURN NEW; END IF;
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
 SELECT h.entity_id,h.publication_id,'verification','scoped_verification_added' FROM governance.published_heads h WHERE h.revision_id=NEW.revision_id OR EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=NEW.entity_id) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=NEW.entity_id) OR EXISTS(SELECT FROM data.service_contact_links l WHERE l.revision_id=h.revision_id AND l.target_entity_id=NEW.entity_id);
 RETURN NEW;
END $$;
CREATE TRIGGER verification_consumers AFTER INSERT ON governance.verifications FOR EACH ROW EXECUTE FUNCTION governance.invalidate_verification_consumers();
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
 UNION SELECT a.territory_id FROM taxonomy.territory_adoptions a WHERE a.vocabulary_id=target_entity OR EXISTS(SELECT FROM taxonomy.terms t WHERE t.entity_id=target_entity AND t.vocabulary_id=a.vocabulary_id)
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.reference_closure(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.service_detail(uuid,text,timestamptz,interval),api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean) FROM PUBLIC;
GRANT SELECT ON api.public_territories,api.public_taxonomy,api.source_attributions,api.public_sequence,api.public_locations,api.public_organizations TO egi_reader;
GRANT EXECUTE ON FUNCTION api.reference_closure(uuid) TO egi_reader;
GRANT EXECUTE ON FUNCTION api.service_detail(uuid,text,timestamptz,interval),api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean) TO egi_reader;

COMMIT;
