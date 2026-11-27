-- Verify egi_database:019_community_submissions on pg
BEGIN;
SELECT 1/(has_function_privilege('egi_editorial','preparation.submit_item(uuid,uuid,uuid,uuid)','EXECUTE'))::int;
SELECT 1/(NOT has_table_privilege('egi_editorial','editorial.community_snapshots','SELECT'))::int;
SELECT 1/(NOT has_function_privilege('egi_intake','editorial.read_community_snapshot(uuid)','EXECUTE'))::int;
SELECT 1/(NOT EXISTS(SELECT FROM pg_constraint WHERE conrelid='editorial.community_snapshots'::regclass AND contype='f'
 AND confrelid IN ('preparation.workspaces'::regclass,'preparation.items'::regclass,'preparation.item_versions'::regclass)))::int;
ROLLBACK;
