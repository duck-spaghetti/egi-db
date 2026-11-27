-- Reuse the actual published category/adoption and private sessions from contract30.
-- A session-only timezone shift crosses the fixture's end date without changing
-- an immutable adoption or the machine clock. UTC-12 to UTC+14 always crosses a day.
SET TIME ZONE 'Etc/GMT+12';
SET egi.reference_expiry='on';
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
SELECT jsonb_build_object('schema_version',1,'kind','classification','as_of',current_date::text,'complete',true,
 'context',jsonb_build_object('territory_id',a.territory_id,'axis_id',rt.axis_id),
 'entries',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','label',c.original_text,'published',true,'active',true,
 'effective_from',a.effective_from::text,'effective_until',a.effective_until,'broader','[]'::jsonb,
 'target',jsonb_build_object('kind','classification','adoption_id',a.adoption_id,'release_id',a.release_id,'term_id',rt.term_id,'axis_id',rt.axis_id)))) AS context
 FROM taxonomy.territory_adoptions a JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.axes ax ON ax.axis_id=rt.axis_id
 JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name' JOIN i18n.content_units c USING(content_id)
 WHERE a.effective_from<=current_date AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND ax.code='service_type' \gset
SELECT :'context'::jsonb||jsonb_build_object('digest',encode(sha256(convert_to(preparation.canonical_json(:'context'::jsonb),'UTF8')),'hex')) AS context \gset
SELECT preparation.validate_matching_context(:'context');
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('matching-fixture-1',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'context'::jsonb),100,100,1000000,0,1000000,clock_timestamp(),'synthetic, no provider');
INSERT INTO preparation.ai_settings(config_version,enabled) VALUES('matching-fixture-1',true);
CREATE ROLE egi_probe32_worker LOGIN IN ROLE egi_preparation_worker;
SET SESSION AUTHORIZATION egi_probe30;
SELECT access.verify_session(encode(sha256(convert_to('session30','UTF8')),'hex'));
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS job \gset
SET SESSION AUTHORIZATION egi_probe32_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS claim \gset
SELECT :'claim'::jsonb->>'lease' AS lease \gset
SELECT preparation.start_dispatch(:'job',:'lease')->>'dispatch_id' AS dispatch \gset
SELECT jsonb_build_object('schema_version',2,'input_id',:'inp','input_hash',:'claim'::jsonb#>>'{eligible_payload,input_hash}',
 'config_version','matching-fixture-1','state','complete','mapping',NULL,'diagnostics','[]'::jsonb,
 'candidates',jsonb_build_array(jsonb_build_object('candidate_key','mensa','service','{}'::jsonb,'location',jsonb_build_object('kind','none'),'diagnostics','[]'::jsonb,
 'source_facts',jsonb_build_array(jsonb_build_object('fact_key','raw-category','subject','service','kind','category_label','source_value','Mensa')),
 'evidence',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'path','/source_facts/0/source_value','kind','stated','input_id',:'inp',
 'input_hash',:'claim'::jsonb#>>'{eligible_payload,input_hash}','quote','Mensa','span',jsonb_build_object('start',18,'end',23))),
 'matches',jsonb_build_array(jsonb_build_object('fact_key','raw-category','context_digest',:'context'::jsonb->>'digest','choices',jsonb_build_array(jsonb_build_object('candidate_key','catalog-1','reason','Same explicit service-type label'))))))) AS output \gset
SELECT pg_temp.assert_true(preparation.finish_job(:'job',:'dispatch',:'lease',:'output','{"input_tokens":10,"output_tokens":10,"cached_input_tokens":0}')->>'state'='succeeded','same-exchange matches succeed with known usage');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.expect_error(format('SELECT preparation.validate_job_result((SELECT j FROM preparation.jobs j WHERE id=%L),%L)',:'job',jsonb_set(:'output'::jsonb,'{candidates,0,matches,0,choices,0,candidate_key}','"invented-id"')),'22023','invalid_category_matches');
SELECT pg_temp.expect_error(format('SELECT preparation.validate_job_result((SELECT j FROM preparation.jobs j WHERE id=%L),%L)',:'job',jsonb_set(:'output'::jsonb,'{candidates,0,matches,0,fact_key}','"foreign-card"')),'22023','invalid_category_matches');
SELECT pg_temp.expect_error(format('SELECT preparation.validate_job_result((SELECT j FROM preparation.jobs j WHERE id=%L),%L)',:'job',jsonb_set(:'output'::jsonb,'{candidates,0,matches,0,choices,0,role}','"provider"')),'22023');
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.read_job(:'ws',:'job')->'candidate_ids'->>'mensa' AS cid \gset
SELECT preparation.create_items(:'ws',:'inp',:'job',jsonb_build_array(jsonb_build_object('candidate_id',:'cid')),gen_random_uuid())->'items'->0 AS matched_item \gset
SELECT preparation.read_item(:'ws',(:'matched_item'::jsonb->>'item_id')::uuid,NULL)#>'{version,payload}' AS matched_payload \gset
SELECT pg_temp.assert_true(:'matched_payload'::jsonb#>>'{resolutions,0,state}'='proposed' AND :'matched_payload'::jsonb#>'{resolutions,0,selected}' IS NULL,'match materializes as unconfirmed only');
SELECT pg_temp.assert_true(:'matched_payload'::jsonb#>>'{resolutions,0,fact_id}'=:'matched_payload'::jsonb#>>'{source_facts,0,fact_id}','local key bound to stable server fact ID');
SELECT pg_temp.assert_true(NOT (:'matched_payload'::jsonb->'service') ? 'classifications','suggestion never populates canonical relationship');
SELECT jsonb_set(jsonb_set(:'matched_payload'::jsonb,'{source_facts,0,value}','"Manual label"'),'{field_origins}',(:'matched_payload'::jsonb->'field_origins')||'{"/source_facts/0/value":{"state":"manual"}}') AS manual_payload \gset
SELECT pg_temp.expect_error(format('SELECT preparation.save_items(%L,%L,gen_random_uuid())',:'ws',jsonb_build_array(jsonb_build_object('item_id',:'matched_item'::jsonb->>'item_id','expected_version',:'matched_item'::jsonb->>'version_id','payload',:'manual_payload'::jsonb))),'22023','source_fact_resolution_stale');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT committed_microusd=20 AND reserved_microusd=0 FROM preparation.budget_periods),'one known exchange settled once');
SELECT jsonb_set(:'manual_payload'::jsonb,'{resolutions}',jsonb_build_array(jsonb_build_object('fact_id',:'matched_payload'::jsonb#>'{source_facts,0,fact_id}','state','ignored','context','{}'::jsonb,'candidates','[]'::jsonb))) AS manual_payload \gset
SELECT preparation.merge_candidate(:'manual_payload',:'output'::jsonb#>'{candidates,0}',:'inp',:'job')->'payload' AS refreshed_payload \gset
SELECT pg_temp.assert_true(:'refreshed_payload'::jsonb#>>'{source_facts,0,value}'='Manual label' AND :'refreshed_payload'::jsonb#>>'{resolutions,0,state}'='ignored','refresh preserves manual value and rejected matching decision');
-- Changing coverage changes the frozen digest/config version and cache identity.
SELECT jsonb_set(:'context'::jsonb,'{complete}','false')-'digest' AS changed_context \gset
SELECT :'changed_context'::jsonb||jsonb_build_object('digest',encode(sha256(convert_to(preparation.canonical_json(:'changed_context'::jsonb),'UTF8')),'hex')) AS changed_context \gset
INSERT INTO preparation.ai_configurations(version,provider_config,max_input_tokens,max_output_tokens,input_rate_microusd_per_million,cached_rate_microusd_per_million,output_rate_microusd_per_million,verified_at,price_reference)
 VALUES('matching-fixture-2',jsonb_build_object('fixture_only',true,'interpretation_version',2,'catalog_context',:'changed_context'::jsonb),100,100,1000000,0,1000000,clock_timestamp(),'synthetic, no provider');
UPDATE preparation.ai_settings SET config_version='matching-fixture-2';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS second_job \gset
SELECT pg_temp.assert_true(:'job'<>:'second_job','different immutable context/config cannot reuse old match cache');
SET SESSION AUTHORIZATION egi_probe32_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS second_claim \gset
SELECT :'second_claim'::jsonb->>'lease' AS second_lease \gset
SELECT preparation.start_dispatch(:'second_job',:'second_lease')->>'dispatch_id' AS second_dispatch \gset
SELECT jsonb_set(jsonb_set(jsonb_set(:'output'::jsonb,'{config_version}','"matching-fixture-2"'),'{candidates,0,matches,0,context_digest}',:'changed_context'::jsonb->'digest'),'{candidates,0,matches,0,choices,0,candidate_key}','"invented-id"') AS invalid_output \gset
SELECT pg_temp.assert_true(preparation.finish_job(:'second_job',:'second_dispatch',:'second_lease',:'invalid_output','{"input_tokens":10,"output_tokens":10,"cached_input_tokens":0}')->>'state'='failed','invalid match fails while known usage settles');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT committed_microusd=40 AND reserved_microusd=0 FROM preparation.budget_periods),'invalid semantic result still accounts for known usage');
-- Expiring a once-valid adoption prevents another dispatch and reservation.
SET TIME ZONE 'Etc/GMT-14';
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.request_interpretation(:'ws',:'inp','extract_text',gen_random_uuid())->>'job_id' AS stale_job \gset
SET SESSION AUTHORIZATION egi_probe32_worker;
SELECT preparation.claim_job(gen_random_uuid()) AS stale_claim \gset
SELECT pg_temp.assert_true(preparation.start_dispatch(:'stale_job',:'stale_claim'::jsonb->>'lease')->>'code'='catalog_context_changed','stale context fails before provider dispatch');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true((SELECT committed_microusd=40 AND reserved_microusd=0 FROM preparation.budget_periods),'stale context spends and reserves nothing');
\if :{?keep_matching_config}
COMMIT;
\else
ROLLBACK;
\endif
