-- Verify egi_database:013_editorial_observations on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','editorial.record_observation(text,jsonb,text,text)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_reader','editorial.record_observation(text,jsonb,text,text)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_intake','editorial.record_observation(text,jsonb,text,text)','EXECUTE'))::int;
ROLLBACK;
