-- Verify egi_database:022_community_evidence_context on pg
BEGIN;
SELECT 1/(NOT has_function_privilege('egi_editorial','editorial.community_context_matches(jsonb,jsonb,text[],text[])','EXECUTE'))::int;
ROLLBACK;
