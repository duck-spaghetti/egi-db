BEGIN;
\ir helpers.sql
\ir fixtures.sql
-- Session roles exist only inside this rolled-back transaction.
CREATE ROLE egi_contract_sync LOGIN IN ROLE egi_sync;
CREATE ROLE egi_contract_writer LOGIN IN ROLE egi_writer;
INSERT INTO governance.actors(actor_id,database_role,display_name) VALUES
('10000000-0000-0000-0000-000000000011','egi_contract_sync','Synthetic sync'),
('10000000-0000-0000-0000-000000000012','egi_contract_writer','Synthetic moderator');
INSERT INTO governance.actor_grants(actor_id,capability)
 SELECT a,c FROM unnest(ARRAY['10000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000012']::uuid[]) a CROSS JOIN unnest(ARRAY['propose','approve','publish']) c;
CREATE TEMP TABLE sync_scenario(service uuid,location uuid,rev uuid,other uuid,other_rev uuid,shared uuid,shared_a uuid,shared_a_rev uuid,shared_b uuid,shared_b_rev uuid);
DO $$ DECLARE loc uuid; locrev uuid; rev uuid; svc uuid; other uuid; otherrev uuid; shared uuid; sharedrev uuid; a uuid; arev uuid; b uuid; brev uuid; BEGIN
 locrev:=pg_temp.save('location','{"location_kind":"address","addresses":[{"formatted":"Synthetic street 1"}]}');
 SELECT entity_id INTO loc FROM governance.entity_revisions WHERE revision_id=locrev;PERFORM pg_temp.publish(locrev);
 rev:=pg_temp.save('service',jsonb_build_object('name','Withdrawable','description','Synthetic','delivery_mode','in_person','place',jsonb_build_object('location_id',loc)));
 SELECT entity_id INTO svc FROM governance.entity_revisions WHERE revision_id=rev;PERFORM pg_temp.publish(rev);
 otherrev:=pg_temp.save('service','{"name":"Moderated","description":"Synthetic","delivery_mode":"telephone","contacts":[{"channel_type":"phone","value":"fixture phone"}]}');
 SELECT entity_id INTO other FROM governance.entity_revisions WHERE revision_id=otherrev;PERFORM pg_temp.publish(otherrev);
 sharedrev:=pg_temp.save('location','{"location_kind":"address","addresses":[{"formatted":"Synthetic street 2"}]}');
 SELECT entity_id INTO shared FROM governance.entity_revisions WHERE revision_id=sharedrev;PERFORM pg_temp.publish(sharedrev);
 arev:=pg_temp.save('service',jsonb_build_object('name','Shared A','description','Synthetic','delivery_mode','in_person','place',jsonb_build_object('location_id',shared)));
 SELECT entity_id INTO a FROM governance.entity_revisions WHERE revision_id=arev;PERFORM pg_temp.publish(arev);
 brev:=pg_temp.save('service',jsonb_build_object('name','Shared B','description','Synthetic','delivery_mode','in_person','place',jsonb_build_object('location_id',shared)));
 SELECT entity_id INTO b FROM governance.entity_revisions WHERE revision_id=brev;PERFORM pg_temp.publish(brev);
 INSERT INTO sync_scenario VALUES(svc,loc,rev,other,otherrev,shared,a,arev,b,brev);
END $$;
GRANT SELECT ON sync_scenario TO egi_contract_sync,egi_contract_writer;
GRANT EXECUTE ON FUNCTION pg_temp.assert_true(boolean,text),pg_temp.expect_error(text,text,text) TO egi_contract_sync,egi_contract_writer;

SET SESSION AUTHORIZATION egi_contract_writer;
DO $$ DECLARE s sync_scenario; BEGIN
 SELECT * INTO s FROM sync_scenario;
 PERFORM pg_temp.expect_error(format('SELECT governance.withdraw_service(%L,%L,%L,%L)',s.service,s.rev,'not_observed','writer cannot claim an absence'),'42501','sync_cause_denied');
 PERFORM pg_temp.expect_error(format('SELECT governance.record_sync_version(%L,%L,false,NULL,NULL,%L)','51000000-0000-0000-0000-000000000001',repeat('a',64),'[]'),'42501');
 PERFORM pg_temp.expect_error('INSERT INTO sources.assertions DEFAULT VALUES','42501');
 PERFORM governance.withdraw_service(s.other,s.other_rev,'moderation','Hidden by a moderator');
END $$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION egi_contract_sync;
DO $$ DECLARE s sync_scenario; v1 uuid; v2 uuid; BEGIN
 SELECT * INTO s FROM sync_scenario;
 PERFORM pg_temp.expect_error(format('SELECT governance.withdraw_service(%L,%L,%L,%L)',s.service,gen_random_uuid(),'not_observed','stale'),'40001','stale_base');
 PERFORM pg_temp.expect_error(format('SELECT governance.withdraw_service(%L,%L,%L,%L)',s.service,s.rev,'closed','unknown cause'),'22023','unknown_withdrawal_cause');
 PERFORM pg_temp.expect_error(format('SELECT governance.withdraw_service(%L,%L,%L,%L)',s.service,s.rev,'not_observed',' '),'22023','reason_required');
 PERFORM pg_temp.expect_error('DELETE FROM governance.published_heads','42501');
 PERFORM pg_temp.expect_error('INSERT INTO sources.registry(code,name,source_kind) VALUES(''x'',''x'',''manual'')','42501');
 v1:=governance.record_sync_version('51000000-0000-0000-0000-000000000001',repeat('a',64),false,NULL,NULL,
  jsonb_build_array(jsonb_build_object('service_id',s.service,'state','loaded','identity','{}'::jsonb,'comparable','{}'::jsonb,'source_body','{}'::jsonb)));
 PERFORM pg_temp.expect_error(format('SELECT governance.record_sync_version(%L,%L,true,NULL,NULL,%L)','51000000-0000-0000-0000-000000000001',repeat('b',64),'[]'),'40001','stale_version');
 v2:=governance.record_sync_version('51000000-0000-0000-0000-000000000001',repeat('b',64),true,v1,NULL,
  jsonb_build_array(jsonb_build_object('service_id',NULL,'state','waiting','identity','{}'::jsonb,'comparable','{}'::jsonb)));
 PERFORM pg_temp.assert_true((SELECT previous_version_id=v1 FROM governance.sync_versions WHERE version_id=v2),'versions form one chain');
 PERFORM pg_temp.assert_true((SELECT source_body IS NULL FROM governance.sync_entries WHERE version_id=v2),'absent body is SQL NULL');
 PERFORM governance.record_sync_version('51000000-0000-0000-0000-000000000002',repeat('c',64),true,NULL,NULL,'[]');
 PERFORM governance.link_source_services('51000000-0000-0000-0000-000000000001','k1','51000000-0000-0000-0000-000000000002','k2','same','a','One service in two sources');
 PERFORM pg_temp.expect_error(format('SELECT governance.link_source_services(%L,%L,%L,%L,%L,NULL,%L)','51000000-0000-0000-0000-000000000001','k1','51000000-0000-0000-0000-000000000002','k2','same','no principal'),'23514');
 PERFORM governance.withdraw_service(s.service,s.rev,'not_observed','Absent from a complete capture');
 PERFORM governance.withdraw_service(s.shared_a,s.shared_a_rev,'duplicate','Linked to another service');
END $$;
RESET SESSION AUTHORIZATION;

DO $$ DECLARE s sync_scenario; again uuid; BEGIN
 SELECT * INTO s FROM sync_scenario;
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM api.published_services WHERE service_id IN(s.service,s.other,s.shared_a)),'withdrawn services are not public');
 PERFORM pg_temp.assert_true(api.service_detail(s.service) IS NULL AND api.opening(s.service,clock_timestamp()) IS NULL,'withdrawn detail is not public');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM api.public_locations WHERE location_id=s.location),'orphan address is not public');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.public_locations WHERE location_id=s.shared) AND EXISTS(SELECT FROM api.published_services WHERE service_id=s.shared_b),'shared location stays');
 PERFORM pg_temp.assert_true((SELECT operational_status='unknown' FROM data.service_revisions WHERE revision_id=s.rev),'withdrawal states no closure');
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM audit.public_changes WHERE entity_id IN(s.service,s.location) AND reason='withdrawal:not_observed'),'both removals advance the public sequence');
 PERFORM pg_temp.assert_true((SELECT details->>'cause'='moderation' FROM audit.events WHERE entity_id=s.other AND action='withdraw'),'moderation cause is audited');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM governance.publications WHERE entity_id=s.service),'publication history stays');
 again:=pg_temp.save('service','{"name":"Moderated","description":"Synthetic again","delivery_mode":"telephone","contacts":[{"channel_type":"phone","value":"fixture phone"}]}',s.other,s.other_rev,NULL);
 PERFORM pg_temp.publish(again);
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM api.published_services WHERE service_id=s.other),'an explicit publication can return');
 PERFORM pg_temp.expect_error('DELETE FROM governance.sync_versions','55000','immutable_record');
 PERFORM pg_temp.expect_error('UPDATE governance.source_service_links SET reason=''x''','55000','immutable_record');
END $$;
ROLLBACK;
