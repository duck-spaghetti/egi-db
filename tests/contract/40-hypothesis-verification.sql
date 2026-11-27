-- New evidence UUID/path cannot turn the same trigger quotation into proof.
\set keep_interpretation_transaction 1
\ir 34-interpretations.sql
\unset keep_interpretation_transaction
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT :'current'::jsonb#>'{payload,interpretation_hypotheses,0}' AS hypothesis \gset
SELECT preparation.read_item(:'ws',:'item',(:'hypothesis'::jsonb#>>'{basis,item_version}')::uuid)->'version' AS anchor \gset
SELECT (e||jsonb_build_object('id',gen_random_uuid(),'path','/service/name')) AS duplicate FROM jsonb_array_elements(:'anchor'::jsonb->'evidence') e WHERE (:'hypothesis'::jsonb->'trigger_evidence_ids') @> jsonb_build_array(e->'id') \gset
SELECT jsonb_set(jsonb_set(:'current'::jsonb->'payload','{evidence}',(:'current'::jsonb#>'{payload,evidence}')||jsonb_build_array(:'duplicate'::jsonb)),'{interpretation_hypotheses,0}',:'hypothesis'::jsonb||jsonb_build_object('state','verified','verification',jsonb_build_object('actor_id',gen_random_uuid(),'verified_at','1900-01-01','decision_id',gen_random_uuid(),'evidence_ids',jsonb_build_array(:'duplicate'::jsonb->'id')))) AS attempted \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',:'attempted'::jsonb))),'22023','hypothesis_trigger_is_not_verification');
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS plain_item \gset
SELECT preparation.read_item(:'ws',(:'plain_item'::jsonb->>'item_id')::uuid,NULL)->'version' AS plain_version \gset
SELECT (:'plain_version'::jsonb->'payload')||'{"schema_version":3,"source_facts":[],"resolutions":[],"interpreted_classifications":[],"interpretation_hypotheses":[]}' AS upgraded_payload \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'plain_item'::jsonb->>'item_id','expected_version',:'plain_version'::jsonb->>'id','payload',:'upgraded_payload'::jsonb)),gen_random_uuid()) AS upgrade \gset
SELECT preparation.undo_operation(:'ws',(:'upgrade'::jsonb->>'operation_id')::uuid,gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',(:'plain_item'::jsonb->>'item_id')::uuid,NULL)#>>'{version,payload,schema_version}'='3' AND preparation.read_item(:'ws',(:'plain_item'::jsonb->>'item_id')::uuid,NULL)#>'{version,payload,source_facts}'='[]'::jsonb,'v1-to-v3 upgrade undo remains valid schema3 without dropping required arrays');
-- Explicit manual reconciliation must not be undone by an echoed confirmation.
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT e->'id' AS category_evidence FROM jsonb_array_elements(:'current'::jsonb->'evidence') e WHERE e->>'path'='/source_facts/1/source_value' \gset
SELECT (:'current'::jsonb#>'{payload,interpreted_classifications,0}')||jsonb_build_object('state','confirmed','method','manual','job_id',NULL,
 'basis',jsonb_build_object('item_version',:'current'::jsonb->>'id','field_path','/source_facts/1/source_value','value_digest',encode(sha256(convert_to((:'current'::jsonb#>'{payload,source_facts,1,source_value}')::text,'UTF8')),'hex'),'evidence_ids',jsonb_build_array(:'category_evidence'::jsonb)),
 'candidates',jsonb_build_array(jsonb_build_object('target',:'current'::jsonb#>'{payload,interpreted_classifications,0,candidates,0,target}','reason','Explicit manual review of the original label','support_evidence_ids',jsonb_build_array(:'category_evidence'::jsonb))),
 'selected',jsonb_build_object('target',:'current'::jsonb#>'{payload,interpreted_classifications,0,candidates,0,target}','actor_id',gen_random_uuid(),'confirmed_at','1900-01-01')) AS fresh_confirmation \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',jsonb_set(:'current'::jsonb->'payload','{interpreted_classifications,0}',:'fresh_confirmation'))),gen_random_uuid());
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS confirmed_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'confirmed_version'::jsonb->>'id','payload',
 jsonb_set(jsonb_set(:'confirmed_version'::jsonb->'payload','{service,classifications}','[]'),'{field_origins}',(:'confirmed_version'::jsonb#>'{payload,field_origins}')||jsonb_build_object('/service/classifications',jsonb_build_object('state','cleared'))))),gen_random_uuid());
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS cleared_version \gset
SELECT pg_temp.assert_true(:'cleared_version'::jsonb#>'{payload,service,classifications}'='[]'::jsonb AND :'cleared_version'::jsonb#>>'{payload,interpreted_classifications,0,state}'='proposed' AND :'cleared_version'::jsonb#>'{payload,interpreted_classifications,0,selected}'='null'::jsonb,'manual category clear resets echoed interpretation selection without restoring association');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'cleared_version'::jsonb->>'id','payload',jsonb_set(:'cleared_version'::jsonb->'payload','{service,cost_note}','"Unrelated private edit"'))),gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>'{version,payload,service,classifications}'='[]'::jsonb,'later unrelated save cannot silently re-add cleared association');
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS after_clear \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'after_clear'::jsonb->>'id','payload',jsonb_set(:'after_clear'::jsonb->'payload','{interpreted_classifications,0}',:'fresh_confirmation'))),gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,interpreted_classifications,0,state}'='confirmed' AND jsonb_array_length(preparation.read_item(:'ws',:'item',NULL)#>'{version,payload,service,classifications}')>0 AND preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,field_origins,/service/classifications,state}'='manual','fresh deliberate confirmation may reselect after a clear');
RESET SESSION AUTHORIZATION;
ROLLBACK;
