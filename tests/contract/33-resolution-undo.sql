-- Real expected-version undo restores values and keeps invalid decisions unresolved.
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT preparation.reference_catalog(:'ws','{"kind":"organization","search":"Associazione Alfa"}')#>'{entries,0,target}' AS target \gset
SELECT jsonb_build_object('fact_id',:'fid','state','confirmed','context','{}'::jsonb,'candidates','[]'::jsonb,'selected',jsonb_build_object('target',:'target'::jsonb,'role','provider')) AS confirmed \gset
SELECT jsonb_set(:'current'::jsonb->'payload','{resolutions}',jsonb_build_array(:'confirmed'::jsonb)) AS mapped \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',:'mapped'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS mapped_version \gset
SELECT jsonb_set(jsonb_set(jsonb_set(:'mapped'::jsonb,'{source_facts,0,value}','"Corrected name"'),'{field_origins}',(:'mapped'::jsonb->'field_origins')||'{"/source_facts/0/value":{"state":"manual"}}'),'{resolutions}','[]') AS corrected \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'mapped_version','payload',:'corrected'::jsonb)),gen_random_uuid()) AS correction \gset
SELECT gen_random_uuid() AS undo_key \gset
SELECT preparation.undo_operation(:'ws',(:'correction'::jsonb->>'operation_id')::uuid,:'undo_key') AS undone \gset
SELECT pg_temp.assert_true(preparation.undo_operation(:'ws',(:'correction'::jsonb->>'operation_id')::uuid,:'undo_key')=:'undone'::jsonb,'undo receipt stable across replay');
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT pg_temp.assert_true(:'current'::jsonb#>>'{payload,source_facts,0,value}'='Associazione Alfa','undo restores original current value');
SELECT pg_temp.assert_true(:'current'::jsonb#>>'{payload,resolutions,0,state}'='unresolved' AND NOT (:'current'::jsonb#>'{payload,resolutions,0}') ? 'confirmation','value compensation requires fresh reference confirmation');
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',:'mapped_version')#>>'{version,payload,resolutions,0,state}'='confirmed','historical confirmed decision unchanged');
SELECT jsonb_build_object('fact_id',:'fid','state','proposed','context','{}'::jsonb,'candidates',jsonb_build_array(jsonb_build_object('target',:'target'::jsonb,'rank',1,'reason','Controlled prior proposal'))) AS proposed \gset
SELECT jsonb_set(:'current'::jsonb->'payload','{resolutions}',jsonb_build_array(:'proposed'::jsonb)) AS mapped \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',:'mapped'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS proposed_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'proposed_version','payload',:'corrected'::jsonb)),gen_random_uuid()) AS correction \gset
SELECT preparation.undo_operation(:'ws',(:'correction'::jsonb->>'operation_id')::uuid,gen_random_uuid());
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT pg_temp.assert_true(:'current'::jsonb#>>'{payload,source_facts,0,value}'='Associazione Alfa' AND :'current'::jsonb#>>'{payload,resolutions,0,state}'='unresolved','undo also invalidates a restored proposed mapping after value change');
-- Undoing only a rejected proposal restores it when references remain current.
SELECT jsonb_set(:'current'::jsonb->'payload','{resolutions}',jsonb_build_array(:'proposed'::jsonb)) AS mapped \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',:'mapped'::jsonb)),gen_random_uuid())->'items'->0->>'after' AS proposed_version \gset
SELECT jsonb_set(:'mapped'::jsonb,'{resolutions}','[]') AS rejected \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'proposed_version','payload',:'rejected'::jsonb)),gen_random_uuid()) AS rejection \gset
SELECT preparation.undo_operation(:'ws',(:'rejection'::jsonb->>'operation_id')::uuid,gen_random_uuid());
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT pg_temp.assert_true(:'current'::jsonb#>>'{payload,resolutions,0,state}'='proposed','unchanged value/current references can restore a proposal');
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','payload',:'rejected'::jsonb)),gen_random_uuid()) AS rejection \gset
-- A newer organization working head must not be revived by undo.
SELECT editorial.revision_body((:'target'::jsonb->>'expected_work')::uuid) AS org_body \gset
SELECT governance.save_revision('organization',(:'target'::jsonb->>'organization_id')::uuid,(:'target'::jsonb->>'expected_work')::uuid,(:'target'::jsonb->>'expected_public')::uuid,:'org_body','New exact working head');
SELECT preparation.undo_operation(:'ws',(:'rejection'::jsonb->>'operation_id')::uuid,gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'item',NULL)#>>'{version,payload,resolutions,0,state}'='unresolved','stale reference invalidated without preventing compensation');
RESET SESSION AUTHORIZATION;
ROLLBACK;
