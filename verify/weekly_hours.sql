BEGIN;
SELECT revision_id,component_id,timezone_name FROM data.schedules WHERE false;
SELECT opens_at,closes_at,end_day_offset FROM api.weekly_hours WHERE false;
SELECT 1 / count(*) FROM governance.revision_extensions WHERE code='10_hours';
SELECT 1 / (has_function_privilege('egi_reader','api.weekly_opening(uuid,timestamptz,text,uuid)','EXECUTE')::integer);
ROLLBACK;
