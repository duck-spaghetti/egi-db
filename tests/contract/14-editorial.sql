-- EGI-82: private visitor contributions, moderation steps and retention.
-- Autocommit like 13-access: each person's session binds one transaction. The
-- canonical service fixture stays (canonical rows are immutable); everything in
-- `access` and `editorial` is removed at the end so their reverts stay possible.
\ir helpers.sql
CREATE FUNCTION pg_temp.h(token text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT encode(sha256(convert_to(token,'UTF8')),'hex') $$;
CREATE ROLE egi_probe_intake LOGIN IN ROLE egi_intake;
CREATE ROLE egi_probe_desk LOGIN IN ROLE egi_editorial;
CREATE ROLE egi_probe_retention LOGIN IN ROLE egi_retention;

-- A public service and its publication, with random ids: shared fixtures use fixed ids
-- and 05-concurrency.sh loads them again after this file.
INSERT INTO governance.actors(database_role,display_name) VALUES(session_user,'Contract 14 editor') RETURNING actor_id AS editor \gset
INSERT INTO governance.actor_grants(actor_id,capability) SELECT :'editor',unnest(ARRAY['propose','approve','publish']);
INSERT INTO sources.registry(code,name,source_kind,homepage) VALUES('contract-14','Contract 14','manual','https://example.invalid/14') RETURNING source_id \gset
INSERT INTO sources.datasets(source_id,name) VALUES(:'source_id','Contract 14') RETURNING dataset_id \gset
INSERT INTO sources.captures(dataset_id,retrieved_at,artifact_uri,content_hash,media_type,retrieval_status,source_metadata_snapshot)
 VALUES(:'dataset_id','2026-01-01Z','fixture:14','bytes-14','application/json','succeeded','{}') RETURNING capture_id \gset
INSERT INTO sources.records(dataset_id,external_key,identity_method) VALUES(:'dataset_id','key-14','upstream') RETURNING record_id \gset
INSERT INTO sources.record_versions(record_id,dataset_id,content_hash,raw_payload) VALUES(:'record_id',:'dataset_id','bytes-14','{}') RETURNING record_version_id \gset
INSERT INTO sources.capture_records VALUES(:'capture_id',:'record_version_id',:'dataset_id','row:1');
INSERT INTO sources.processing_runs(run_kind,capture_id,processor_version,config_hash,status)
 VALUES('normalize',:'capture_id','v1','c1','succeeded') RETURNING run_id \gset
INSERT INTO sources.normalized_subjects(record_version_id,run_id,subject_kind,subject_locator,normalized_payload)
 VALUES(:'record_version_id',:'run_id','service','row:1','{}') RETURNING subject_id \gset
INSERT INTO sources.assertions(subject_id,attribute_code,normalized_value,certainty,method)
 VALUES(:'subject_id','record','"record"','stated','synthetic') RETURNING assertion_id \gset
SELECT governance.save_revision('service',NULL,NULL,NULL,jsonb_build_object('name','Editorial service',
 'description','A telephone service','delivery_mode','telephone','contacts',jsonb_build_array(jsonb_build_object(
 'channel_type','phone','value','06 000000')),'evidence',jsonb_build_object('record',jsonb_build_array(
 jsonb_build_object('assertion_id',:'assertion_id','role','supporting')))),'Contract 14 fixture') AS service_revision \gset
SELECT governance.publish_revision(:'service_revision',governance.review_revision(:'service_revision',NULL,'approved','Contract 14 review'),NULL) AS publication \gset
SELECT entity_id AS service FROM governance.entity_revisions WHERE revision_id=:'service_revision' \gset

-- People: an admin by password with TOTP, a moderator by OIDC.
SELECT access.bootstrap_admin('admin1','Admin One',pg_temp.h('inv-admin')) AS admin_account \gset
SET SESSION AUTHORIZATION egi_probe_desk;
SELECT access.accept_invitation(pg_temp.h('inv-admin'),'password','$argon2id$a',NULL,NULL,'JBSWY3DPEHPK3PXP') IS NOT NULL AS ok;
SELECT access.open_session(:'admin_account',pg_temp.h('s-admin'),'password',true) IS NOT NULL AS ok;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin'))->>'actor_id' AS admin_actor \gset
SELECT access.create_account('mod1','Mod One','moderator',pg_temp.h('inv-mod')) AS mod_account \gset
COMMIT;
SELECT access.accept_invitation(pg_temp.h('inv-mod'),'oidc',NULL,'https://accounts.google.com','sub-1',NULL) IS NOT NULL AS ok;
SELECT access.open_session(:'mod_account',pg_temp.h('s-mod'),'oidc',false) IS NOT NULL AS ok;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-mod'))->>'actor_id' AS mod_actor \gset
COMMIT;
-- The editorial login never passes through intake.
SELECT pg_temp.expect_error(format('SELECT editorial.submit_contribution(%L,%L,%L,NULL,NULL,NULL,NULL,NULL)','report',:'service','hours'),'42501');
RESET SESSION AUTHORIZATION;

-- ============================================================================
-- Intake: insert only, validated, limited, switchable
-- ============================================================================
SET SESSION AUTHORIZATION egi_probe_intake;
SELECT pg_temp.expect_error('SELECT * FROM editorial.contributions','42501');
SELECT pg_temp.expect_error('SELECT editorial.list_contributions()','42501');
SELECT pg_temp.expect_error(format('SELECT editorial.submit_contribution(%L,%L,%L,%L,%L,false,NULL,NULL)',
 'report',:'service','hours','Orari cambiati','reporter@example.invalid'),'22023','contact_requires_consent');
SELECT pg_temp.expect_error(format('SELECT editorial.submit_contribution(%L,%L,%L,NULL,NULL,NULL,NULL,NULL)',
 'report',gen_random_uuid(),'hours'),'22023','service_not_public');
SELECT pg_temp.expect_error(format('SELECT editorial.submit_contribution(%L,%L,NULL,%L,NULL,NULL,NULL,NULL)',
 'still_valid',:'service','Ancora aperto'),'22023','still_valid_carries_nothing');
SELECT pg_temp.expect_error($$SELECT editorial.submit_contribution('new_service',NULL,NULL,'Nuovo',NULL,NULL,'[{"field":"offer","value":"Pasti"}]',NULL)$$,
 '22023','new_service_requires_name');
SELECT pg_temp.assert_true(editorial.submit_contribution('report',:'service','hours','Orari cambiati','reporter@example.invalid',true,
 '[{"field":"hours","value":"Lun 9-13 secret-value"}]'::jsonb,NULL)='stored','a report is stored');
SELECT pg_temp.assert_true(editorial.submit_contribution('still_valid',:'service',NULL,NULL,NULL,NULL,NULL,NULL)='stored','a still-valid signal is stored');
SELECT pg_temp.assert_true(editorial.submit_contribution('new_service',NULL,NULL,'Mensa nuova',NULL,NULL,
 '[{"field":"name","value":"Mensa San Paolo"},{"field":"offer","value":"Pasti caldi"}]'::jsonb,'')='stored','a new-service proposal is stored');
SELECT pg_temp.assert_true(editorial.submit_contribution('report',:'service','other','Bot',NULL,NULL,NULL,'filled')='trapped','the honeypot keeps nothing');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.contributions)=3,'three contributions stored');
UPDATE editorial.intake_settings SET window_limit=3;
SET SESSION AUTHORIZATION egi_probe_intake;
SELECT pg_temp.assert_true(editorial.submit_contribution('still_valid',:'service',NULL,NULL,NULL,NULL,NULL,NULL)='limited','the window limit refuses');
RESET SESSION AUTHORIZATION;
UPDATE editorial.intake_settings SET window_limit=30,daily_limit=3;
SET SESSION AUTHORIZATION egi_probe_intake;
SELECT pg_temp.assert_true(editorial.submit_contribution('still_valid',:'service',NULL,NULL,NULL,NULL,NULL,NULL)='limited','the daily limit refuses');
RESET SESSION AUTHORIZATION;
UPDATE editorial.intake_settings SET daily_limit=300,open=false;
SET SESSION AUTHORIZATION egi_probe_intake;
SELECT pg_temp.assert_true(editorial.submit_contribution('still_valid',:'service',NULL,NULL,NULL,NULL,NULL,NULL)='closed','the switch closes intake');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.contributions)=3,'refusals store nothing');
SELECT contribution_id AS report FROM editorial.contributions WHERE kind='report' \gset
SELECT contribution_id AS signal FROM editorial.contributions WHERE kind='still_valid' \gset
SELECT contribution_id AS proposal_case FROM editorial.contributions WHERE kind='new_service' \gset
SELECT proposal_id AS hours_proposal FROM editorial.proposals WHERE contribution_id=:'report' \gset

-- ============================================================================
-- Moderation as the person of the verified session
-- ============================================================================
SET SESSION AUTHORIZATION egi_probe_desk;
SELECT pg_temp.expect_error('SELECT editorial.list_contributions()','42501','session_required');
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS ok;
SELECT editorial.set_intake(true,30,300);
COMMIT;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-mod')) IS NOT NULL AS ok;
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.list_contributions())=3,'the queue lists the open contributions');
SELECT pg_temp.expect_error('SELECT editorial.set_intake(false,30,300)','42501','admin_required');
SELECT editorial.claim(:'report');
SELECT pg_temp.assert_true((SELECT r->>'contact'='reporter@example.invalid' AND r->>'state'='claimed'
 AND jsonb_array_length(r->'proposals')=1 AND r->>'claimed_by_name'='Mod One' FROM editorial.read_contribution(:'report') r),
 'a moderator reads text, contact, proposals and claim');
SELECT pg_temp.expect_error(format('SELECT editorial.set_waiting(%L,%L)',:'signal','submitter'),'22023','no_submitter_contact');
SELECT editorial.set_waiting(:'report','submitter');
COMMIT;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS ok;
SELECT pg_temp.expect_error(format('SELECT editorial.claim(%L)',:'report'),'55000','claimed_by_other');
SELECT editorial.claim(:'report','take_over');
SELECT pg_temp.assert_true((SELECT state='waiting' AND claimed_by=:'admin_actor' FROM editorial.list_contributions()
 WHERE contribution_id=:'report'),'a takeover keeps the waiting state');
SELECT editorial.claim(:'report','reassign',:'mod_actor');
COMMIT;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-mod')) IS NOT NULL AS ok;
SELECT editorial.set_waiting(:'report',NULL);
SELECT pg_temp.expect_error(format('SELECT editorial.decide_proposal(%L,%L)',:'hours_proposal','amended'),'22023','decision_invalid');
SELECT editorial.decide_proposal(:'hours_proposal','amended','"Lun 9-12"'::jsonb,'Orario verificato al telefono');
SELECT pg_temp.expect_error(format('SELECT editorial.close_contribution(%L,%L)',:'report','published'),'23514','publication_required');
SELECT pg_temp.expect_error(format('SELECT editorial.close_contribution(%L,%L,NULL,%L)',:'report','published',gen_random_uuid()),'23514','publication_required');
SELECT editorial.close_contribution(:'report','published',NULL,:'publication');
SELECT pg_temp.expect_error(format('SELECT editorial.claim(%L)',:'report'),'55000','contribution_closed');
SELECT pg_temp.expect_error(format('SELECT editorial.close_contribution(%L,%L)',:'proposal_case','rejected'),'22023','reason_required');
SELECT editorial.close_contribution(:'proposal_case','rejected','Già presente come altro servizio');
COMMIT;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true((SELECT bool_and(decision='rejected' AND decided_by=:'mod_actor') FROM editorial.proposals
 WHERE contribution_id=:'proposal_case'),'closure rejects undecided proposals, attributed');
SELECT pg_temp.assert_true((SELECT array_agg(action||':'||COALESCE(actor_id::text,'visitor') ORDER BY event_id)
 FROM editorial.events WHERE contribution_id=:'report')=ARRAY['submitted:visitor','claimed:'||:'mod_actor','waiting:'||:'mod_actor',
 'taken_over:'||:'admin_actor','reassigned:'||:'admin_actor','resumed:'||:'mod_actor','proposal_decided:'||:'mod_actor',
 'closed:'||:'mod_actor'],'every step is attributed to the verified person');
SELECT pg_temp.assert_true((SELECT outcome='published' AND publication_id=:'publication' AND closed_by=:'mod_actor'
 FROM editorial.contributions WHERE contribution_id=:'report'),'published outcome tied to its publication');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM audit.events WHERE details::text LIKE '%secret-value%' OR details::text LIKE '%reporter@%')
 AND NOT EXISTS(SELECT FROM i18n.content_units WHERE original_text LIKE '%secret-value%' OR original_text LIKE '%reporter@%')
 AND NOT EXISTS(SELECT FROM editorial.events WHERE details::text LIKE '%secret-value%' OR details::text LIKE '%reporter@%'),
 'contribution text and contact never reach canonical history or event details');

-- ============================================================================
-- Retention with controlled time
-- ============================================================================
INSERT INTO editorial.contributions(kind,category,service_id,public_revision_id,text,contact,created_at)
 VALUES('report','contacts',:'service',:'service_revision','Telefono vecchio','old@example.invalid',clock_timestamp()-interval '91 days'),
       ('report','contacts',:'service',:'service_revision','Telefono recente','new@example.invalid',clock_timestamp()-interval '89 days');
SET SESSION AUTHORIZATION egi_probe_retention;
SELECT pg_temp.expect_error('SELECT * FROM editorial.contributions','42501');
SELECT pg_temp.assert_true(editorial.purge_expired_contributions()=jsonb_build_object('contacts',2,'texts',0),
 'contacts go at closure or after 90 days; texts stay');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT contact IS NULL AND contact_deleted_at IS NOT NULL AND text IS NOT NULL
 FROM editorial.contributions WHERE contribution_id=:'report'),'closed report: contact gone, text kept');
SELECT pg_temp.assert_true((SELECT contact IS NULL FROM editorial.contributions WHERE text='Telefono vecchio')
 AND (SELECT contact='new@example.invalid' FROM editorial.contributions WHERE text='Telefono recente'),'only the 90-day contact goes');
UPDATE editorial.contributions SET closed_at=clock_timestamp()-interval '31 days' WHERE contribution_id=:'report';
UPDATE editorial.contributions SET closed_at=clock_timestamp()-interval '29 days' WHERE contribution_id=:'proposal_case';
SET SESSION AUTHORIZATION egi_probe_retention;
SELECT pg_temp.assert_true(editorial.purge_expired_contributions()=jsonb_build_object('contacts',0,'texts',1),
 'text goes 30 days after closure');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT text IS NULL AND text_deleted_at IS NOT NULL AND outcome='published'
 FROM editorial.contributions WHERE contribution_id=:'report'),'the outcome stays');
SELECT pg_temp.assert_true((SELECT value IS NULL AND decided_value IS NULL AND decision='amended'
 FROM editorial.proposals WHERE proposal_id=:'hours_proposal'),'proposal values go with the text; the decision stays');
SELECT pg_temp.assert_true((SELECT text='Mensa nuova' FROM editorial.contributions WHERE contribution_id=:'proposal_case')
 AND (SELECT count(*) FROM editorial.proposals WHERE contribution_id=:'proposal_case' AND value IS NOT NULL)=2,
 'a case closed 29 days ago keeps its text');

-- Remove the people and contributions created here.
DELETE FROM editorial.events;
DELETE FROM editorial.proposals;
DELETE FROM editorial.contributions;
UPDATE editorial.intake_settings SET open=true,window_limit=30,daily_limit=300;
DELETE FROM access.request_actors;
DELETE FROM access.events;
DELETE FROM access.sessions;
DELETE FROM access.invitations;
DELETE FROM access.identities;
DELETE FROM governance.actor_grants WHERE actor_id IN (SELECT actor_id FROM access.accounts);
WITH gone AS (DELETE FROM access.accounts RETURNING actor_id)
DELETE FROM governance.actors WHERE actor_id IN (SELECT actor_id FROM gone);
-- The canonical fixture is immutable; its actor stops naming this login.
UPDATE governance.actors SET database_role=('contract-14-'||actor_id)::name,enabled=false WHERE actor_id=:'editor';
DROP ROLE egi_probe_intake;
DROP ROLE egi_probe_desk;
DROP ROLE egi_probe_retention;
