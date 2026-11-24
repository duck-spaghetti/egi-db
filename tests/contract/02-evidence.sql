BEGIN;
\ir helpers.sql
\ir fixtures.sql
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM sources.captures WHERE content_hash='same-bytes'),'two retrieval observations');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM sources.record_versions WHERE content_hash='same-bytes'),'one reused raw version');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM sources.normalized_subjects WHERE record_version_id='54000000-0000-0000-0000-000000000001'),'two parser interpretations');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM sources.records WHERE external_key='same-upstream-key'),'dataset-scoped upstream keys');
SELECT pg_temp.expect_error($q$INSERT INTO sources.records(dataset_id,external_key,identity_method) VALUES('51000000-0000-0000-0000-000000000001','same-upstream-key','upstream')$q$,'23505');
SELECT pg_temp.expect_error($q$UPDATE sources.assertions SET normalized_value='"overwritten"'$q$,'55000','immutable_record');
SELECT pg_temp.expect_error($q$INSERT INTO sources.capture_records VALUES('52000000-0000-0000-0000-000000000003','54000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000002','wrong dataset')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO sources.normalized_subjects(record_version_id,run_id,subject_kind,subject_locator,normalized_payload) VALUES('54000000-0000-0000-0000-000000000002','55000000-0000-0000-0000-000000000001','service','wrong','{}')$q$,'23514','interpretation_capture_mismatch');
DO $$ DECLARE rev uuid; owner uuid; decision uuid; d uuid; BEGIN
 rev:=pg_temp.save('service','{"name":"Evidence service","delivery_mode":"telephone"}');
 SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;
 -- The field decision is accountable and retains original assertion references.
 SELECT value_decision_id INTO decision FROM governance.value_decisions WHERE revision_id=rev AND field_code='name';
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM governance.value_evidence WHERE value_decision_id=decision AND assertion_id='57000000-0000-0000-0000-000000000001'),'selected value evidence');
 PERFORM pg_temp.expect_error(format('INSERT INTO governance.value_evidence VALUES (%L,%L,%L)',decision,'57000000-0000-0000-0000-000000000003','contradicting'),'55000','sealed_revision_evidence');
 INSERT INTO governance.resolution_decisions(operation,actor_id,reason) VALUES('link','10000000-0000-0000-0000-000000000001','synthetic identity link') RETURNING decision_id INTO d;
 INSERT INTO governance.resolution_members VALUES(d,'56000000-0000-0000-0000-000000000001',owner,'service','linked');
 INSERT INTO governance.subject_bindings VALUES('56000000-0000-0000-0000-000000000001',owner,d,'linked');
 PERFORM pg_temp.expect_error(format('INSERT INTO governance.resolution_members VALUES(%L,%L,%L,%L,%L)',d,'56000000-0000-0000-0000-000000000002',owner,'organization','wrong'),'23503');
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM sources.assertions WHERE attribute_code='hours'),'positive and negative hours retained');
END $$;
ROLLBACK;
