BEGIN;
SELECT revision_id,calendar_id,event_kind FROM governance.calendar_event_versions WHERE false;
SELECT event_version_id,effect_kind FROM data.schedule_exception_effects WHERE false;
SELECT 1/count(*) FROM governance.revision_extensions WHERE code='20_calendar_event';
ROLLBACK;
