BEGIN;
\ir helpers.sql
INSERT INTO governance.actors(actor_id,database_role,display_name) VALUES ('10000000-0000-0000-0000-000000000001',session_user,'Synthetic editor');
SELECT pg_temp.assert_true(governance.current_actor()='10000000-0000-0000-0000-000000000001','trusted actor');
INSERT INTO data.entities(entity_id,entity_kind) VALUES ('20000000-0000-0000-0000-000000000001','service'),('20000000-0000-0000-0000-000000000002','organization');
INSERT INTO data.services(entity_id) VALUES ('20000000-0000-0000-0000-000000000001');
SELECT pg_temp.expect_error($q$INSERT INTO data.organizations(entity_id) VALUES ('20000000-0000-0000-0000-000000000001')$q$,'23503');
INSERT INTO governance.entity_revisions(revision_id,entity_id,entity_kind,revision_number,actor_id,reason) VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','service',1,'10000000-0000-0000-0000-000000000001','Synthetic revision');
SELECT pg_temp.expect_error($q$INSERT INTO governance.entity_revisions(entity_id,entity_kind,revision_number,actor_id,reason) VALUES ('20000000-0000-0000-0000-000000000001','organization',2,'10000000-0000-0000-0000-000000000001','wrong kind')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO governance.working_heads VALUES ('20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001')$q$,'23503');
INSERT INTO i18n.content_units(content_id,owner_entity_id,introduced_revision_id,field_code,original_text) VALUES ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','name','Draft name');
SELECT pg_temp.expect_error($q$INSERT INTO i18n.revision_content_links(revision_id,entity_id,field_code,content_id) VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','description','40000000-0000-0000-0000-000000000001')$q$,'23514','content_binding_mismatch');
INSERT INTO i18n.revision_content_links(revision_id,entity_id,field_code,content_id) VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','name','40000000-0000-0000-0000-000000000001');
UPDATE governance.entity_revisions SET sealed_at=clock_timestamp();
SELECT pg_temp.expect_error($q$UPDATE governance.entity_revisions SET reason='changed'$q$,'55000','immutable_revision');
SELECT pg_temp.expect_error($q$DELETE FROM i18n.content_units$q$,'55000','immutable_record');
SELECT pg_temp.expect_error($q$INSERT INTO i18n.revision_content_links(revision_id,entity_id,field_code,content_id) VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','name','40000000-0000-0000-0000-000000000001')$q$,'55000','sealed_revision');
SELECT pg_temp.assert_true(NOT has_table_privilege('public','governance.entity_revisions','UPDATE'),'public cannot write');
ROLLBACK;
