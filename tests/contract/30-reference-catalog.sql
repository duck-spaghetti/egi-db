-- EGI-117: real session/private save, bounded catalog and atomic acceptance.
\ir helpers.sql
BEGIN;
CREATE ROLE egi_probe30 LOGIN IN ROLE egi_editorial;
SELECT access.bootstrap_admin('admin30','Reference reviewer',encode(sha256(convert_to('invite30','UTF8')),'hex')) AS account \gset
SET LOCAL SESSION AUTHORIZATION egi_probe30;
SELECT access.accept_invitation(encode(sha256(convert_to('invite30','UTF8')),'hex'),'password','$argon2id$a',NULL,NULL,'JBSWY3DPEHPK3PXP');
SELECT access.open_session(:'account',encode(sha256(convert_to('session30','UTF8')),'hex'),'password',true);
SELECT access.verify_session(encode(sha256(convert_to('session30','UTF8')),'hex'))->>'actor_id' AS actor \gset
SELECT editorial.register_community_source('{"name":"Reference contract source","source_kind":"directory"}',gen_random_uuid())->>'source_id' AS src \gset
SELECT preparation.create_workspace(:'src','Reference resolution',gen_random_uuid())->>'id' AS ws \gset
SELECT preparation.put_input(:'ws',1,'text',convert_to('Associazione Alfa Mensa PRIVATE UNSENT','UTF8'),'true',gen_random_uuid())->>'input_id' AS inp \gset
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS item_info \gset
SELECT :'item_info'::jsonb->>'item_id' AS item,:'item_info'::jsonb->>'version_id' AS base \gset
SELECT gen_random_uuid() AS fid,gen_random_uuid() AS catfid \gset
SELECT (preparation.read_item(:'ws',:'item',NULL)#>'{version,payload}')||jsonb_build_object('schema_version',2,
 'service',jsonb_build_object('name','Mensa','delivery_mode','telephone','description','Public meal information','contacts',jsonb_build_array(jsonb_build_object('channel_type','phone','value','0612345678','is_public',true))),
 'outcome','confirmed','source_facts',jsonb_build_array(
 jsonb_build_object('fact_id',:'fid','subject','service','kind','organization_name','source_value','Associazione Alfa','value','Associazione Alfa'),
 jsonb_build_object('fact_id',:'catfid','subject','service','kind','category_label','source_value','Mensa','value','Mensa')),
 'resolutions','[]'::jsonb,'evidence',jsonb_build_array(
 jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value','kind','stated','input_id',:'inp','input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','quote','Associazione Alfa','span',jsonb_build_object('start',0,'end',17)),
 jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/1/source_value','kind','stated','input_id',:'inp','input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','quote','Mensa','span',jsonb_build_object('start',18,'end',23)))) AS payload \gset
SELECT jsonb_build_object('kind','new_organization','body',jsonb_build_object('name','Associazione Alfa','original_language','it','territories','[]'::jsonb)) AS new_target \gset
SELECT preparation.reference_catalog(:'ws','{"kind":"organization","search":"Associazione Alfa"}')->'context' AS org_context \gset
SELECT jsonb_build_object('target',:'new_target'::jsonb,'role','provider') AS selected \gset
SELECT jsonb_set(:'payload'::jsonb,'{resolutions}',jsonb_build_array(jsonb_build_object('fact_id',:'fid','state','confirmed','context',:'org_context'::jsonb,'candidates','[]'::jsonb,'selected',:'selected'::jsonb,
 'confirmation',jsonb_build_object('actor_id',gen_random_uuid(),'item_version',gen_random_uuid(),'fact_value','spoof')))) AS payload \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'base','payload',:'payload'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS version \gset
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,resolutions,0,confirmation,actor_id}'=:'actor','server replaces forged confirmer');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,resolutions,0,confirmation,item_version}'=:'base','confirmation bound to actual item base');
SELECT pg_temp.assert_true(preparation.reference_catalog(:'ws','{"kind":"organization"}')->'entries'='[]'::jsonb,'preparation confirmation creates no canonical organization');
SELECT pg_temp.expect_error(format('SELECT preparation.reference_catalog(%L,%L)',gen_random_uuid(),'{"kind":"organization"}'),'P0002','preparation_not_found');
SELECT pg_temp.expect_error(format('SELECT preparation.reference_catalog(%L,%L)',:'ws','{"kind":"organization","limit":51}'),'22023','invalid_catalog_query');
SELECT pg_temp.expect_error(format('SELECT preparation.reference_catalog(%L,%L)',:'ws','{"kind":"classification"}'),'22023','taxonomy_context_required');
SELECT preparation.submit_item(:'ws',:'item',:'version',gen_random_uuid())->>'contribution_id' AS contribution \gset
SELECT jsonb_build_object('schema_version',2,'expected_service_work',NULL,'expected_service_public',NULL,
 'service_operations',jsonb_build_array(jsonb_build_object('op','add','path','/name','value','Mensa','evidence_ids','[]'::jsonb),
 jsonb_build_object('op','add','path','/delivery_mode','value','telephone','evidence_ids','[]'::jsonb),
 jsonb_build_object('op','add','path','/description','value','Public meal information','evidence_ids','[]'::jsonb),
 jsonb_build_object('op','add','path','/contacts','value',:'payload'::jsonb#>'{service,contacts}','evidence_ids','[]'::jsonb)),
 'location',jsonb_build_object('kind','none'),'observations',jsonb_build_array(jsonb_build_object('paths',jsonb_build_array('/service'),'method','other','note','Explicit service check')),
 'reason','Explicit organization and role decision','fact_actions',jsonb_build_array(jsonb_build_object('fact_id',:'fid','action','create','context',:'org_context'::jsonb,'selected',:'selected'::jsonb,'note','Checked organization identity and provider role','reconcile','retain'))) AS decision \gset
-- A raw name alone never asserts an organizational role.
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',(:'decision'::jsonb#-'{fact_actions,0,selected,role}')),'22023','explicit_organization_role_required');
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',(:'decision'::jsonb#-'{fact_actions,0,note}')),'22023','explicit_fact_decision_required');
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',jsonb_set(:'decision'::jsonb,'{fact_actions,0,fact_id}',to_jsonb(gen_random_uuid()))),'22023','invalid_fact_action');
-- Failure after creating the organization must roll back the whole statement.
SELECT jsonb_set(:'decision'::jsonb,'{location}','{"kind":"invalid"}') AS invalid_decision \gset
SELECT pg_temp.expect_error(format('SELECT editorial.accept_community_item(%L,%L,gen_random_uuid())',:'contribution',:'invalid_decision'),'22023','invalid_community_location');
SELECT pg_temp.assert_true(preparation.reference_catalog(:'ws','{"kind":"organization"}')->'entries'='[]'::jsonb,'failed service acceptance leaves no organization');
\if :{?prepare_reference_race}
SELECT access.open_session(:'account',encode(sha256(convert_to('session30-a','UTF8')),'hex'),'password',true);
SELECT access.open_session(:'account',encode(sha256(convert_to('session30-b','UTF8')),'hex'),'password',true);
RESET SESSION AUTHORIZATION;
CREATE TABLE public.egi_reference_race(contribution uuid,decision jsonb);
INSERT INTO public.egi_reference_race VALUES(:'contribution',:'decision');
GRANT SELECT ON public.egi_reference_race TO egi_probe30;
COMMIT;
\quit
\endif
SELECT editorial.accept_community_item(:'contribution',:'decision',gen_random_uuid()) AS accepted \gset
SELECT pg_temp.assert_true(editorial.accept_community_item(:'contribution',:'decision',gen_random_uuid())->>'initial_revision_id'=:'accepted'::jsonb->>'initial_revision_id','retry creates one draft only');
SELECT preparation.reference_catalog(:'ws','{"kind":"organization","limit":1}')#>'{entries,0,target}' AS org_target \gset
SELECT :'org_target'::jsonb->>'organization_id' AS org,:'org_target'::jsonb->>'expected_work' AS orgrev \gset
SELECT pg_temp.assert_true(preparation.reference_catalog(:'ws','{"kind":"organization"}')->'entries' @> jsonb_build_array(jsonb_build_object('label','Associazione Alfa','published',false)),'draft catalog contains actual name and status');
SELECT pg_temp.assert_true(editorial.revision_body(:'orgrev')->>'name'='Associazione Alfa','organization canonical serialization');
SELECT pg_temp.assert_true(position('PRIVATE UNSENT' IN editorial.read_community_snapshot(:'contribution')::text)=0,'selective snapshot excludes unsent material');
-- Source admission and organization publication are separate explicit steps.
SELECT pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',:'orgrev','approved','Not admitted yet'),'23514','community_source_not_admitted');
SELECT editorial.admit_community_source(:'src','Checked original source');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM governance.publication_diagnostics((:'accepted'::jsonb->>'initial_revision_id')::uuid) WHERE code='unpublished_organization'),'linked organization still needs explicit publication');
SELECT pg_temp.assert_true((SELECT count(*) FROM data.organizations)=1,'one canonical organization after all failure/retry attempts');
SELECT pg_temp.assert_true((SELECT count(*) FROM editorial.community_fact_resolutions)=1,'one attributed resolution');
SELECT pg_temp.assert_true((SELECT count(*) FROM sources.assertions a JOIN sources.normalized_subjects n USING(subject_id) WHERE n.subject_kind='organization' AND a.method='community_stated')=1,'source name becomes its own organization assertion');
SELECT source_id AS editorial_source FROM sources.registry WHERE code='egi_editorial' \gset
SET SESSION AUTHORIZATION egi_probe30;
SELECT editorial.admit_community_source(:'editorial_source','Checked editorial observations');
SELECT pg_temp.expect_error(format('SELECT governance.review_revision(%L,NULL,%L,%L)',:'accepted'::jsonb->>'initial_revision_id','approved','Before organization publication'),'23514','unpublished_organization');
SELECT governance.review_revision(:'orgrev',NULL,'approved','Explicit organization review') AS org_review \gset
SELECT governance.publish_revision(:'orgrev',:'org_review',NULL) AS org_publication \gset
SELECT governance.review_revision((:'accepted'::jsonb->>'initial_revision_id')::uuid,NULL,'approved','Explicit service review') AS service_review \gset
SELECT governance.publish_revision((:'accepted'::jsonb->>'initial_revision_id')::uuid,:'service_review',NULL) AS service_publication \gset
SELECT editorial.close_community_item(:'contribution','published',NULL,:'service_publication');
RESET SESSION AUTHORIZATION;
-- Controlled canonical fixtures use real governance APIs and explicit evidence.
CREATE FUNCTION pg_temp.catalog_save(kind text,payload jsonb,entity uuid DEFAULT NULL,working uuid DEFAULT NULL,published uuid DEFAULT NULL) RETURNS uuid
LANGUAGE sql AS $$ SELECT governance.save_revision(kind,entity,working,published,payload||jsonb_build_object('evidence',jsonb_build_object('record',jsonb_build_array(jsonb_build_object('assertion_id',(current_setting('egi.catalog_fixture_proof'))::uuid,'role','supporting')))),'Catalog fixture') $$;
CREATE FUNCTION pg_temp.catalog_publish(rev uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE approved uuid; BEGIN approved:=governance.review_revision(rev,NULL,'approved','Catalog fixture'); RETURN governance.publish_revision(rev,approved,NULL); END $$;
CREATE FUNCTION pg_temp.check_catalog(wid uuid,item uuid,payload jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r uuid; t uuid; other_t uuid; v uuid; vr uuid; axis uuid; other_axis uuid; term uuid; other_term uuid; tr uuid; otr uuid; release uuid; adoption uuid; future_adoption uuid;
 context jsonb; target jsonb; result jsonb; proof jsonb; prepared jsonb; ver uuid; contribution uuid; decision jsonb; existing jsonb; accepted jsonb; service uuid; work uuid; public_head uuid; started timestamptz; iteration integer;
BEGIN
 proof:=editorial.record_observation('service','{"record":"Synthetic catalog fixtures"}','other','Contract fixture');
 PERFORM set_config('egi.catalog_fixture_proof',proof->>'record',true);
 r:=pg_temp.catalog_save('territory','{"code":"ref-current","name":"Current territory","timezone_name":"Europe/Rome"}'); PERFORM pg_temp.catalog_publish(r);
 SELECT entity_id INTO t FROM governance.entity_revisions WHERE revision_id=r;
 r:=pg_temp.catalog_save('territory','{"code":"ref-future","name":"Future territory","timezone_name":"Europe/Rome"}'); PERFORM pg_temp.catalog_publish(r);
 SELECT entity_id INTO other_t FROM governance.entity_revisions WHERE revision_id=r;
 vr:=pg_temp.catalog_save('taxonomy_vocabulary','{"code":"ref-vocabulary","name":"Controlled catalog"}'); PERFORM pg_temp.catalog_publish(vr);
 SELECT entity_id INTO v FROM governance.entity_revisions WHERE revision_id=vr;
 axis:=governance.create_taxonomy_axis(v,'service_type'); other_axis:=governance.create_taxonomy_axis(v,'audience');
 tr:=pg_temp.catalog_save('taxonomy_term',jsonb_build_object('name','Mensa','vocabulary_id',v,'axis_id',axis,'code','meal')); PERFORM pg_temp.catalog_publish(tr);
 SELECT entity_id INTO term FROM governance.entity_revisions WHERE revision_id=tr;
 otr:=pg_temp.catalog_save('taxonomy_term',jsonb_build_object('name','Mensa','vocabulary_id',v,'axis_id',other_axis,'code','unrelated')); PERFORM pg_temp.catalog_publish(otr);
 SELECT entity_id INTO other_term FROM governance.entity_revisions WHERE revision_id=otr;
 release:=governance.freeze_taxonomy_release(vr,'v1',jsonb_build_array(jsonb_build_object('axis_id',axis,'label','Service type'),jsonb_build_object('axis_id',other_axis,'label','Audience')),
 jsonb_build_array(jsonb_build_object('term_id',term,'revision_id',tr),jsonb_build_object('term_id',other_term,'revision_id',otr)),'[]','Controlled release');
 adoption:=governance.adopt_taxonomy_release(t,release,current_date-1,CASE WHEN current_setting('egi.reference_expiry',true)='on' THEN current_date END,'Current context');
 future_adoption:=governance.adopt_taxonomy_release(other_t,release,current_date+1,NULL,'Future context');
 -- Identical labels do not coalesce organization identities.
 r:=pg_temp.catalog_save('organization','{"name":"Same name","original_language":"it"}');
 r:=pg_temp.catalog_save('organization','{"name":"Same name","original_language":"it"}');
 result:=preparation.catalog('{"kind":"organization","search":"Same name","limit":1}');
 PERFORM pg_temp.assert_true(jsonb_array_length(result->'entries')=1 AND result->>'next_offset'='1' AND result->'complete'='false'::jsonb,'bounded catalog exposes continuation');
 proof:=preparation.catalog('{"kind":"organization","search":"Same name","limit":1,"offset":1}');
 PERFORM pg_temp.assert_true(result#>>'{entries,0,target,organization_id}'<>proof#>>'{entries,0,target,organization_id}','same name retains distinct identities');
 started:=clock_timestamp();
 FOR iteration IN 1..20 LOOP proof:=preparation.catalog('{"kind":"organization"}'); END LOOP;
 RAISE NOTICE 'Reference catalog warm SQL mean (20 calls, 3 organizations): % ms',extract(epoch FROM clock_timestamp()-started)*1000/20;

 r:=(result#>>'{entries,0,target,expected_work}')::uuid;
 proof:=editorial.revision_body(r);
 r:=governance.save_revision('organization',(result#>>'{entries,0,target,organization_id}')::uuid,r,NULL,proof,'Round-trip organization');
 PERFORM pg_temp.assert_true(editorial.revision_body(r)=proof,'organization body round trip keeps canonical grammar and proof');
 result:=preparation.catalog('{"kind":"organization","search":"Same name","limit":1}');
 context:=result->'context';
 r:=pg_temp.catalog_save('organization','{"name":"Same name","original_language":"it"}');
 PERFORM pg_temp.expect_error(format('SELECT preparation.validate_reference(%L,%L,%L)','{"kind":"organization_name"}',context,
  '{"kind":"new_organization","body":{"name":"Same name","original_language":"it","territories":[]}}'),'40001','organization_catalog_changed');
 target:=result#>'{entries,0,target}';
 r:=pg_temp.catalog_save('organization','{"name":"Renamed same name","original_language":"it"}',(target->>'organization_id')::uuid,(target->>'expected_work')::uuid,NULL);
 PERFORM pg_temp.expect_error(format('SELECT preparation.validate_reference(%L,%L,%L)','{"kind":"organization_name"}','{}',target),'40001','reference_heads_changed');
 context:=jsonb_build_object('territory_id',t,'axis_id',axis);
 -- Use internal helpers only as cluster owner; public wrappers are tested below.
 result:=preparation.catalog(context||jsonb_build_object('kind','classification'));
 PERFORM pg_temp.assert_true(jsonb_array_length(result->'entries')=1 AND result#>>'{entries,0,target,term_id}'=term::text,'same label on another axis excluded');
 target:=result#>'{entries,0,target}';
 PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',context,target);
 -- An explicit later selection reuses the original entity and preserves unrelated
 -- roles while adding a category against the adopted territorial context.
 prepared:=jsonb_set(payload,'{resolutions}','[]');
 ver:=(preparation.read_item(wid,item,NULL)#>>'{version,id}')::uuid;
 ver:=(preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',ver,'payload',prepared)),gen_random_uuid())#>>'{items,0,after}')::uuid;
 contribution:=(preparation.submit_item(wid,item,ver,gen_random_uuid())->>'contribution_id')::uuid;
 service:=editorial.community_identity(contribution);
 SELECT h.revision_id,p.revision_id INTO work,public_head FROM governance.working_heads h LEFT JOIN governance.published_heads p USING(entity_id) WHERE h.entity_id=service;
 existing:=preparation.catalog('{"kind":"organization","search":"Associazione Alfa"}')#>'{entries,0,target}';
 decision:=jsonb_build_object('schema_version',2,'expected_service_work',work,'expected_service_public',public_head,
  'service_operations',jsonb_build_array(jsonb_build_object('op','replace','path','/territories','value',jsonb_build_array(t),'evidence_ids','[]'::jsonb)),
  'location',jsonb_build_object('kind','none'),'reason','Explicit existing organization and classification',
  'observations',jsonb_build_array(jsonb_build_object('paths',jsonb_build_array('/service/territories'),'method','other','note','Checked territorial scope')),
  'fact_actions',jsonb_build_array(
   jsonb_build_object('fact_id',payload#>'{source_facts,0,fact_id}','action','select','context','{}'::jsonb,'selected',jsonb_build_object('target',existing,'role','organizer'),'note','Checked distinct organizer role','reconcile','retain'),
   jsonb_build_object('fact_id',payload#>'{source_facts,1,fact_id}','action','select','context',context,'selected',jsonb_build_object('target',target),'note','Checked source label against service-type axis','reconcile','retain')));
 accepted:=editorial.accept_community_item(contribution,decision,gen_random_uuid());
 PERFORM pg_temp.assert_true(accepted->>'service_id'=service::text,'later proposal retains canonical service identity');
 prepared:=editorial.revision_body((accepted->>'initial_revision_id')::uuid);
 PERFORM pg_temp.assert_true(jsonb_array_length(prepared->'organizations')=2 AND prepared->'organizations' @> jsonb_build_array(jsonb_build_object('role_code','provider'),jsonb_build_object('role_code','organizer')),'new selection preserves an unrelated organizational role');
 PERFORM pg_temp.assert_true(prepared->'classifications' @> jsonb_build_array(jsonb_build_object('term_id',term,'adoption_id',adoption)),'explicit context-bound category accepted');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM data.organizations WHERE entity_id=(existing->>'organization_id')::uuid)=1,'existing organization selection creates no duplicate');

 PERFORM pg_temp.expect_error(format('SELECT preparation.validate_reference(%L,%L,%L)','{"kind":"category_label","subject":"service"}',jsonb_set(context,'{axis_id}',to_jsonb(other_axis)),target),'40001','taxonomy_context_stale');
 result:=preparation.catalog(jsonb_build_object('kind','classification','territory_id',other_t,'axis_id',axis));
 PERFORM pg_temp.assert_true(result->'entries'='[]'::jsonb,'future adoption unavailable before start date');
 PERFORM pg_temp.expect_error(format('SELECT preparation.validate_reference(%L,%L,%L)','{"kind":"category_label","subject":"service"}',jsonb_build_object('territory_id',other_t,'axis_id',axis),jsonb_set(target,'{adoption_id}',to_jsonb(future_adoption))),'40001','taxonomy_context_stale');
END $$;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.check_catalog(:'ws',:'item',:'payload');
RESET SESSION AUTHORIZATION;
\if :{?keep_reference_transaction}
\else
\if :{?keep_references}
COMMIT;
\else
ROLLBACK;
\endif
\endif
