-- Verify egi_database:009_contact_protection_register
-- Behavioral publication/concurrency fixtures remain separate.
BEGIN;
DO $$ DECLARE relation text; operation record; BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_privacy_moderator' AND NOT rolcanlogin
  AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls)
  OR pg_has_role('egi_sync','egi_privacy_moderator','MEMBER')
  OR has_function_privilege('egi_sync','governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)','EXECUTE')
  OR has_function_privilege('egi_writer','governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)','EXECUTE')
  OR has_function_privilege('egi_reader','governance.read_contact_protections(uuid)','EXECUTE')
  OR NOT has_function_privilege('egi_reader','api.service_contact_visible(uuid,uuid,uuid,uuid)','EXECUTE')
  OR NOT has_function_privilege('egi_sync','governance.read_contact_protections(uuid)','EXECUTE')
  OR NOT has_function_privilege('egi_privacy_moderator','governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)','EXECUTE') THEN
  RAISE EXCEPTION 'contact_protection_privileges_invalid';
 END IF;
 FOREACH relation IN ARRAY ARRAY['contact_protections','contact_protection_scopes','contact_protection_resolutions'] LOOP
  IF has_table_privilege('egi_reader','governance.'||relation,'SELECT')
   OR has_table_privilege('egi_sync','governance.'||relation,'INSERT')
   OR has_table_privilege('egi_writer','governance.'||relation,'UPDATE') THEN
   RAISE EXCEPTION 'contact_protection_storage_privileges_invalid';
  END IF;
 END LOOP;
 IF governance.protection_phone_keys('06 45460313 / 06 45460314')<>ARRAY['0645460313','0645460314']
  OR governance.protection_phone_keys('Telefono: +39 06/45460313/4')<>ARRAY['0645460313','0645460314']
  OR governance.protection_phone_keys('0039 06 45460314')<>ARRAY['0645460314']
  OR governance.protection_phone_keys('06'||chr(8201)||'45460313/4')<>ARRAY['0645460313','0645460314']
  OR governance.protection_contact_keys('other','06.45.4603',NULL)<>ARRAY['06454603']
  OR governance.protection_contact_keys('other','06 - 45 - 4603',NULL)<>ARRAY['06454603']
  OR cardinality(governance.protection_contact_keys('other','03 - 12 - 2025',NULL))<>0
  OR governance.protection_contact_keys('other','Tel.06-12-2025',NULL)<>ARRAY['06122025']
  OR cardinality(governance.protection_phone_keys('06 45460313/4/5'))<>0
  OR NOT governance.protection_phone_uncertain('other','06 45460313/4/5',NULL)
  OR NOT governance.protection_phone_uncertain('other','da chiedere','Telefono')
  OR governance.protection_phone_uncertain('other','03/12/2025',NULL)
  OR governance.protection_phone_uncertain('other','03 - 12 - 2025',NULL)
  OR governance.protection_phone_uncertain('email','a3/4@example.invalid',NULL)
  OR governance.protection_phone_uncertain('other','www.example.invalid/a3/4',NULL) THEN
  RAISE EXCEPTION 'contact_protection_matching_invalid';
 END IF;
 IF governance.contact_allowed_by_protection('{"numbers":["06122025"],"phone_hold":false}',
      'other','06-12-2025',NULL,false)
  OR governance.contact_allowed_by_protection('{"numbers":["0645460314"],"phone_hold":false}',
      'other','06 45460313 / 06 45460314',NULL,false)
  OR governance.contact_allowed_by_protection('{"numbers":[],"phone_hold":true}',
      'whatsapp','0645460314',NULL,true)
  OR NOT governance.contact_allowed_by_protection('{"numbers":[],"phone_hold":true}',
      'phone','0645460314',NULL,false)
  OR NOT governance.contact_allowed_by_protection('{"numbers":[],"phone_hold":true}',
      'email','public@example.invalid',NULL,true) THEN
  RAISE EXCEPTION 'contact_protection_projection_invalid';
 END IF;
 FOR operation IN SELECT p.proname,p.proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='governance' AND p.proname IN(
   'protection_phone_whitespace','protection_phone_text','protection_phone_key','protection_phone_keys','protection_phone_uncertain','protection_phone_labelled','protection_contact_keys',
   'protection_service_group','effective_contact_protections','contact_allowed_by_protection',
   'read_contact_protections','retain_current_contact_protections','retain_contact_protection_context','propagate_contact_protection_scopes','capture_private_contact_revision',
   'capture_publication_contact_protections','refresh_contact_protection_scopes','publish_contact_protection_resolution') LOOP
  IF NOT COALESCE(operation.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'],false) THEN
   RAISE EXCEPTION 'contact_protection_search_path_invalid';
  END IF;
 END LOOP;
 IF NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='api' AND p.proname='service_contact_visible' AND p.prosecdef
   AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp']) THEN
  RAISE EXCEPTION 'contact_visibility_search_path_invalid';
 END IF;
 PERFORM api.linked_service_supplements(NULL,'it');
END $$;
ROLLBACK;
