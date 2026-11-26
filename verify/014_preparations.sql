-- Verify egi_database:014_preparations on pg
BEGIN;
SELECT 1/(NOT has_table_privilege('egi_editorial','preparation.inputs','SELECT'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','preparation.items','UPDATE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.authorize(uuid,boolean,boolean)','EXECUTE'))::int;
SELECT 1/(has_function_privilege('egi_editorial','preparation.save_items(uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_reader','preparation.read_workspace(uuid)','EXECUTE'))::int;
SELECT 1/(NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='preparation' AND NOT COALESCE('search_path=pg_catalog, pg_temp'=ANY(p.proconfig),false)))::int;
ROLLBACK;
