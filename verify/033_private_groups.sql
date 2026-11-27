-- Verify egi_database:033_private_groups
BEGIN;
SELECT group_id,current_version FROM preparation.private_groups WHERE false;
SELECT version,body FROM preparation.group_revisions WHERE false;
SELECT operation_id,request_key,selection FROM preparation.group_applications WHERE false;
SELECT item_id,status,after_version FROM preparation.group_member_receipts WHERE false;
SELECT 1/CASE WHEN has_function_privilege('egi_editorial','preparation.apply_group(uuid,jsonb)','EXECUTE')
 AND NOT has_function_privilege('egi_editorial','preparation.process_group_operation(uuid)','EXECUTE')
 AND NOT has_table_privilege('egi_editorial','preparation.group_revisions','SELECT')
 AND NOT has_table_privilege('egi_preparation_worker','preparation.group_member_receipts','SELECT') THEN 1 ELSE 0 END;
ROLLBACK;
