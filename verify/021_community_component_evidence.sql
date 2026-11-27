-- Verify egi_database:021_community_component_evidence on pg
BEGIN;
SELECT 1/(NOT has_function_privilege('egi_editorial','editorial.community_align_baseline(jsonb,jsonb)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text)','EXECUTE'))::int;
ROLLBACK;
