-- Verify egi_database:020_community_acceptance on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','editorial.accept_community_item(uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','editorial.community_evidence','SELECT'))::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','editorial.accept_community_item(uuid,jsonb,uuid)','EXECUTE'))::int;
SELECT 1/(EXISTS(SELECT FROM pg_constraint WHERE conrelid='editorial.community_resolutions'::regclass AND contype='f'
 AND confrelid='governance.entity_revisions'::regclass AND cardinality(conkey)=2))::int;
ROLLBACK;
