-- Verify egi_database:018_preparation_candidates on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','preparation.create_items(uuid,uuid,uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.create_manual_item(uuid,uuid,uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','preparation.candidate_applications','SELECT'))::int;
ROLLBACK;
