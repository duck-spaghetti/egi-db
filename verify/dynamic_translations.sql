BEGIN;
SELECT translation_id,translation_class FROM i18n.translations WHERE false;
SELECT required_content_id,status FROM governance.translation_work WHERE false;
SELECT 1/(has_function_privilege('egi_reader','api.resolve_text(uuid,text)','EXECUTE')::integer);
ROLLBACK;
