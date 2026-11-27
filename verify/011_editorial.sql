-- Verify egi_database:011_editorial
-- Behaviour (intake, claims, closure, retention) is covered by tests/contract/14-editorial.sql.
BEGIN;
SELECT open,window_limit,window_length,daily_limit FROM editorial.intake_settings WHERE false;
SELECT contribution_id,kind,category,service_id,public_revision_id,author_kind,text,contact,state,waiting_reason,
 claimed_by,outcome,outcome_reason,publication_id,closed_by,closed_at,created_at,contact_deleted_at,text_deleted_at
 FROM editorial.contributions WHERE false;
SELECT proposal_id,contribution_id,field,value,decision,decided_value,decision_note,decided_by,decided_at FROM editorial.proposals WHERE false;
SELECT event_id,contribution_id,actor_id,action,details,created_at FROM editorial.events WHERE false;
DO $$ DECLARE relation text; operation text; BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_intake' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls)
  OR NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_retention' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls)
  OR pg_has_role('egi_intake','egi_writer','MEMBER') OR pg_has_role('egi_retention','egi_writer','MEMBER') THEN
  RAISE EXCEPTION 'editorial_roles_invalid';
 END IF;
 FOREACH relation IN ARRAY ARRAY['intake_settings','contributions','proposals','events'] LOOP
  IF has_table_privilege('egi_intake','editorial.'||relation,'SELECT') OR has_table_privilege('egi_intake','editorial.'||relation,'INSERT')
   OR has_table_privilege('egi_editorial','editorial.'||relation,'SELECT') OR has_table_privilege('egi_reader','editorial.'||relation,'SELECT')
   OR has_table_privilege('egi_retention','editorial.'||relation,'UPDATE') OR has_table_privilege('egi_sync','editorial.'||relation,'SELECT') THEN
   RAISE EXCEPTION 'editorial_storage_privileges_invalid: %',relation;
  END IF;
 END LOOP;
 IF NOT has_function_privilege('egi_intake','editorial.submit_contribution(text,uuid,text,text,text,boolean,jsonb,text)','EXECUTE')
  OR has_function_privilege('egi_editorial','editorial.submit_contribution(text,uuid,text,text,text,boolean,jsonb,text)','EXECUTE')
  OR has_function_privilege('egi_reader','editorial.submit_contribution(text,uuid,text,text,text,boolean,jsonb,text)','EXECUTE')
  OR NOT has_function_privilege('egi_retention','editorial.purge_expired_contributions()','EXECUTE')
  OR has_function_privilege('egi_editorial','editorial.purge_expired_contributions()','EXECUTE') THEN
  RAISE EXCEPTION 'editorial_entry_privileges_invalid';
 END IF;
 FOREACH operation IN ARRAY ARRAY['editorial.list_contributions(boolean)','editorial.read_contribution(uuid)',
  'editorial.claim(uuid,text,uuid)','editorial.set_waiting(uuid,text)','editorial.decide_proposal(uuid,text,jsonb,text)',
  'editorial.close_contribution(uuid,text,text,uuid)','editorial.set_intake(boolean,integer,integer)'] LOOP
  IF NOT has_function_privilege('egi_editorial',operation,'EXECUTE') OR has_function_privilege('egi_intake',operation,'EXECUTE') THEN
   RAISE EXCEPTION 'editorial_operation_privileges_invalid: %',operation;
  END IF;
 END LOOP;
END $$;
ROLLBACK;
