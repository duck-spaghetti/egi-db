BEGIN;
\ir helpers.sql
\ir fixtures.sql
CREATE TEMP TABLE scenario(key text PRIMARY KEY,rev uuid,entity uuid);
DO $$ DECLARE org uuid; orgrev uuid; orgedit uuid; orgphone uuid; rev uuid; owner uuid; changed uuid; restored uuid; d uuid; contact uuid; before_sequence bigint; incomplete uuid; closed uuid; closed_again uuid; temporary uuid; t1 uuid; t2 uuid; BEGIN
 orgrev:=pg_temp.save('organization','{"name":"Provider","contacts":[{"channel_type":"phone","value":"original provider phone","purpose_code":"organization"},{"channel_type":"email","value":"unrelated@example.invalid"},{"channel_type":"phone","value":"private phone","is_public":false}]}');
 SELECT entity_id INTO org FROM governance.entity_revisions WHERE revision_id=orgrev;
 SELECT component_id INTO orgphone FROM data.contact_entries WHERE revision_id=orgrev AND value='original provider phone';
 PERFORM pg_temp.publish(orgrev);
 rev:=pg_temp.save('service',jsonb_build_object('name','Telephone advice','description','A usable telephone service','delivery_mode','telephone','contacts',jsonb_build_array(jsonb_build_object('channel_type','phone','value','original service phone','purpose_code','appointment')),'contact_links',jsonb_build_array(jsonb_build_object('target_entity_id',org,'target_contact_component_id',orgphone,'purpose_code','organization')),'organizations',jsonb_build_array(jsonb_build_object('organization_id',org,'role_code','manager')),'conditions',jsonb_build_array(jsonb_build_object('condition_kind','appointment','requirement_state','required','details','Call before attending'))));
 SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;
 PERFORM pg_temp.publish(rev);
 SELECT component_id INTO contact FROM data.contact_entries WHERE revision_id=rev;
 PERFORM governance.verify_revision(rev,'component',NULL,contact,'2025-01-01Z','phone','fixture:call','confirmed');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM api.service_verification WHERE service_id=owner AND component_id=contact),'scoped old phone verification retained');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM api.service_verification WHERE service_id=owner AND field_code='hours'),'phone check does not verify hours');
 SELECT max(change_sequence) INTO before_sequence FROM audit.public_changes;
 orgedit:=pg_temp.save('organization',jsonb_build_object('name','Updated provider','contacts',jsonb_build_array(jsonb_build_object('component_id',orgphone,'channel_type','phone','value','new provider phone'))),org,orgrev,orgrev);
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.service_contacts WHERE service_id=owner AND value='original provider phone'),'pending provider edits hidden');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM api.service_contacts WHERE service_id=owner AND value IN ('private phone','unrelated@example.invalid','new provider phone')),'only explicitly linked approved public contacts');
 changed:=pg_temp.save('service','{"name":"Pending service title","description":"Pending description","delivery_mode":"telephone","contacts":[{"channel_type":"phone","value":"pending service phone"}]}',owner,rev,rev);
 PERFORM pg_temp.assert_true((SELECT name='Telephone advice' FROM api.published_services WHERE service_id=owner),'pending service title hidden');
 PERFORM pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',changed,'approved','stale approval'),'40001','stale_base');
 PERFORM pg_temp.assert_true((SELECT max(change_sequence)=before_sequence FROM audit.public_changes),'failed and pending operations do not advance public sequence');
 PERFORM pg_temp.expect_error(format('SELECT governance.publish_revision(%L,%L,%L)',changed,gen_random_uuid(),rev),'23514','exact_approval_required');
 PERFORM pg_temp.publish(changed,rev);
 PERFORM pg_temp.publish(orgedit,orgrev);
 restored:=governance.restore_revision(rev,changed,changed,'Restore source-backed original service');
 PERFORM pg_temp.assert_true((SELECT restored_from_revision_id=rev AND parent_revision_id=changed FROM governance.entity_revisions WHERE revision_id=restored),'restore is a new revision with explicit origin');
 PERFORM pg_temp.assert_true((SELECT revision_id=orgedit FROM governance.published_heads WHERE entity_id=org),'shared provider head untouched by restore');
 PERFORM pg_temp.assert_true((SELECT name='Pending service title' FROM api.published_services WHERE service_id=owner),'unapproved restore not public');
 PERFORM pg_temp.publish(restored,changed);
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.service_contacts WHERE service_id=owner AND value='original service phone'),'own contact restored');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.service_contacts WHERE service_id=owner AND value='new provider phone'),'shared contact uses independently approved current provider');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM data.access_conditions WHERE revision_id=restored),'access aggregate restored');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM governance.verifications WHERE revision_id=restored),'restore does not fabricate new verification');
 incomplete:=pg_temp.save('service','{"delivery_mode":"telephone"}');
 PERFORM pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',incomplete,'approved','invalid'),'23514','publication_incomplete');
 PERFORM pg_temp.expect_error(format('SELECT governance.publish_revision(%L,%L,%L)',restored,gen_random_uuid(),restored),'40001','stale_submission');
 closed:=pg_temp.save('service','{"name":"Closed offer","description":"Closed history","delivery_mode":"telephone","operational_status":"defunct","contacts":[{"channel_type":"phone","value":"archived phone"}]}');
 PERFORM pg_temp.publish(closed); SELECT entity_id INTO closed_again FROM governance.entity_revisions WHERE revision_id=closed;
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.published_services WHERE service_id=closed_again AND operational_status='defunct'),'closed direct access');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM api.discoverable_services WHERE service_id=closed_again),'closed not discoverable');
 temporary:=pg_temp.save('service','{"name":"Temporary closure","description":"Temporary status","delivery_mode":"telephone","operational_status":"temporarily_closed","contacts":[{"channel_type":"phone","value":"contact"}]}');PERFORM pg_temp.publish(temporary);
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.discoverable_services WHERE revision_id=temporary AND operational_status='temporarily_closed'),'temporary closure remains discoverable');
 -- An approved shared update may not invalidate already approved consumers.
 d:=pg_temp.save('organization','{"name":"Provider without referenced contact"}',org,orgedit,orgedit);
 PERFORM pg_temp.expect_error(format('SELECT pg_temp.publish(%L,%L)',d,orgedit),'23514','invalid_shared_contact');
 PERFORM pg_temp.assert_true((SELECT revision_id=orgedit FROM governance.published_heads WHERE entity_id=org),'invalid shared publication rolled back');
 -- Shared endpoint alone can be the usable remote access channel.
 d:=pg_temp.save('service',jsonb_build_object('name','Shared telephone access','description','Call provider for service','delivery_mode','telephone','contact_links',jsonb_build_array(jsonb_build_object('target_entity_id',org,'target_contact_component_id',orgphone))));PERFORM pg_temp.publish(d);
 INSERT INTO scenario VALUES('published',restored,owner),('provider',orgedit,org);
 t1:=pg_temp.save('territory','{"code":"scope-a","name":"Area A","timezone_name":"Europe/Rome"}');SELECT entity_id INTO t1 FROM governance.entity_revisions WHERE revision_id=t1;
 t2:=pg_temp.save('territory','{"code":"scope-b","name":"Area B","timezone_name":"Europe/Rome"}');SELECT entity_id INTO t2 FROM governance.entity_revisions WHERE revision_id=t2;
 d:=pg_temp.save('service',jsonb_build_object('name','Two territories','description','Both territories','delivery_mode','telephone','contacts',jsonb_build_array(jsonb_build_object('channel_type','phone','value','two-territory phone')),'territories',jsonb_build_array(t1,t2)));SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=d;
 INSERT INTO scenario VALUES('restricted',d,owner),('scope-a',NULL,t1),('scope-b',NULL,t2);
END $$;
CREATE ROLE egi_contract_reader LOGIN;
GRANT egi_reader TO egi_contract_reader;
SELECT format('GRANT USAGE ON SCHEMA %I TO egi_contract_reader',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO egi_contract_reader',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SET SESSION AUTHORIZATION egi_contract_reader;
SELECT pg_temp.assert_true((SELECT count(*)>=1 FROM api.published_services),'reader approved view');
SELECT pg_temp.expect_error('SELECT * FROM governance.working_heads','42501');
SELECT pg_temp.expect_error('SELECT * FROM sources.assertions','42501');
SELECT pg_temp.expect_error('UPDATE data.service_revisions SET cost_state=''free''','42501');
SELECT pg_temp.expect_error('SELECT governance.save_revision(''service'',NULL,NULL,NULL,''{}'',''spoof'')','42501');
RESET SESSION AUTHORIZATION;
CREATE ROLE egi_contract_writer LOGIN;
GRANT egi_writer TO egi_contract_writer;
INSERT INTO governance.actors(actor_id,database_role,display_name) VALUES('10000000-0000-0000-0000-000000000002','egi_contract_writer','Limited scope editor');
INSERT INTO governance.actor_grants(actor_id,capability,territory_id) SELECT '10000000-0000-0000-0000-000000000002',cap,entity FROM scenario CROSS JOIN unnest(ARRAY['propose','approve','publish','verify']) cap WHERE key='scope-a';
GRANT SELECT ON scenario TO egi_contract_writer;
SELECT format('GRANT USAGE ON SCHEMA %I TO egi_contract_writer',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO egi_contract_writer',nspname) FROM pg_namespace WHERE oid=pg_my_temp_schema()
\gexec
SET SESSION AUTHORIZATION egi_contract_writer;
SELECT pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',rev,'approved','out of scope'),'42501','territory_permission_denied') FROM scenario WHERE key='restricted';
SELECT pg_temp.expect_error(format('SELECT governance.save_revision(%L,%L,%L,NULL,%L,%L)','service',entity,rev,'{"name":"remove scope","delivery_mode":"telephone","territories":[]}','scope removal'),'42501','territory_permission_denied') FROM scenario WHERE key='restricted';
SELECT pg_temp.expect_error('SELECT * FROM governance.actor_grants','42501');
DO $$ DECLARE rev uuid; decision uuid; scope uuid; BEGIN
 SELECT entity INTO scope FROM pg_temp.scenario WHERE key='scope-a';
 rev:=pg_temp.save('service',jsonb_build_object('name','Authorized territorial offer','description','A fully authorized local offer','delivery_mode','telephone','territories',jsonb_build_array(scope),'contacts',jsonb_build_array(jsonb_build_object('channel_type','phone','value','authorized contact'))));
 decision:=governance.review_revision(rev,NULL,'approved','Authorized self-approval with propose and approve');
 PERFORM governance.publish_revision(rev,decision,NULL);
END $$;

RESET SESSION AUTHORIZATION;
ROLLBACK;
