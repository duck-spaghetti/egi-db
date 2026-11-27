-- Verify egi_database:010_access
-- Behaviour (sessions, invitations, release) is covered by tests/contract/13-access.sql.
BEGIN;
SELECT account_id,actor_id,login_name,role,state,created_at,created_by FROM access.accounts WHERE false;
SELECT identity_id,account_id,kind,secret,issuer,subject,created_at FROM access.identities WHERE false;
SELECT invitation_id,account_id,token_hash,created_by,created_at,expires_at,used_at,revoked_at FROM access.invitations WHERE false;
SELECT session_id,account_id,token_hash,method,second_factor,created_at,last_seen_at,expires_at,revoked_at FROM access.sessions WHERE false;
SELECT transaction_id,session_id,actor_id,created_at FROM access.request_actors WHERE false;
SELECT event_id,account_id,actor_id,action,details,created_at FROM access.events WHERE false;
DO $$ DECLARE relation text; operation text; BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_editorial' AND NOT rolcanlogin AND NOT rolsuper
   AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls)
  OR NOT pg_has_role('egi_editorial','egi_writer','MEMBER')
  OR pg_has_role('egi_editorial','egi_privacy_moderator','MEMBER')
  OR pg_has_role('egi_sync','egi_editorial','MEMBER') THEN
  RAISE EXCEPTION 'editorial_role_invalid';
 END IF;
 FOREACH relation IN ARRAY ARRAY['accounts','identities','invitations','sessions','request_actors','events'] LOOP
  IF has_table_privilege('egi_editorial','access.'||relation,'SELECT')
   OR has_table_privilege('egi_reader','access.'||relation,'SELECT')
   OR has_table_privilege('egi_sync','access.'||relation,'SELECT') THEN
   RAISE EXCEPTION 'access_storage_privileges_invalid';
  END IF;
 END LOOP;
 FOREACH operation IN ARRAY ARRAY['access.verify_session(text)','access.open_session(uuid,text,text,boolean)',
  'access.accept_invitation(text,text,text,text,text,text)','access.create_account(text,text,text,text)',
  'governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)'] LOOP
  IF NOT has_function_privilege('egi_editorial',operation,'EXECUTE')
   OR has_function_privilege('egi_reader',operation,'EXECUTE') OR has_function_privilege('egi_sync',operation,'EXECUTE') THEN
   RAISE EXCEPTION 'access_operation_privileges_invalid: %',operation;
  END IF;
 END LOOP;
 FOREACH operation IN ARRAY ARRAY['access.bootstrap_admin(text,text,text)','access.create_person(text,text,text,text,uuid)',
  'access.create_invitation(uuid,text,uuid)','access.require_admin()'] LOOP
  IF has_function_privilege('egi_editorial',operation,'EXECUTE') THEN
   RAISE EXCEPTION 'access_owner_operation_exposed: %',operation;
  END IF;
 END LOOP;
 IF position('editorial_login' IN (SELECT prosrc FROM pg_proc WHERE oid='governance.current_actor()'::regprocedure))=0
  OR position('release_protection' IN (SELECT prosrc FROM pg_proc WHERE oid='governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)'::regprocedure))=0
  OR position('release_protection' IN pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='actor_grants_capability_check')))=0
  OR (SELECT attnotnull FROM pg_attribute WHERE attrelid='governance.actors'::regclass AND attname='database_role') THEN
  RAISE EXCEPTION 'access_actor_contract_invalid';
 END IF;
END $$;
ROLLBACK;
