-- Verify egi_database:028_preparation_reference_lookup
BEGIN;
SELECT 1/(position('organization_ids' IN pg_get_functiondef('preparation.catalog(jsonb)'::regprocedure))>0)::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.catalog(jsonb)','EXECUTE'))::int;
ROLLBACK;
