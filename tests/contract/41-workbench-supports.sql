-- Exact member-record context support, source-proof retention and attribution.
\set keep_proposal_transaction 1
\ir 38-workbench-proposals.sql
\unset keep_proposal_transaction
SELECT (:'independent_cards'::uuid[])[1] AS support_item \gset
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS raw_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'support_item','expected_version',:'raw_version'::jsonb->>'id','payload',
 (:'raw_version'::jsonb->'payload')||jsonb_build_object('service',(:'raw_version'::jsonb#>'{payload,service}')||jsonb_build_object('name','Mensa','delivery_mode','telephone','territories',jsonb_build_array(:'context'::jsonb#>'{context,territory_id}')),
 'field_origins',jsonb_build_object('/source_facts/0/source_value',jsonb_build_object('state','manual'),'/source_facts/0/value',jsonb_build_object('state','manual'))))),gen_random_uuid());
SELECT preparation.create_items(:'ws',:'inp',NULL,jsonb_build_array(jsonb_build_object('creation_key',gen_random_uuid())),gen_random_uuid())->'items'->0 AS outside \gset
SELECT preparation.read_item(:'ws',(:'outside'::jsonb->>'item_id')::uuid,NULL)->'version' AS outside_version \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'outside'::jsonb->>'item_id','expected_version',:'outside_version'::jsonb->>'id','payload',
 (:'outside_version'::jsonb->'payload')||jsonb_build_object('schema_version',2,'service',jsonb_build_object('description','Associazione Alfa'),
 'source_facts',jsonb_build_array(jsonb_build_object('fact_id',gen_random_uuid(),'kind','category_label','subject','service','source_value','Associazione Alfa','value','Associazione Alfa')),'resolutions','[]'::jsonb,
 'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value','kind','stated','input_id',:'inp','input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','quote','Associazione Alfa','span',jsonb_build_object('start',0,'end',17)),
 jsonb_build_object('id',gen_random_uuid(),'path','/service/description','kind','stated','input_id',:'inp','input_hash',preparation.read_input(:'ws',:'inp')->>'sha256','quote','Associazione Alfa','span',jsonb_build_object('start',0,'end',17)))))),gen_random_uuid());
SELECT preparation.preview_analysis_plan(:'ws',:'independent_cards'::uuid[]||ARRAY[(:'outside'::jsonb->>'item_id')::uuid],NULL,:'limits',gen_random_uuid()) AS support_plan \gset
SELECT preparation.start_analysis_plan(:'ws',(:'support_plan'::jsonb->>'plan_id')::uuid,1,gen_random_uuid())->>'plan_id';
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS support_claim \gset
SELECT preparation.start_dispatch((:'support_claim'::jsonb->>'job_id')::uuid,:'support_claim'::jsonb->>'lease') AS support_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT jsonb_agg(s->'support_key') AS choice_support FROM jsonb_array_elements(:'support_claim'::jsonb#>'{eligible_payload,data,supports}') s WHERE s->>'record_key'=:'support_item' AND s->>'field_path' IN ('/service/description','/source_facts/0/source_value','/source_metadata/name') \gset
SELECT pg_temp.workbench_result(:'support_claim'::jsonb->'eligible_payload') AS support_result \gset
SELECT jsonb_set(:'support_result','{proposals}',(SELECT jsonb_agg(CASE WHEN EXISTS(SELECT FROM jsonb_array_elements(:'support_claim'::jsonb#>'{eligible_payload,data,bases}') b WHERE b->'basis_key'=p->'basis_key' AND b->>'record_key'=:'support_item') THEN p||jsonb_build_object('state','proposed','choices',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','reason','Original label and description with explicit weaker source context','support_keys',:'choice_support'::jsonb))) ELSE p END) FROM jsonb_array_elements(:'support_result'::jsonb->'proposals') p)) AS support_result \gset
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'support_claim'::jsonb->>'job_id')::uuid,(:'support_dispatch'::jsonb->>'dispatch_id')::uuid,:'support_claim'::jsonb->>'lease',:'support_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
SELECT preparation.claim_job(gen_random_uuid()) AS support_group_claim \gset
SELECT preparation.start_dispatch((:'support_group_claim'::jsonb->>'job_id')::uuid,:'support_group_claim'::jsonb->>'lease') AS support_group_dispatch \gset
RESET SESSION AUTHORIZATION;
SELECT l AS selected_label FROM jsonb_array_elements(:'support_group_claim'::jsonb#>'{eligible_payload,data,labels}') l WHERE l->>'label'='Mensa' \gset
SELECT s->'support_key' AS outside_support FROM jsonb_array_elements(:'support_group_claim'::jsonb#>'{eligible_payload,data,supports}') s WHERE s->>'record_key'=:'outside'::jsonb->>'item_id' AND s->>'field_path'='/service/description' \gset
SELECT jsonb_build_object('schema_version',1,'task','group_labels','request_digest',preparation.workbench_digest(:'support_group_claim'::jsonb->'eligible_payload'),'state','complete',
 'unit_results',jsonb_build_array(jsonb_build_object('unit_key',:'support_group_claim'::jsonb#>'{eligible_payload,data,units,0,unit_key}','record_key',NULL,'state','analyzed','processed_basis_keys','[]'::jsonb,'unprocessed_basis_keys','[]'::jsonb,'proposal_keys','["member-context"]'::jsonb,'hypotheses','[]'::jsonb,'diagnostics','[]'::jsonb)),
 'unprocessed_unit_keys','[]'::jsonb,'diagnostics','[]'::jsonb,'proposals',jsonb_build_array(jsonb_build_object('proposal_key','member-context','relation','equivalent','unit_keys',jsonb_build_array(:'selected_label'::jsonb->'unit_key'),'membership_issues','[]'::jsonb,'choices',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','reason','Compared members own descriptions and public source metadata','support_keys',:'choice_support'::jsonb)),'reason','Repeated source label disambiguated with owned member context','support_keys',:'choice_support'::jsonb))) AS support_group_result \gset
SELECT q AS support_packet FROM preparation.analysis_packets q WHERE q.packet_id=(:'support_group_claim'::jsonb#>>'{eligible_payload,packet_key}')::uuid \gset
SELECT preparation.reconcile_workbench_result(:'support_packet'::preparation.analysis_packets,jsonb_set(:'support_group_result','{proposals,0,choices,0,support_keys}',jsonb_build_array(:'outside_support'::jsonb))) AS outside_result \gset
SELECT pg_temp.assert_true(:'outside_result'::jsonb->'proposals'='[]'::jsonb,'unrelated same-packet record cannot support compared member interpretation');
SET SESSION AUTHORIZATION egi_probe36_worker;
SELECT preparation.finish_job((:'support_group_claim'::jsonb->>'job_id')::uuid,(:'support_group_dispatch'::jsonb->>'dispatch_id')::uuid,:'support_group_claim'::jsonb->>'lease',:'support_group_result','{"input_tokens":100,"output_tokens":20,"cached_input_tokens":0}');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_workbench_proposals(:'ws',(:'support_group_claim'::jsonb->>'job_id')::uuid,NULL,0,1) AS proposal_page \gset
SELECT pg_temp.assert_true(:'proposal_page'::jsonb->>'total_proposals'='1' AND :'proposal_page'::jsonb#>>'{catalog_choices,0,label}'='Mensa' AND jsonb_array_length(:'proposal_page'::jsonb->'records')=3,'group proposal page includes human vocabulary and only member records');
SELECT preparation.read_workbench_proposal_members(:'ws',(:'support_group_claim'::jsonb->>'job_id')::uuid,'member-context',0,100) AS member_page \gset
SELECT pg_temp.assert_true(:'member_page'::jsonb->>'total_members'='3' AND :'member_page'::jsonb->>'unresolved_occurrences'='0','member reader resolves exact source-fact identities');
SELECT preparation.read_workbench_supports(:'ws',(:'support_group_claim'::jsonb->>'job_id')::uuid,NULL,'member-context',0,1) AS support_page \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'support_page'::jsonb->'supports')=1 AND :'support_page'::jsonb->>'next_offset'='1','context supports have explicit bounded pages');
SELECT gen_random_uuid() AS linked_gid,gen_random_uuid() AS linked_version \gset
SELECT jsonb_build_object('group_id',:'linked_gid','version',:'linked_version','parent_versions','[]'::jsonb,'preparation_id',:'ws','context',(:'context'::jsonb->'context')||jsonb_build_object('catalog_digest',:'support_group_claim'::jsonb#>>'{eligible_payload,catalog_context,digest}','as_of',current_date),'members',:'member_page'::jsonb->'members','mapping',:'context'::jsonb#>'{entries,0,target}','state','proposed','method','ai','proposal_id',(:'support_group_claim'::jsonb#>>'{eligible_payload,packet_key}')||':member-context') AS linked_group \gset
SELECT preparation.save_group(:'ws',NULL,:'linked_group',gen_random_uuid())->'group'->>'version';
SELECT preparation.read_item(:'ws',(:'outside'::jsonb->>'item_id')::uuid,NULL)->'version' AS outsider \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_group(%L,NULL,%L,gen_random_uuid())',:'ws',(:'linked_group'::jsonb)||jsonb_build_object('group_id',gen_random_uuid(),'version',gen_random_uuid(),'members',(:'member_page'::jsonb->'members')||jsonb_build_array(jsonb_build_object('item_id',:'outside'::jsonb->>'item_id','expected_version',:'outsider'::jsonb->>'id','basis_kind','source_fact','basis_id',:'outsider'::jsonb#>'{payload,source_facts,0,fact_id}')))),'22023','group_member_not_in_proposal');
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS before_select \gset
SELECT jsonb_agg(p->'proposal_key') AS selected_keys FROM jsonb_array_elements(:'support_result'::jsonb->'proposals') p WHERE p->>'state'='proposed' \gset
SELECT preparation.select_workbench_proposals(:'ws',(:'support_claim'::jsonb->>'job_id')::uuid,:'support_item',(:'before_select'::jsonb->>'id')::uuid,:'selected_keys',gen_random_uuid());
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS interpreted \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'interpreted'::jsonb#>'{payload,interpreted_classifications}')=2 AND NOT EXISTS(SELECT FROM jsonb_array_elements(:'interpreted'::jsonb#>'{payload,interpreted_classifications}') r WHERE r->>'state'<>'proposed' OR jsonb_array_length(r#>'{candidates,0,support_evidence_ids}')<>2),'initial manual raw origin stays eligible and actual description/label quote IDs both persist');
SELECT r AS description_interpretation FROM jsonb_array_elements(:'interpreted'::jsonb#>'{payload,interpreted_classifications}') r WHERE r#>>'{basis,field_path}'='/service/description' \gset
SELECT :'linked_gid' AS manual_gid,gen_random_uuid() AS manual_version \gset
SELECT (:'linked_group'::jsonb)||jsonb_build_object('group_id',:'manual_gid','version',:'manual_version','parent_versions',jsonb_build_array(:'linked_version'),'state','accepted','method','manual','proposal_id',NULL,'members',jsonb_build_array(jsonb_build_object('item_id',:'support_item','expected_version',:'interpreted'::jsonb->>'id','basis_kind','interpreted_classification','basis_id',:'description_interpretation'::jsonb->'interpretation_id'))) AS manual_group \gset
SELECT preparation.save_group(:'ws',:'linked_version',:'manual_group',gen_random_uuid())->'group'->>'version';
SELECT jsonb_build_object('group_id',:'manual_gid','expected_group_version',:'manual_version','selection',:'manual_group'::jsonb->'members','request_key',gen_random_uuid()) AS actual_apply \gset
SELECT preparation.apply_group(:'ws',:'actual_apply') AS applied \gset
SELECT pg_temp.assert_true(:'applied'::jsonb#>>'{items,0,status}'='applied' AND :'applied'::jsonb->'resume_request'=:'actual_apply'::jsonb,'AI-created interpretation can be confirmed by explicit group and resumed with exact original body');
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS reviewed_before_reselect \gset
SELECT preparation.select_workbench_proposals(:'ws',(:'support_claim'::jsonb->>'job_id')::uuid,:'support_item',(:'reviewed_before_reselect'::jsonb->>'id')::uuid,:'selected_keys',gen_random_uuid()) AS reselection \gset
SELECT pg_temp.assert_true(:'reselection'::jsonb->'items'='[]'::jsonb AND jsonb_array_length(:'reselection'::jsonb->'already_materialized')=2 AND preparation.read_item(:'ws',:'support_item',NULL)->'version'=:'reviewed_before_reselect'::jsonb,'same output with a new key neither duplicates nor resets confirmed review');
SELECT preparation.read_workbench_proposals(:'ws',(:'support_claim'::jsonb->>'job_id')::uuid,:'support_item',0,100) AS reviewed_proposals \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'reviewed_proposals'::jsonb->'materializations')=2 AND EXISTS(SELECT FROM jsonb_array_elements(:'reviewed_proposals'::jsonb->'materializations') identity WHERE identity->>'state'='confirmed'),'proposal reader exposes existing human decisions through stable server identities');
SELECT preparation.undo_group(:'ws',(:'applied'::jsonb->>'operation_id')::uuid,gen_random_uuid()) AS undone \gset
SELECT pg_temp.assert_true(:'undone'::jsonb#>>'{items,0,status}'='applied' AND :'undone'::jsonb->>'kind'='undo','AI creation provenance survives compensating undo');
SELECT preparation.list_group_operations(:'ws',0,1) AS operation_page \gset
SELECT pg_temp.assert_true(:'operation_page'::jsonb->>'total_operations'='2' AND :'operation_page'::jsonb->>'next_offset'='1','current actor can reload durable operation identities');
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS reject_before \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'support_item','expected_version',:'reject_before'::jsonb->>'id','payload',jsonb_set(:'reject_before'::jsonb->'payload','{interpreted_classifications}',(SELECT jsonb_agg(CASE WHEN r#>>'{basis,field_path}'='/source_facts/0/source_value' THEN r||'{"state":"rejected","selected":null}'::jsonb ELSE r END) FROM jsonb_array_elements(:'reject_before'::jsonb#>'{payload,interpreted_classifications}') r)))),gen_random_uuid());
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS rejected_review \gset
SELECT preparation.select_workbench_proposals(:'ws',(:'support_claim'::jsonb->>'job_id')::uuid,:'support_item',(:'rejected_review'::jsonb->>'id')::uuid,:'selected_keys',gen_random_uuid());
SELECT pg_temp.assert_true(preparation.read_item(:'ws',:'support_item',NULL)->'version'=:'rejected_review'::jsonb,'new-key reselection preserves an explicitly rejected interpretation');
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS after_undo \gset
SELECT preparation.apply_group(:'ws',jsonb_set(jsonb_set(:'actual_apply','{selection,0,expected_version}',:'after_undo'::jsonb->'id'),'{request_key}',to_jsonb(gen_random_uuid()))) AS reapplied \gset
SELECT preparation.read_item(:'ws',:'support_item',NULL)->'version' AS final_private \gset
SELECT preparation.save_items(:'ws',jsonb_build_array(jsonb_build_object('item_id',:'support_item','expected_version',:'final_private'::jsonb->>'id','payload',jsonb_set(:'final_private'::jsonb->'payload','{outcome}','"confirmed"'))),gen_random_uuid())->'items'->0->>'after' AS ready_version \gset
SELECT preparation.submit_item(:'ws',:'support_item',:'ready_version',gen_random_uuid())->>'contribution_id' AS selected_contribution \gset
SELECT editorial.read_community_snapshot(:'selected_contribution') AS retained_snapshot \gset
SELECT pg_temp.assert_true(jsonb_array_length(:'retained_snapshot'::jsonb#>'{snapshot,values,interpretation_support,0,evidence}')=2 AND EXISTS(SELECT FROM jsonb_array_elements(:'retained_snapshot'::jsonb#>'{snapshot,values,interpretation_support,0,context_support}') s WHERE s->>'origin'='source_metadata' AND s->>'field_path'='/source_metadata/name') AND position('PRIVATE UNSENT' IN :'retained_snapshot')=0,'selective snapshot retains actual source quotes plus referenced weak metadata only');
SELECT preparation.preview_analysis_plan(:'ws',ARRAY[:'support_item'::uuid],NULL,:'limits',gen_random_uuid()) AS expanded_prior_plan \gset
SELECT pg_temp.assert_true(:'expanded_prior_plan'::jsonb#>>'{configuration,max_selected_records}'='100' AND :'expanded_prior_plan'::jsonb#>>'{catalog_coverage,supplied_terms}'='1','preview exposes explicit selection and vocabulary coverage limits');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM preparation.analysis_plans plan,jsonb_array_elements(plan.comparison_seed->'prior_proposals') prior,jsonb_array_elements(prior->'choices') choice WHERE plan.plan_id=(:'expanded_prior_plan'::jsonb->>'plan_id')::uuid AND jsonb_array_length(choice->'support_keys')>=3 AND EXISTS(SELECT FROM jsonb_array_elements(plan.comparison_seed->'supports') support WHERE support->>'origin'='source_metadata' AND (choice->'support_keys') @> jsonb_build_array(support->'support_key'))),'new interpreted comparison retains original additional quotes and weaker metadata as prior alternatives');
SET SESSION AUTHORIZATION egi_probe30;
SELECT jsonb_build_object('schema_version',2,'expected_service_work',NULL,'expected_service_public',NULL,'service_operations',jsonb_build_array(
 jsonb_build_object('op','add','path','/name','value','Mensa','evidence_ids','[]'::jsonb),jsonb_build_object('op','add','path','/description','value','Mensa','evidence_ids','[]'::jsonb),jsonb_build_object('op','add','path','/delivery_mode','value','telephone','evidence_ids','[]'::jsonb),
 jsonb_build_object('op','add','path','/territories','value',jsonb_build_array(:'context'::jsonb#>'{context,territory_id}'),'evidence_ids','[]'::jsonb),jsonb_build_object('op','add','path','/classifications','value',jsonb_build_array(jsonb_build_object('adoption_id',:'context'::jsonb#>'{entries,0,target,adoption_id}','term_id',:'context'::jsonb#>'{entries,0,target,term_id}')),'evidence_ids','[]'::jsonb)),
 'location',jsonb_build_object('kind','none'),'reason','Explicit human interpretation after reviewing original description and weaker source context','observations',jsonb_build_array(jsonb_build_object('paths',jsonb_build_array('/service'),'method','other','note','Human category decision; description is quoted, category is interpreted')),'fact_actions','[]'::jsonb) AS explicit_decision \gset
SELECT editorial.accept_community_item(:'selected_contribution',:'explicit_decision',gen_random_uuid());
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT COALESCE(bool_and(a.method='editorial_other'),false) FROM editorial.community_evidence e JOIN sources.assertions a USING(assertion_id) WHERE e.contribution_id=:'selected_contribution' AND e.field_path LIKE '/service/classifications/%'),'canonical category uses attributed human observation, never borrowed literal description assertion');
UPDATE preparation.workspaces SET state='trash',trashed_at=clock_timestamp()-interval '31 days' WHERE id=:'ws';
SET SESSION AUTHORIZATION egi_probe35_retention;
SELECT preparation.purge_trash();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe30;
SELECT pg_temp.assert_true(editorial.read_community_snapshot(:'selected_contribution')->'snapshot'=:'retained_snapshot'::jsonb->'snapshot','selected interpreted provenance survives private job and card purge');
RESET SESSION AUTHORIZATION;
ROLLBACK;
