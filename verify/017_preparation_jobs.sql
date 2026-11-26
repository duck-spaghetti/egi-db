-- Verify egi_database:017_preparation_jobs on pg
BEGIN;
SELECT 1/(NOT has_table_privilege('egi_preparation_worker','preparation.inputs','SELECT'))::int;
SELECT 1/(NOT has_table_privilege('egi_preparation_worker','preparation.jobs','SELECT'))::int;
SELECT 1/(has_function_privilege('egi_preparation_worker','preparation.claim_job(uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','preparation.read_input(uuid,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.start_dispatch(uuid,text)','EXECUTE'))::int;
SELECT 1/(NOT pg_has_role('egi_preparation_worker','egi_writer','MEMBER'))::int;
ROLLBACK;
