-- Verify egi_database:026_community_reference_acceptance
BEGIN;
SELECT 1/(to_regclass('editorial.community_fact_resolutions') IS NOT NULL)::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','editorial.community_fact_resolutions','INSERT'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','editorial.apply_community_facts(editorial.community_snapshots,jsonb,jsonb)','EXECUTE'))::int;
ROLLBACK;
