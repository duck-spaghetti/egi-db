BEGIN;
\ir helpers.sql
\ir fixtures.sql
CREATE TEMP TABLE directory_case(service uuid,territory uuid,private_content uuid,old_sequence bigint);
DO $$ DECLARE territory uuid; org uuid; orgrev uuid; orgphone uuid; loc uuid; locrev uuid; rev uuid; service uuid; changed uuid; detail jsonb; private_content uuid; sequence bigint; BEGIN
 territory:=pg_temp.save('territory','{"code":"directory-area","name":"Directory area","timezone_name":"Europe/Rome"}');PERFORM pg_temp.publish(territory);SELECT entity_id INTO territory FROM governance.entity_revisions WHERE revision_id=territory;
 orgrev:=pg_temp.save('organization','{"name":"Public provider","description":"Provider description","contacts":[{"channel_type":"phone","value":"provider appointment","label":"Appointments"},{"channel_type":"email","value":"PRIVATE-SECRET","label":"PRIVATE-LABEL","is_public":false}]}');PERFORM pg_temp.publish(orgrev);SELECT entity_id INTO org FROM governance.entity_revisions WHERE revision_id=orgrev;
 SELECT component_id INTO orgphone FROM data.contact_entries WHERE revision_id=orgrev AND value='provider appointment';SELECT label_content_id INTO private_content FROM data.contact_entries WHERE revision_id=orgrev AND NOT is_public;
 locrev:=pg_temp.save('location','{"name":"Approved place","location_kind":"building","latitude":41.9,"longitude":12.5,"coordinate_state":"known","addresses":[{"formatted":"Approved address"}]}');PERFORM pg_temp.publish(locrev);SELECT entity_id INTO loc FROM governance.entity_revisions WHERE revision_id=locrev;
 rev:=pg_temp.save('service',jsonb_build_object('name','Public directory offer','description','A valid offer','delivery_mode','in_person','territories',jsonb_build_array(territory),'place',jsonb_build_object('location_id',loc),'organizations',jsonb_build_array(jsonb_build_object('organization_id',org,'role_code','operator')),'contact_links',jsonb_build_array(jsonb_build_object('target_entity_id',org,'target_contact_component_id',orgphone,'purpose_code','appointment')),'conditions','[{"condition_kind":"appointment","requirement_state":"required","details":"Call first"}]'::jsonb));PERFORM pg_temp.publish(rev);SELECT entity_id INTO service FROM governance.entity_revisions WHERE revision_id=rev;
 detail:=api.service_detail(service,'ar','2026-01-06 10:00Z');
 PERFORM pg_temp.assert_true(detail#>>'{place,name,text}'='Approved place' AND detail#>>'{contacts,0,value}'='provider appointment','approved shared place and explicit endpoint');
 PERFORM pg_temp.assert_true(detail#>>'{conditions,0,details,text}'='Call first','access details distinct');
 PERFORM pg_temp.assert_true(detail#>>'{verification,warning}'='no_verification','missing verification warns');
 PERFORM pg_temp.assert_true(jsonb_array_length(detail->'sources')=1 AND NOT detail::text LIKE '%PRIVATE%' AND NOT detail::text LIKE '%raw_payload%' AND NOT detail::text LIKE '%actor_id%' AND NOT detail::text LIKE '%fixture:a%','whitelisted attribution and private data hidden');
 PERFORM pg_temp.assert_true(api.resolve_text(private_content,'ar') IS NULL,'private contact original cannot be requested directly');
 detail:=api.directory_snapshot(territory,'ar','{}','2026-01-06 10:00Z');PERFORM pg_temp.assert_true(jsonb_array_length(detail->'services')=1 AND jsonb_array_length(detail#>'{references,locations}')=1 AND jsonb_array_length(detail#>'{references,organizations}')=1 AND detail->>'snapshot_sequence' IS NOT NULL,'coherent territorial snapshot');
 PERFORM pg_temp.assert_true(jsonb_array_length(api.directory_snapshot(territory,'ar','{}','2026-01-06 10:00Z',true)->'services')=0,'unknown opening excluded by explicit open filter');
 changed:=pg_temp.save('location','{"name":"DRAFT-SECRET","location_kind":"building","coordinate_state":"unknown"}',loc,locrev,locrev);
 PERFORM pg_temp.assert_true(api.service_detail(service)#>>'{place,name,text}'='Approved place','shared draft hidden');
 SELECT snapshot_sequence INTO sequence FROM api.public_sequence;PERFORM pg_temp.publish(changed,locrev);
 PERFORM pg_temp.assert_true(api.service_detail(service)#>>'{place,name,text}'='DRAFT-SECRET' AND (SELECT snapshot_sequence>sequence FROM api.public_sequence),'approved location changes invalidate service');
 SELECT snapshot_sequence INTO sequence FROM api.public_sequence;PERFORM governance.verify_revision(rev,'page',NULL,NULL,'2025-01-01Z','phone','fixture:verification','confirmed');
 detail:=api.service_detail(service,NULL,'2026-01-06Z',interval '90 days');PERFORM pg_temp.assert_true(detail#>>'{verification,checks,0,warning}'='review_due' AND (SELECT snapshot_sequence>sequence FROM api.public_sequence),'retained old check with explicit caller policy');
 changed:=pg_temp.save('service',jsonb_build_object('name','Closed history','description','A valid closed record','delivery_mode','telephone','contacts','[{"channel_type":"phone","value":"closed contact"}]'::jsonb,'operational_status','defunct','territories',jsonb_build_array(territory)),service,rev,rev);PERFORM pg_temp.publish(changed,rev);
 PERFORM pg_temp.assert_true(api.service_detail(service)->>'operational_status'='defunct' AND api.opening(service,'2026-01-06Z')->>'status'='closed','closed direct detail and opening');
 PERFORM pg_temp.assert_true(jsonb_array_length(api.directory_snapshot(territory)->'services')=0,'defunct excluded from ordinary directory');
 INSERT INTO directory_case VALUES(service,territory,private_content,sequence);
END $$;
CREATE ROLE egi_directory_reader LOGIN;
GRANT egi_reader TO egi_directory_reader;
GRANT SELECT ON directory_case TO egi_directory_reader;
SELECT format('GRANT USAGE ON SCHEMA %I TO egi_directory_reader',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO egi_directory_reader',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SET SESSION AUTHORIZATION egi_directory_reader;
SELECT pg_temp.assert_true(api.service_detail(service) IS NOT NULL,'reader detail access') FROM directory_case;
SELECT pg_temp.assert_true(api.directory_snapshot(territory) IS NOT NULL,'reader snapshot access') FROM directory_case;
SELECT pg_temp.assert_true(api.resolve_text(private_content) IS NULL,'reader private label denied') FROM directory_case;
SELECT pg_temp.expect_error('SELECT * FROM i18n.translations','42501');
SELECT pg_temp.expect_error('SELECT * FROM governance.translation_work','42501');
SELECT pg_temp.expect_error('SELECT * FROM taxonomy.assignments','42501');
SELECT pg_temp.expect_error('SELECT * FROM api.export_manifests','42501');
RESET SESSION AUTHORIZATION;
ROLLBACK;
