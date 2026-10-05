-- Revert egi_database:weekly_hours from pg
BEGIN;
DROP VIEW api.weekly_hours;
DROP FUNCTION api.weekly_opening(uuid,timestamptz,text,uuid);
DROP FUNCTION governance.clock_changes(text,timestamptz,timestamptz);
DROP FUNCTION governance.civil_occurrences(timestamp,text);
DROP FUNCTION governance.weekly_state(uuid,text,uuid,timestamptz);
DROP FUNCTION governance.eligible_schedules(uuid,text,uuid,timestamptz);
DELETE FROM governance.revision_extensions WHERE code='10_hours';
DROP FUNCTION governance.save_schedules(uuid,uuid,text,jsonb,jsonb,text);
DROP TABLE data.schedule_intervals;
DROP TABLE data.schedule_days;
DROP TABLE data.schedules;
DROP FUNCTION governance.check_schedule_interval();
DROP FUNCTION governance.check_schedule();
COMMIT;
