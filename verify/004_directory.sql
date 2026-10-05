-- Verify egi_database:004_directory
BEGIN;

-- ============================================================================
-- Weekly Hours
-- ============================================================================
SELECT revision_id,component_id,timezone_name FROM data.schedules WHERE false;
SELECT opens_at,closes_at,end_day_offset FROM api.weekly_hours WHERE false;
SELECT 1 / count(*) FROM governance.revision_extensions WHERE code='10_hours';
SELECT 1 / (has_function_privilege('egi_reader','api.weekly_opening(uuid,timestamptz,text,uuid)','EXECUTE')::integer);

-- ============================================================================
-- Shared Calendar
-- ============================================================================
SELECT revision_id,calendar_id,event_kind FROM governance.calendar_event_versions WHERE false;
SELECT event_version_id,effect_kind FROM data.schedule_exception_effects WHERE false;
SELECT 1/count(*) FROM governance.revision_extensions WHERE code='20_calendar_event';

-- ============================================================================
-- Territorial Taxonomy
-- ============================================================================
SELECT adoption_id,release_id,territory_id FROM taxonomy.assignments WHERE false;
SELECT term_revision_id FROM taxonomy.release_terms WHERE false;
SELECT 1/count(*) FROM pg_trigger WHERE tgrelid='taxonomy.broader_links'::regclass AND tgname='acyclic';

-- ============================================================================
-- Dynamic Translations
-- ============================================================================
SELECT translation_id,translation_class FROM i18n.translations WHERE false;
SELECT required_content_id,status FROM governance.translation_work WHERE false;
SELECT 1/(has_function_privilege('egi_reader','api.resolve_text(uuid,text)','EXECUTE')::integer);

-- ============================================================================
-- Public Directory
-- ============================================================================
SELECT snapshot_sequence FROM api.public_sequence;
SELECT source_id,name,homepage,license FROM api.source_attributions WHERE false;
SELECT 1/(has_function_privilege('egi_reader','api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean)','EXECUTE')::integer);

ROLLBACK;
