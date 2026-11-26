-- EGI-83: editorial.revision_body reads a revision back as the body save_revision takes.
-- Saving that body unchanged gives the same body again: components, texts, hours,
-- calendar exceptions and evidence survive. Equivalence with sync's reader
-- (egi-importer sync/db.py) was checked once across sync's native tests.
BEGIN;
\ir helpers.sql
\ir fixtures.sql
DO $$ DECLARE
 territory uuid; operator uuid; phone uuid; place uuid; calendar uuid; event uuid; rev uuid; owner uuid; again uuid;
 lrev uuid; location uuid; schedule uuid:='b1500000-0000-0000-0000-000000000001'; days jsonb; first jsonb; second jsonb;
 supporting jsonb:='[{"assertion_id":"57000000-0000-0000-0000-000000000001","role":"supporting"}]';
BEGIN
 territory:=pg_temp.save('territory','{"code":"body-a","name":"Area A","timezone_name":"Europe/Rome"}');PERFORM pg_temp.publish(territory);
 SELECT entity_id INTO territory FROM governance.entity_revisions WHERE revision_id=territory;
 operator:=pg_temp.save('organization','{"name":"Operator","contacts":[{"channel_type":"phone","value":"06 111","purpose_code":"appointment"}]}');
 PERFORM pg_temp.publish(operator);SELECT component_id INTO phone FROM data.contact_entries WHERE revision_id=operator;
 SELECT entity_id INTO operator FROM governance.entity_revisions WHERE revision_id=operator;
 lrev:=pg_temp.save('location',jsonb_build_object('name','Body building','location_kind','building','coordinate_state','known',
  'latitude',41.9,'longitude',12.5,'territories',jsonb_build_array(territory),
  'organizations',jsonb_build_array(jsonb_build_object('organization_id',operator,'role_code','host')),
  'addresses',jsonb_build_array(jsonb_build_object('address_kind','street','formatted','Via Esempio 1, Roma','line1','Via Esempio 1',
   'locality','Roma','postal_code','00100','country_code','IT','normalization_state','normalized'))));
 PERFORM pg_temp.publish(lrev);SELECT entity_id INTO place FROM governance.entity_revisions WHERE revision_id=lrev;
 calendar:=governance.create_calendar('body-shared','Body calendar');
 event:=pg_temp.save('calendar_event',jsonb_build_object('name','Holiday','calendar_id',calendar,'date_from','2026-01-06','date_until','2026-01-06','event_kind','confirmed_change'));
 PERFORM pg_temp.publish(event);
 SELECT jsonb_agg(jsonb_build_object('weekday',n,'state',CASE WHEN n<=2 THEN 'intervals' ELSE 'closed' END,'completeness','complete',
  'intervals',CASE n WHEN 1 THEN '[{"opens":"22:00","closes":"02:00","end_day_offset":1}]'::jsonb
   WHEN 2 THEN '[{"opens":"14:00","closes":"18:00"},{"opens":"09:00:30","closes":"12:00"}]'::jsonb ELSE '[]'::jsonb END)) INTO days
  FROM generate_series(1,7)n;
 rev:=pg_temp.save('service',jsonb_build_object('name','Body offer','description','A service read back','delivery_mode','in_person',
  'cost_state','variable','cost_note','Ask first','place',jsonb_build_object('location_id',place),'territories',jsonb_build_array(territory),
  'coverage',jsonb_build_array(jsonb_build_object('territory_id',territory,'description','Area A only')),
  'organizations',jsonb_build_array(jsonb_build_object('organization_id',operator,'role_code','operator')),
  'contact_links',jsonb_build_array(jsonb_build_object('target_entity_id',operator,'target_contact_component_id',phone,'purpose_code','appointment')),
  'conditions','[{"condition_kind":"appointment","requirement_state":"required","details":"Call first"}]'::jsonb,
  'contacts','[{"channel_type":"email","value":"b@example.invalid","sort_order":2},{"channel_type":"phone","value":"06 222","label":"Desk","sort_order":1}]'::jsonb,
  'schedules',jsonb_build_array(jsonb_build_object('component_id',schedule,'timezone','Europe/Rome','completeness','complete','days',days,
   'evidence','[{"assertion_id":"57000000-0000-0000-0000-000000000002","role":"supporting"},{"assertion_id":"57000000-0000-0000-0000-000000000003","role":"contradicting"}]'::jsonb)),
  'calendar_links',jsonb_build_array(jsonb_build_object('schedule_id',schedule,'calendar_id',calendar,'effects',jsonb_build_array(
   jsonb_build_object('event_version_id',event,'kind','replace','intervals','[{"opens":"10:00","closes":"12:00"}]'::jsonb))))));
 PERFORM pg_temp.publish(rev);SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;

 -- Service: the body has every part, and saving it unchanged gives it back.
 first:=editorial.revision_body(rev);
 PERFORM pg_temp.assert_true(first->>'name'='Body offer' AND first->>'cost_note'='Ask first' AND first->>'original_language' IS NULL
  AND first#>>'{place,location_id}'=place::text AND first->'territories'=jsonb_build_array(territory),'service scalars, place and territories');
 PERFORM pg_temp.assert_true(jsonb_array_length(first->'contacts')=2 AND first#>>'{contacts,0,label}'='Desk' AND first#>>'{contacts,1,value}'='b@example.invalid'
  AND first#>>'{contacts,0,component_id}' IS NOT NULL,'contacts in their order, with labels and components');
 PERFORM pg_temp.assert_true(first#>'{schedules,0,days,0,intervals,0}'@>'{"opens":"22:00","closes":"02:00","end_day_offset":1}'
  AND first#>>'{schedules,0,days,1,intervals,0,opens}'='09:00:30' AND jsonb_array_length(first#>'{schedules,0,days}')=7
  AND jsonb_array_length(first#>'{schedules,0,evidence}')=2,'hours by weekday and time, seconds kept only when stated');
 PERFORM pg_temp.assert_true(first#>>'{calendar_links,0,effects,0,kind}'='replace'
  AND first#>>'{calendar_links,0,effects,0,intervals,0,closes}'='12:00','calendar exceptions');
 PERFORM pg_temp.assert_true(first#>>'{coverage,0,description}'='Area A only' AND first#>>'{conditions,0,details}'='Call first'
  AND first#>>'{contact_links,0,target_contact_component_id}'=phone::text AND first#>>'{organizations,0,role_code}'='operator','components');
 PERFORM pg_temp.assert_true(first#>'{evidence,record}'=supporting AND first#>'{evidence,name}'=supporting
  AND NOT first->'evidence' ? 'contacts','evidence per scalar field');
 again:=governance.save_revision('service',owner,rev,rev,first,'Round trip');
 second:=editorial.revision_body(again);
 PERFORM pg_temp.assert_true(second=first,'a saved body reads back unchanged');

 -- A moderator's value keeps its explicit empty evidence; the rest keeps the source's.
 rev:=governance.save_revision('service',owner,again,(SELECT revision_id FROM governance.published_heads WHERE entity_id=owner),
  jsonb_set(jsonb_set(second,'{name}','"Edited offer"'),'{evidence,name}','[]'),'Moderator edit');
 first:=editorial.revision_body(rev);
 PERFORM pg_temp.assert_true(first->>'name'='Edited offer' AND first#>'{evidence,name}'='[]' AND first#>'{evidence,record}'=supporting
  AND first->'schedules'=second->'schedules','an edit changes only what it names');

 -- Location: addresses, coordinates, organizations and territories.
 first:=editorial.revision_body(lrev);
 PERFORM pg_temp.assert_true(first->>'location_kind'='building' AND (first->>'latitude')::numeric=41.9
  AND first#>>'{addresses,0,locality}'='Roma' AND first#>>'{organizations,0,role_code}'='host'
  AND first->'territories'=jsonb_build_array(territory),'location body');
 again:=governance.save_revision('location',place,lrev,lrev,first,'Round trip');
 PERFORM pg_temp.assert_true(editorial.revision_body(again)=first,'a saved location body reads back unchanged');

 PERFORM pg_temp.expect_error(format('SELECT editorial.revision_body(%L)',territory),'P0002','revision_not_found');
END $$;

-- Only the editorial login reads drafts this way, and only within a verified session.
CREATE ROLE egi_probe15_desk LOGIN IN ROLE egi_editorial;
CREATE ROLE egi_probe15_reader LOGIN IN ROLE egi_reader;
SELECT revision_id AS any_revision FROM governance.entity_revisions WHERE entity_kind='service' LIMIT 1 \gset
SET LOCAL SESSION AUTHORIZATION egi_probe15_desk;
SELECT pg_temp.expect_error(format('SELECT editorial.revision_body(%L)',:'any_revision'),'42501','session_required');
RESET SESSION AUTHORIZATION;
SET LOCAL SESSION AUTHORIZATION egi_probe15_reader;
SELECT pg_temp.expect_error(format('SELECT editorial.revision_body(%L)',:'any_revision'),'42501');
RESET SESSION AUTHORIZATION;
ROLLBACK;
