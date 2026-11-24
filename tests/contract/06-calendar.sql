BEGIN;
\ir helpers.sql
\ir fixtures.sql
DO $$ DECLARE calendar uuid; event uuid; event_owner uuid; changed uuid; schedule uuid:='a1000000-0000-0000-0000-000000000001'; rev uuid; owner uuid; days jsonb; body jsonb; result jsonb; before_seq bigint; second_event uuid; BEGIN
 calendar:=governance.create_calendar('shared','Shared advisory calendar');
 event:=pg_temp.save('calendar_event',jsonb_build_object('name','Public holiday','calendar_id',calendar,'date_from','2026-01-06','date_until','2026-01-06'));
 SELECT entity_id INTO event_owner FROM governance.entity_revisions WHERE revision_id=event;
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state','intervals','completeness','complete','intervals','[{"opens":"09:00","closes":"17:00"}]'::jsonb)) INTO days FROM generate_series(1,7)n;
 body:=jsonb_build_object('name','Calendar offer','description','Calendar contract','delivery_mode','telephone','contacts','[{"channel_type":"phone","value":"contact"}]'::jsonb,'schedules',jsonb_build_array(jsonb_build_object('component_id',schedule,'timezone','Europe/Rome','completeness','complete','days',days)),'calendar_links',jsonb_build_array(jsonb_build_object('schedule_id',schedule,'calendar_id',calendar)));
 rev:=pg_temp.save('service',body);SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;PERFORM pg_temp.publish(rev);
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-06 10:00Z')->>'status'='open','pending advisory hidden');
 SELECT max(change_sequence) INTO before_seq FROM audit.public_changes;PERFORM pg_temp.publish(event);
 result:=api.opening(owner,'2026-01-06 10:00Z');
 PERFORM pg_temp.assert_true(result->>'status'='unknown' AND (result->>'contact_warning')::boolean AND result->>'closes_at' IS NULL,'default holiday warns without countdown');
 PERFORM pg_temp.assert_true((SELECT max(change_sequence)>before_seq FROM audit.public_changes),'calendar invalidates consumers');
 changed:=pg_temp.save('calendar_event',jsonb_build_object('name','Confirmed holiday','calendar_id',calendar,'date_from','2026-01-06','date_until','2026-01-06','event_kind','confirmed_change'),event_owner,event,event);PERFORM pg_temp.publish(changed,event);
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-06 10:00Z')->>'status'='unknown','confirmed event needs explicit supported effect');
 body:=jsonb_set(body,'{calendar_links,0,effects}',jsonb_build_array(jsonb_build_object('event_version_id',changed,'kind','closed')));
 event:=pg_temp.save('service',body,owner,rev,rev);PERFORM pg_temp.publish(event,rev);
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-06 10:00Z')->>'status'='closed','confirmed closure');
 body:=jsonb_set(body,'{calendar_links,0,effects}',jsonb_build_array(jsonb_build_object('event_version_id',changed,'kind','replace','intervals','[{"opens":"11:00","closes":"12:00"},{"opens":"12:00","closes":"13:00"}]'::jsonb)));
 rev:=pg_temp.save('service',body,owner,event,event);PERFORM pg_temp.publish(rev,event);
 result:=api.opening(owner,'2026-01-06 10:30Z');
 PERFORM pg_temp.assert_true(result->>'status'='open' AND (result->>'closes_at')::timestamptz='2026-01-06 12:00Z','replacement intervals and adjacent closing');
 body:=jsonb_set(body,'{calendar_links,0,effects}',jsonb_build_array(jsonb_build_object('event_version_id',changed,'kind','replace','intervals','[{"opens":"22:00","closes":"02:00","end_day_offset":1}]'::jsonb)));
 event:=pg_temp.save('service',body,owner,rev,rev);PERFORM pg_temp.publish(event,rev);
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-07 00:00Z')->>'status'='open','exception previous-day spillover');
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-07 01:00Z')->>'status'='closed','exception half-open closing');
 rev:=event;
 second_event:=pg_temp.save('calendar_event',jsonb_build_object('name','Conflicting holiday','calendar_id',calendar,'date_from','2026-01-06','date_until','2026-01-06','event_kind','confirmed_change'));PERFORM pg_temp.publish(second_event);
 body:=jsonb_set(body,'{calendar_links,0,effects}',(body#>'{calendar_links,0,effects}')||jsonb_build_array(jsonb_build_object('event_version_id',second_event,'kind','closed')));
 event:=pg_temp.save('service',body,owner,rev,rev);PERFORM pg_temp.publish(event,rev);
 result:=api.opening(owner,'2026-01-06 10:30Z');PERFORM pg_temp.assert_true(result->>'status'='unknown' AND result->>'basis'='conflicting_calendar_effects','conflicts do not last-write-win');
 rev:=governance.restore_revision(rev,event,event,'Restore calendar aggregate');PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM data.schedule_exception_effects WHERE revision_id=rev),'restore calendar aggregate');
END $$;
ROLLBACK;
