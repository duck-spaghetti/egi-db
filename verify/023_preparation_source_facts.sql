-- Verify egi_database:023_preparation_source_facts
BEGIN;
SELECT 1/(to_regclass('preparation.fact_identities') IS NOT NULL)::int;
SELECT 1/(EXISTS(SELECT FROM pg_trigger WHERE tgname='source_fact_version' AND tgrelid='preparation.item_versions'::regclass))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','preparation.fact_identities','SELECT,INSERT,UPDATE,DELETE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.validate_source_facts(uuid,jsonb)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','preparation.citation_unchanged(jsonb,jsonb,jsonb)','EXECUTE'))::int;
ROLLBACK;
