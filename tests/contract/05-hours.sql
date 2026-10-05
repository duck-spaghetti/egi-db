BEGIN;
\ir helpers.sql
\ir fixtures.sql
CREATE FUNCTION pg_temp.schedule(days jsonb,zone text DEFAULT 'Europe/Rome') RETURNS jsonb LANGUAGE sql AS $$
SELECT jsonb_build_object('name','Scheduled offer','description','Weekly test','delivery_mode','telephone','contacts','[{"channel_type":"phone","value":"contact"}]'::jsonb,'schedules',jsonb_build_array(jsonb_build_object('timezone',zone,'completeness','complete','days',days))) $$;
DO $$ DECLARE rev uuid; owner uuid; newrev uuid; restored uuid; body jsonb; days jsonb; result jsonb; BEGIN
 -- Complete weekday coverage, Monday overnight and two adjacent Tuesday shifts.
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state',CASE WHEN n IN(1,2) THEN 'intervals' ELSE 'closed' END,'completeness','complete','intervals',CASE n WHEN 1 THEN '[{"opens":"22:00","closes":"02:00","end_day_offset":1}]'::jsonb WHEN 2 THEN '[{"opens":"09:00","closes":"12:00"},{"opens":"12:00","closes":"17:00"}]'::jsonb ELSE '[]'::jsonb END)) INTO days FROM generate_series(1,7) n;
 body:=pg_temp.schedule(days); rev:=pg_temp.save('service',body); SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev; PERFORM pg_temp.publish(rev);
 SELECT component_id INTO newrev FROM data.schedule_intervals WHERE revision_id=rev LIMIT 1;
 PERFORM governance.verify_revision(rev,'component',NULL,newrev,'2025-01-01Z','phone','fixture:interval-check','confirmed');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM governance.verifications WHERE revision_id=rev AND component_id=newrev),'single interval can be verified');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 00:00Z')->>'status'='open','previous-day spillover');
 result:=api.weekly_opening(owner,'2026-01-06 00:00Z');
 PERFORM pg_temp.assert_true((result->>'closes_at')::timestamptz='2026-01-06 01:00Z' AND (result->>'seconds_until_close')::numeric=3600,'previous-day spillover closes in one elapsed hour');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 01:00Z')->>'status'='closed','half-open endpoint');
 result:=api.weekly_opening(owner,'2026-01-06 10:00Z');
 PERFORM pg_temp.assert_true((result->>'closes_at')::timestamptz='2026-01-06 16:00Z' AND (result->>'seconds_until_close')::numeric=21600,'adjacent intervals merge for countdown');
 newrev:=pg_temp.save('service',body-'schedules',owner,rev,rev);
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 10:00Z')->>'status'='open','draft hours hidden');
 PERFORM pg_temp.publish(newrev,rev);
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 10:00Z')->>'status'='unknown','absent hours unknown');
 restored:=governance.restore_revision(rev,newrev,newrev,'Restore hours'); PERFORM pg_temp.publish(restored,newrev);
 PERFORM pg_temp.assert_true((SELECT count(*)=3 FROM data.schedule_intervals WHERE revision_id=restored),'restore includes intervals');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 10:00Z')->>'status'='open','restored opening');
 -- DST repeated civil interval occurs twice, with a closed span between.
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state',CASE WHEN n=7 THEN 'intervals' ELSE 'closed' END,'completeness','complete','intervals',CASE WHEN n=7 THEN '[{"opens":"02:15","closes":"02:45"}]'::jsonb ELSE '[]'::jsonb END)) INTO days FROM generate_series(1,7) n;
 rev:=pg_temp.save('service',pg_temp.schedule(days)); SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev; PERFORM pg_temp.publish(rev);
 result:=api.weekly_opening(owner,'2026-10-25 00:30Z');
 PERFORM pg_temp.assert_true(result->>'status'='open' AND (result->>'closes_at')::timestamptz='2026-10-25 00:45Z','first repeated occurrence');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-10-25 00:50Z')->>'status'='closed','closed between repeated intervals');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-10-25 01:30Z')->>'status'='open','second repeated occurrence');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-03-29 01:15Z')->>'status'='closed','skipped interval absent');
 -- Continuous span across spring/fall clock changes uses actual elapsed seconds.
 days:=jsonb_set(days,'{6,intervals}','[{"opens":"01:00","closes":"04:00"}]');
 newrev:=pg_temp.save('service',pg_temp.schedule(days),owner,rev,rev);PERFORM pg_temp.publish(newrev,rev);
 result:=api.weekly_opening(owner,'2026-03-29 00:30Z');
 PERFORM pg_temp.assert_true(result->>'status'='open' AND (result->>'seconds_until_close')::numeric=5400,'spring real elapsed countdown');
 result:=api.weekly_opening(owner,'2026-10-24 23:30Z');
 PERFORM pg_temp.assert_true(result->>'status'='open' AND (result->>'seconds_until_close')::numeric=12600,'fall real elapsed countdown');
 -- Date-window transitions must not mistake historical schedules for a conflict.
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state','intervals','completeness','complete','intervals','[{"opens":"09:00","closes":"17:00"}]'::jsonb)) INTO days FROM generate_series(1,7)n;
 body:=pg_temp.schedule(days);
 body:=jsonb_set(body,'{schedules}',jsonb_build_array((body->'schedules'->0)||'{"valid_until":"2026-01-05"}'::jsonb,(body->'schedules'->0)||'{"valid_from":"2026-01-06"}'::jsonb));
 rev:=pg_temp.save('service',body);SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;PERFORM pg_temp.publish(rev);
 PERFORM pg_temp.assert_true(api.opening(owner,'2026-01-06 10:00Z')->>'status'='open','dated nonoverlapping schedules');
 -- 24h, partial unknown and scoped hours.
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state','intervals','completeness','complete','intervals','[{"opens":"00:00","closes":"00:00","end_day_offset":1}]'::jsonb)) INTO days FROM generate_series(1,7)n;
 rev:=pg_temp.save('service',pg_temp.schedule(days,'Asia/Kolkata'));SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev; PERFORM pg_temp.publish(rev);
 result:=api.weekly_opening(owner,'2026-01-06 10:00Z');
 PERFORM pg_temp.assert_true(result->>'status'='open' AND result->>'closes_at' IS NULL,'24h no fabricated closing');
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 10:00Z','intake')->>'status'='unknown','scope independent');
 PERFORM pg_temp.expect_error(format('SELECT pg_temp.save(%L,%L)','service',pg_temp.schedule(days,'Unknown/Zone')),'22023','unknown_timezone');
 days:=jsonb_build_array(jsonb_build_object('weekday',2,'state','intervals','completeness','partial','intervals','[{"opens":"09:00","closes":"10:00"}]'::jsonb));
 rev:=pg_temp.save('service',pg_temp.schedule(days));SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;PERFORM pg_temp.publish(rev);
 PERFORM pg_temp.assert_true(api.weekly_opening(owner,'2026-01-06 11:00Z')->>'status'='unknown','partial outside intervals uncertain');
 PERFORM pg_temp.expect_error(format('INSERT INTO data.schedule_days SELECT revision_id,component_id,7,%L,%L FROM data.schedules WHERE revision_id=%L','closed','complete',rev),'55000');
END $$;
ROLLBACK;
