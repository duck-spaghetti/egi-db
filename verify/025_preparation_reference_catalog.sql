-- Verify egi_database:025_preparation_reference_catalog
BEGIN;
SELECT 1/(to_regprocedure('preparation.reference_catalog(uuid,jsonb)') IS NOT NULL)::int;
SELECT 1/(has_function_privilege('egi_editorial','preparation.reference_catalog(uuid,jsonb)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.catalog(jsonb)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','preparation.validate_reference(jsonb,jsonb,jsonb)','EXECUTE'))::int;
ROLLBACK;
