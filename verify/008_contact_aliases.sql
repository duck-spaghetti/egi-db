-- Verify egi_database:008_contact_aliases; separate fixtures test eligibility.
BEGIN;
DO $$ BEGIN
 IF NOT has_function_privilege('egi_reader','api.linked_service_supplements(uuid,text)','EXECUTE')
  OR has_function_privilege('egi_reader','governance.contact_aliases(text,text)','EXECUTE')
  OR has_table_privilege('egi_reader','data.contact_entries','SELECT') THEN
  RAISE EXCEPTION 'contact_alias_privileges_invalid';
 END IF;
 IF NOT (governance.contact_aliases('phone','06 45460313/4') @> ARRAY['number:0645460313','number:0645460314'])
  OR NOT (governance.contact_aliases('whatsapp','+39 06 45460313/4') && governance.contact_aliases('phone','0039 06 45460314'))
  OR NOT (governance.contact_aliases('phone','Tel. 06 45460313/4') @> ARRAY['number:0645460313','number:0645460314'])
  OR NOT (governance.contact_aliases('phone','Telefono: 06/45460313/4') @> ARRAY['number:0645460313','number:0645460314'])
  OR cardinality(governance.contact_aliases('email','a3/4@example.invalid'))<>1 THEN
  RAISE EXCEPTION 'contact_alias_contract_invalid';
 END IF;
 PERFORM api.linked_service_supplements(NULL,'it');
END $$;
ROLLBACK;
