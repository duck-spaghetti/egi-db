-- Revert egi_database:032_workbench_coverage
BEGIN;
DROP FUNCTION preparation.read_analysis_events(uuid,uuid,bigint,bigint,integer);
DROP FUNCTION preparation.read_analysis_record_results(uuid,uuid,bigint,uuid,integer,integer);
DROP FUNCTION preparation.retry_uncertain_analysis_packet(uuid,uuid,uuid);
DROP FUNCTION preparation.cancel_analysis_plan(uuid,uuid,bigint,uuid);
DROP FUNCTION preparation.amend_analysis_plan(uuid,uuid,bigint,uuid[],text,jsonb,uuid);

DROP FUNCTION preparation.purge_job_payloads(uuid);
ALTER FUNCTION preparation.purge_job_payloads_before_coverage(uuid) RENAME TO purge_job_payloads;
DROP FUNCTION preparation.read_workspace(uuid);
ALTER FUNCTION preparation.read_workspace_before_workbench(uuid) RENAME TO read_workspace;
CREATE OR REPLACE FUNCTION preparation.read_workspace(id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb:=preparation.read_workspace_initial(id); summaries jsonb;
BEGIN
 SELECT COALESCE(jsonb_agg(jsonb_build_object('job_id',j.id,'input_id',j.input_id,'config_version',j.config_version,
  'state',j.state,'created_at',j.created_at,'diagnostics',j.diagnostics) ORDER BY j.created_at,j.id),'[]') INTO summaries
  FROM preparation.jobs j WHERE j.workspace_id=read_workspace.id;
 RETURN jsonb_set(r,'{jobs}',summaries);
END $$;
GRANT EXECUTE ON FUNCTION preparation.read_workspace(uuid) TO egi_editorial;
DROP FUNCTION preparation.select_workbench_proposals(uuid,uuid,uuid,uuid,jsonb,uuid);
DROP FUNCTION preparation.select_workbench_hypotheses(uuid,uuid,uuid,uuid,jsonb,uuid);
DROP FUNCTION preparation.select_workbench_result(uuid,uuid,uuid,uuid,jsonb,uuid,boolean);

DROP TRIGGER zz_workbench_comparison ON preparation.jobs;
DROP FUNCTION preparation.auto_workbench_comparison();
DROP FUNCTION preparation.continue_analysis_plan(uuid,uuid,bigint,uuid);
DROP FUNCTION preparation.schedule_workbench_comparison(uuid,bigint);
DROP FUNCTION preparation.read_analysis_coverage(uuid,uuid,bigint,integer,integer);
DROP TRIGGER workbench_units ON preparation.jobs;
DROP FUNCTION preparation.persist_workbench_units();
DROP FUNCTION preparation.finish_job(uuid,uuid,text,jsonb,jsonb);
ALTER FUNCTION preparation.finish_job_text(uuid,uuid,text,jsonb,jsonb) RENAME TO finish_job;
CREATE OR REPLACE FUNCTION preparation.finish_job(job uuid,dispatch uuid,lease text,result jsonb,usage jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE j preparation.jobs; w preparation.workspaces; config preparation.ai_configurations; reserve preparation.budget_reservations;
 digest text:=preparation.digest(jsonb_build_object('result',result,'usage',usage)); k text; value jsonb;
 intokens bigint; outtokens bigint; cached bigint; actual bigint; generated_ids jsonb:='{}'; applicable boolean; eligible jsonb; final_state text;
BEGIN
 PERFORM preparation.require_worker();
 SELECT * INTO w FROM preparation.workspaces WHERE workspaces.id=(SELECT workspace_id FROM preparation.jobs WHERE jobs.id=job) FOR UPDATE;
 j:=preparation.leased_job(job,lease);
 IF j.dispatch_id IS NULL OR j.dispatch_id IS DISTINCT FROM dispatch THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='dispatch_invalid'; END IF;
 IF j.completion_digest IS NOT NULL THEN
  IF j.completion_digest<>digest THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='job_completion_conflict'; END IF;
  RETURN jsonb_build_object('state',j.state,'settled',true);
 END IF;
 PERFORM preparation.closed(usage,ARRAY['input_tokens','output_tokens','cached_input_tokens','reasoning_tokens','provider_request_id'],ARRAY['input_tokens','output_tokens','cached_input_tokens']);
 FOR k,value IN SELECT * FROM jsonb_each(usage) LOOP
  IF k='provider_request_id' THEN
   IF jsonb_typeof(value)<>'null' AND (jsonb_typeof(value)<>'string' OR length(value#>>'{}') NOT BETWEEN 1 AND 200) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_provider_request_id'; END IF;
   CONTINUE;
  END IF;
  IF jsonb_typeof(value)<>'number' OR value::text !~ '^[0-9]+$' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_provider_usage'; END IF;
 END LOOP;
 intokens:=(usage->>'input_tokens')::bigint; outtokens:=(usage->>'output_tokens')::bigint; cached:=(usage->>'cached_input_tokens')::bigint;
 SELECT * INTO config FROM preparation.ai_configurations WHERE version=j.config_version;
 IF intokens>config.max_input_tokens OR outtokens>config.max_output_tokens OR cached>intokens OR
  COALESCE((usage->>'reasoning_tokens')::bigint,0)>outtokens THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='provider_usage_exceeds_bound'; END IF;
 actual:=ceil(((intokens-cached)::numeric*config.input_rate_microusd_per_million+
  cached::numeric*config.cached_rate_microusd_per_million+outtokens::numeric*config.output_rate_microusd_per_million)/1000000)::bigint;
 SELECT * INTO reserve FROM preparation.budget_reservations WHERE job_id=job;
 PERFORM 1 FROM preparation.budget_periods WHERE period_start=reserve.period_start FOR UPDATE;
 IF reserve.job_id IS NULL OR actual>reserve.ceiling_microusd THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='provider_usage_exceeds_bound'; END IF;
 UPDATE preparation.budget_periods SET reserved_microusd=reserved_microusd-reserve.ceiling_microusd,committed_microusd=committed_microusd+actual WHERE period_start=reserve.period_start;
 UPDATE preparation.budget_reservations SET state='settled',settled_microusd=actual WHERE job_id=job;
 applicable:=j.cancelled_at IS NULL AND j.state NOT IN ('cancelled') AND preparation.requester_authorized(j.workspace_id,j.requester_actor_id)
  AND w.current_input_id IS NOT DISTINCT FROM j.input_id AND w.state='active';
 IF applicable THEN
  eligible:=preparation.eligible_input(j.workspace_id,j.input_id);
  applicable:=eligible-'locator_map' IS NOT DISTINCT FROM j.eligible_payload AND eligible->'locator_map' IS NOT DISTINCT FROM j.locator_map;
 END IF;
 -- Validate the reusable interpreter's result at the persistence boundary too.
 IF applicable THEN
  BEGIN
   PERFORM preparation.validate_job_result(j,result);
   final_state:=CASE WHEN result->>'state'='complete' THEN 'succeeded' ELSE 'failed' END;
  EXCEPTION WHEN data_exception OR check_violation THEN final_state:='failed'; result:=NULL;
  END;
 ELSE final_state:='cancelled'; result:=NULL; END IF;
 IF NOT applicable THEN final_state:='cancelled'; result:=NULL; END IF;
 IF final_state='succeeded' THEN
  SELECT COALESCE(jsonb_object_agg(c->>'candidate_key',to_jsonb(gen_random_uuid())),'{}') INTO generated_ids
   FROM jsonb_array_elements(result->'candidates') c;
 END IF;
 UPDATE preparation.jobs SET candidate_ids=generated_ids,state=final_state,output=CASE WHEN applicable THEN result ELSE NULL END,usage=finish_job.usage,
  completion_digest=digest,finished_at=clock_timestamp(),diagnostics=CASE WHEN NOT applicable THEN '[{"code":"access_or_input_changed"}]'::jsonb
   WHEN final_state='failed' THEN '[{"code":"invalid_or_incomplete_output"}]'::jsonb ELSE '[]'::jsonb END WHERE jobs.id=job;
 RETURN jsonb_build_object('state',final_state,'settled',true);
END $$;
GRANT EXECUTE ON FUNCTION preparation.finish_job(uuid,uuid,text,jsonb,jsonb) TO egi_preparation_worker;
DROP FUNCTION preparation.reconcile_workbench_result(preparation.analysis_packets,jsonb);
DROP FUNCTION preparation.validate_job_result(preparation.jobs,jsonb);
ALTER FUNCTION preparation.validate_job_result_text(preparation.jobs,jsonb) RENAME TO validate_job_result;
DROP FUNCTION preparation.validate_workbench_result(preparation.analysis_packets,jsonb);
DROP FUNCTION preparation.workbench_codes(jsonb);
DROP FUNCTION preparation.start_dispatch(uuid,text);
ALTER FUNCTION preparation.start_dispatch_text(uuid,text) RENAME TO start_dispatch;
GRANT EXECUTE ON FUNCTION preparation.start_dispatch(uuid,text) TO egi_preparation_worker;
DROP FUNCTION preparation.claim_job(uuid);
ALTER FUNCTION preparation.claim_job_text(uuid) RENAME TO claim_job;
GRANT EXECUTE ON FUNCTION preparation.claim_job(uuid) TO egi_preparation_worker;
DROP FUNCTION preparation.start_analysis_plan(uuid,uuid,bigint,uuid);
DROP FUNCTION preparation.enqueue_workbench_packet(uuid);
DROP FUNCTION preparation.workbench_packet_current(uuid);
DROP TABLE preparation.workbench_unit_results;
ALTER TABLE preparation.jobs DROP CONSTRAINT jobs_task_check, ADD CONSTRAINT jobs_task_check CHECK(task IN ('extract_text','map_csv'));
CREATE OR REPLACE FUNCTION preparation.read_analysis_plan(wid uuid,pid uuid,pversion bigint,packet_offset integer DEFAULT 0,page_size integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p preparation.analysis_plans; result jsonb;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size NOT BETWEEN 1 AND 100 OR packet_offset NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_plan_page'; END IF;
 SELECT * INTO p FROM preparation.analysis_plans WHERE workspace_id=wid AND plan_id=pid AND version=pversion;
 IF p.plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='plan_not_found'; END IF;
 SELECT COALESCE(jsonb_agg(x.manifest ORDER BY x.packet_id),'[]') INTO result FROM
  (SELECT packet_id,manifest FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion ORDER BY packet_id LIMIT page_size OFFSET packet_offset) x;
 RETURN (to_jsonb(p)-'eligible_snapshot'-'comparison_seed')||jsonb_build_object('shared_context',(SELECT body FROM preparation.shared_contexts WHERE context_id=p.context_id),
  'selection_manifest_digest',p.selection_digest,
  'initial_packet_ids',(SELECT COALESCE(jsonb_agg(packet_id ORDER BY packet_id),'[]') FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND stage='initial'),
  'packets',result,'total_packets',(SELECT count(*) FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion),
  'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object('kind',kind,'body',body) ORDER BY event_id),'[]') FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion));
END $$;
COMMIT;
