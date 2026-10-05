-- Deploy egi_database:weekly_hours [aggregate_extensions] to pg
BEGIN;
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
COMMIT;
