-- Verify egi_database:006_hardening
BEGIN;

-- ============================================================================
-- Session temporary objects
-- ============================================================================
DO $$ DECLARE found text; BEGIN
 IF to_regprocedure('governance.withdraw_orphan_location(uuid,uuid,text)') IS NULL
  OR NOT has_table_privilege('egi_sync','governance.revision_territories','SELECT')
  OR to_regclass('i18n.content_units_owner_field') IS NULL
  OR to_regclass('governance.value_decisions_revision') IS NULL
  OR to_regclass('governance.sync_entries_service') IS NULL THEN
  RAISE EXCEPTION 'sync_review_contract_missing';
 END IF;
 IF has_function_privilege('egi_reader','governance.withdraw_orphan_location(uuid,uuid,text)','EXECUTE')
  OR NOT has_function_privilege('egi_sync','governance.withdraw_orphan_location(uuid,uuid,text)','EXECUTE') THEN
  RAISE EXCEPTION 'orphan_withdrawal_privilege_mismatch';
 END IF;
 SELECT string_agg(p.oid::regprocedure::text,', ') INTO found FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f'
  AND NOT COALESCE('search_path=pg_catalog, pg_temp'=ANY(p.proconfig),false);
 IF found IS NOT NULL THEN RAISE EXCEPTION 'unsafe_search_path: %',found; END IF;
 IF EXISTS(SELECT FROM pg_database d CROSS JOIN LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a
  WHERE d.datname=current_database() AND a.grantee=0 AND a.privilege_type='TEMPORARY') THEN
  RAISE EXCEPTION 'public_temporary_leak';
 END IF;
 SELECT string_agg(r,', ') INTO found FROM unnest(ARRAY['egi_reader','egi_writer','egi_sync']) r
  WHERE has_database_privilege(r,current_database(),'TEMPORARY');
 IF found IS NOT NULL THEN RAISE EXCEPTION 'role_temporary_leak: %',found; END IF;
END $$;

ROLLBACK;
