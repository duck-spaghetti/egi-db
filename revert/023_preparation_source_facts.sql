-- Revert egi_database:023_preparation_source_facts
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.item_versions WHERE payload->'schema_version'='2'::jsonb) OR
  EXISTS(SELECT FROM editorial.community_snapshots WHERE values->'schema_version'='2'::jsonb) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='source_facts_in_use'; END IF;
END $$;
DROP TRIGGER source_fact_version ON preparation.item_versions;
DROP FUNCTION preparation.guard_source_fact_version();
DROP FUNCTION preparation.save_items_initial(uuid,jsonb,uuid);
ALTER FUNCTION preparation.save_items_initial_v1(uuid,jsonb,uuid) RENAME TO save_items_initial;
DROP FUNCTION preparation.validate_payload(uuid,jsonb);
DROP FUNCTION preparation.validate_source_facts(uuid,jsonb);
DROP FUNCTION preparation.citation_unchanged(jsonb,jsonb,jsonb);
ALTER FUNCTION preparation.validate_payload_v1(uuid,jsonb) RENAME TO validate_payload;
DROP TABLE preparation.fact_identities;
COMMIT;
