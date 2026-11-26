-- EGI-84: a moderator's own check is a source. A location and a service created in the
-- workspace cite an observation of "Redazione EGI", publish like imported ones and are
-- credited publicly to that source; without evidence they still cannot be published.
BEGIN;
\ir helpers.sql
CREATE FUNCTION pg_temp.h(token text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT encode(sha256(convert_to(token,'UTF8')),'hex') $$;
CREATE ROLE egi_probe16_desk LOGIN IN ROLE egi_editorial;
CREATE ROLE egi_probe16_reader LOGIN IN ROLE egi_reader;
SELECT access.bootstrap_admin('admin16','Admin Sixteen',pg_temp.h('inv-16')) AS admin_account \gset
SET LOCAL SESSION AUTHORIZATION egi_probe16_desk;
SELECT pg_temp.expect_error($$SELECT editorial.record_observation('service','{"name":"x"}','phone_call',NULL)$$,'42501','session_required');
SELECT access.accept_invitation(pg_temp.h('inv-16'),'password','$argon2id$a',NULL,NULL,'JBSWY3DPEHPK3PXP') IS NOT NULL AS ok;
SELECT access.open_session(:'admin_account',pg_temp.h('s-16'),'password',true) IS NOT NULL AS ok;
SELECT access.verify_session(pg_temp.h('s-16'))->>'actor_id' AS actor \gset
SELECT set_config('egi.test_actor',:'actor',true) IS NOT NULL AS ok;

SELECT pg_temp.expect_error($$SELECT editorial.record_observation('organization','{"name":"x"}','phone_call',NULL)$$,'22023','invalid_subject_kind');
SELECT pg_temp.expect_error($$SELECT editorial.record_observation('service','{"name":"x"}','rumour',NULL)$$,'22023','invalid_method');
SELECT pg_temp.expect_error($$SELECT editorial.record_observation('service','{}','phone_call',NULL)$$,'22023','nothing_observed');
SELECT pg_temp.expect_error(format('SELECT editorial.record_observation(%L,%L,%L,%L)','service','{"name":"x"}','other',repeat('x',1001)),'22001','note_too_long');

DO $$ DECLARE
 seen jsonb; place jsonb; location uuid; lrev uuid; srev uuid; service uuid; cites jsonb; payload jsonb;
BEGIN
 -- Without evidence a created service is a draft that cannot be published.
 srev:=governance.save_revision('service',NULL,NULL,NULL,'{"name":"Unsourced","description":"No check","delivery_mode":"telephone",
  "contacts":[{"channel_type":"phone","value":"06 161616"}],"evidence":{"record":[]}}','Contract 16');
 PERFORM pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',srev,'approved','x'),'23514','publication_incomplete: missing_evidence');

 place:=editorial.record_observation('location','{"name":"Sede vista","address":"Via Verificata 1, Roma"}','site_visit','Visitata il 26/11');
 PERFORM pg_temp.assert_true(place ?& ARRAY['name','address'] AND jsonb_typeof(place->'name')='string','one assertion per observed value');
 cites:=jsonb_build_array(jsonb_build_object('assertion_id',place->>'name','role','supporting'),
  jsonb_build_object('assertion_id',place->>'address','role','supporting'));
 lrev:=governance.save_revision('location',NULL,NULL,NULL,jsonb_build_object('name','Sede vista','location_kind','address',
  'coordinate_state','unknown','addresses',jsonb_build_array(jsonb_build_object('address_kind','physical',
  'formatted','Via Verificata 1, Roma','normalization_state','raw','evidence',jsonb_build_array(cites->1))),
  'evidence',jsonb_build_object('record',cites,'name',jsonb_build_array(cites->0))),'Contract 16');
 PERFORM governance.publish_revision(lrev,governance.review_revision(lrev,NULL,'approved','Luogo verificato'),NULL);
 SELECT entity_id INTO location FROM governance.entity_revisions WHERE revision_id=lrev;

 seen:=editorial.record_observation('service','{"name":"Servizio verificato","delivery_mode":"in_person"}','phone_call',NULL);
 srev:=governance.save_revision('service',NULL,NULL,NULL,jsonb_build_object('name','Servizio verificato','description','Verificato al telefono',
  'delivery_mode','in_person','original_language','it','place',jsonb_build_object('location_id',location),
  'evidence',jsonb_build_object('record',jsonb_build_array(jsonb_build_object('assertion_id',seen->>'name','role','supporting'),
   jsonb_build_object('assertion_id',seen->>'delivery_mode','role','supporting')),'description','[]'::jsonb)),'Contract 16');
 PERFORM governance.publish_revision(srev,governance.review_revision(srev,NULL,'approved','Servizio verificato'),NULL);
 SELECT entity_id INTO service FROM governance.entity_revisions WHERE revision_id=srev;

 PERFORM set_config('egi.test_service',service::text,true);
 SELECT rv.raw_payload INTO payload FROM sources.assertions a JOIN sources.normalized_subjects n USING(subject_id)
  JOIN sources.record_versions rv USING(record_version_id) WHERE a.assertion_id=(seen->>'name')::uuid;
 PERFORM pg_temp.assert_true(payload->>'actor_id'=current_setting('egi.test_actor') AND payload->>'method'='phone_call'
  AND payload#>>'{values,name}'='Servizio verificato','the record says who observed what and how');
 PERFORM pg_temp.assert_true((SELECT method FROM sources.assertions WHERE assertion_id=(place->>'address')::uuid)='editorial_site_visit'
  AND (SELECT raw_payload->>'note' FROM sources.record_versions rv JOIN sources.normalized_subjects n USING(record_version_id)
   JOIN sources.assertions a USING(subject_id) WHERE a.assertion_id=(place->>'name')::uuid)='Visitata il 26/11','method and note are kept');
END $$;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM api.source_attributions WHERE entity_id=current_setting('egi.test_service')::uuid
 AND name='Redazione EGI'),'the public card credits the editorial source');

SET LOCAL SESSION AUTHORIZATION egi_probe16_reader;
SELECT pg_temp.expect_error($$SELECT editorial.record_observation('service','{"name":"x"}','phone_call',NULL)$$,'42501');
RESET SESSION AUTHORIZATION;
ROLLBACK;
