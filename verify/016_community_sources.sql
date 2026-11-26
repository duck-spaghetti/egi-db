-- Verify egi_database:016_community_sources on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','editorial.register_community_source(jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_intake','editorial.register_community_source(jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','editorial.community_source_requests','INSERT'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','governance.community_source_admissions','INSERT'))::int;
SELECT 1/(has_table_privilege('egi_editorial','governance.community_source_admissions','SELECT'))::int;
ROLLBACK;
