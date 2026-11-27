-- Explicit delivery/access context is input support, never a required basis.
\set keep_context_transaction 1
\ir 39-workbench-context.sql
\unset keep_context_transaction
UPDATE preparation.ai_settings SET config_version='context-fixture-1';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.create_workspace(:'src','Exact access context',gen_random_uuid())->>'id' AS access_ws \gset
SELECT 'Mensa Accesso su appuntamento online PRIVATE UNSENT' AS access_text \gset
SELECT preparation.put_input(:'access_ws',1,'text',convert_to(:'access_text','UTF8'),'true',gen_random_uuid())->>'input_id' AS access_input \gset
SELECT preparation.create_items(:'access_ws',:'access_input',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS access_item \gset
SELECT preparation.read_item(:'access_ws',(:'access_item'::jsonb->>'item_id')::uuid,NULL)->'version' AS access_version \gset
SELECT (:'access_version'::jsonb->'payload')||jsonb_build_object('service',jsonb_build_object('description','Mensa','delivery_mode','online','cost_note','PRIVATE NOTE',
 'conditions',jsonb_build_array(jsonb_build_object('condition_kind','appointment','requirement_state','required','details','Accesso su appuntamento'))),
 'field_origins',jsonb_build_object('/service/cost_note',jsonb_build_object('state','manual')),
 'evidence',jsonb_build_array(
 jsonb_build_object('id',gen_random_uuid(),'path','/service/description','kind','stated','input_id',:'access_input','input_hash',preparation.read_input(:'access_ws',:'access_input')->>'sha256','quote','Mensa','span',jsonb_build_object('start',0,'end',5)),
 jsonb_build_object('id',gen_random_uuid(),'path','/service/conditions/0/details','kind','stated','input_id',:'access_input','input_hash',preparation.read_input(:'access_ws',:'access_input')->>'sha256','quote','Accesso su appuntamento','span',jsonb_build_object('start',strpos(:'access_text','Accesso')-1,'end',strpos(:'access_text','Accesso')-1+length('Accesso su appuntamento'))),
 jsonb_build_object('id',gen_random_uuid(),'path','/service/delivery_mode','kind','stated','input_id',:'access_input','input_hash',preparation.read_input(:'access_ws',:'access_input')->>'sha256','quote','online','span',jsonb_build_object('start',strpos(:'access_text','online')-1,'end',strpos(:'access_text','online')-1+length('online'))))) AS access_payload \gset
SELECT preparation.save_items(:'access_ws',jsonb_build_array(jsonb_build_object('item_id',:'access_item'::jsonb->>'item_id','expected_version',:'access_version'::jsonb->>'id','payload',:'access_payload'::jsonb)),gen_random_uuid());
SELECT preparation.preview_analysis_plan(:'access_ws',ARRAY[(:'access_item'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS access_plan \gset
RESET SESSION AUTHORIZATION;
SELECT request_body AS access_request FROM preparation.analysis_packets WHERE plan_id=(:'access_plan'::jsonb->>'plan_id')::uuid \gset
SELECT pg_temp.assert_true(EXISTS(SELECT FROM jsonb_array_elements(:'access_request'::jsonb#>'{data,supports}') s WHERE s->>'field_path'='/service/conditions/0/details' AND s->>'quote'='Accesso su appuntamento' AND s->>'origin'='source') AND EXISTS(SELECT FROM jsonb_array_elements(:'access_request'::jsonb#>'{data,supports}') s WHERE s->>'field_path'='/service/delivery_mode' AND s->>'quote'='online'),'owned stated public delivery and access quotations enrich context');
SELECT pg_temp.assert_true(jsonb_array_length(:'access_request'::jsonb#>'{data,bases}')=1 AND :'access_request'::jsonb#>>'{data,bases,0,kind}'='description','optional service context does not create extra classification obligations');
SELECT pg_temp.assert_true(position('PRIVATE NOTE' IN :'access_request')=0 AND position('PRIVATE UNSENT' IN :'access_request')=0 AND (:'access_request'::jsonb#>'{shared_context,limitations}') @> '["unsupported_field"]'::jsonb,'manual/private and unquoted normalized fields stay excluded with explicit input limitation');
ROLLBACK;
