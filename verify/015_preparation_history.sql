-- Verify egi_database:015_preparation_history on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','preparation.read_history(uuid,uuid,bigint,integer)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.save_items_initial(uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(has_function_privilege('egi_retention','preparation.purge_trash()','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.purge_trash()','EXECUTE'))::int;
SELECT 1/(NOT has_table_privilege('egi_retention','preparation.inputs','DELETE'))::int;
ROLLBACK;
