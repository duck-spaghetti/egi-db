-- Verify egi_database:029_preparation_resolution_undo
BEGIN;
SELECT 1/(position('undoing' IN pg_get_functiondef('preparation.stamp_reference_confirmation()'::regprocedure))>0)::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.stamp_reference_confirmation()','EXECUTE'))::int;
ROLLBACK;
