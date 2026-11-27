-- Revert egi_database:033_private_groups
BEGIN;
DROP FUNCTION preparation.purge_job_payloads(uuid);
ALTER FUNCTION preparation.purge_job_payloads_before_groups(uuid) RENAME TO purge_job_payloads;
DROP FUNCTION preparation.list_groups(uuid,integer,integer),preparation.read_group(uuid,uuid,uuid,integer,integer),preparation.undo_group(uuid,uuid,uuid),preparation.apply_group(uuid,jsonb),
 preparation.process_group_operation(uuid),preparation.read_group_operation(uuid,uuid,integer,integer),preparation.group_mapped_payload(jsonb,jsonb,jsonb,jsonb),preparation.save_group(uuid,uuid,jsonb,uuid),
 preparation.group_member(uuid,jsonb),preparation.validate_group_context(jsonb,jsonb);
DROP TABLE preparation.group_member_receipts,preparation.group_applications;
ALTER TABLE preparation.private_groups DROP CONSTRAINT private_groups_current_version_group_id_fkey;
DROP TABLE preparation.group_revisions,preparation.private_groups;
DROP FUNCTION preparation.group_receipt_guard(),preparation.get_group_context(uuid,uuid,uuid),preparation.group_catalog_context(uuid,uuid);
COMMIT;
