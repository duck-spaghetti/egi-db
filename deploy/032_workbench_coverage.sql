-- Deploy egi_database:032_workbench_coverage
-- requires: 031_workbench_plans
BEGIN;
ALTER TABLE preparation.jobs DROP CONSTRAINT jobs_task_check,
 ADD CONSTRAINT jobs_task_check CHECK(task IN ('extract_text','map_csv','classify_cards','group_labels'));
CREATE TABLE preparation.workbench_unit_results (
 packet_id uuid NOT NULL REFERENCES preparation.analysis_packets,
 unit_key text NOT NULL, job_id uuid NOT NULL REFERENCES preparation.jobs,
 record_key text, state text NOT NULL, processed_basis_keys jsonb NOT NULL,
 unprocessed_basis_keys jsonb NOT NULL, result jsonb NOT NULL,
 PRIMARY KEY(packet_id,unit_key)
);
CREATE TRIGGER immutable_unit_result BEFORE UPDATE OR DELETE ON preparation.workbench_unit_results FOR EACH ROW EXECUTE FUNCTION preparation.workbench_immutable();
REVOKE ALL ON preparation.workbench_unit_results FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;

CREATE FUNCTION preparation.workbench_packet_current(packet uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE p preparation.analysis_plans; a preparation.analysis_packets; x jsonb; w preparation.workspaces;
BEGIN
 SELECT * INTO a FROM preparation.analysis_packets WHERE packet_id=packet;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=a.plan_id AND version=a.plan_version;
 SELECT * INTO w FROM preparation.workspaces WHERE id=p.workspace_id;
 IF p.plan_id IS NULL OR NOT preparation.requester_authorized(p.workspace_id,p.actor_id) OR w.current_input_id IS DISTINCT FROM p.input_id THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT FROM preparation.ai_settings WHERE singleton AND enabled AND config_version=p.configuration_version) THEN RETURN false; END IF;
 PERFORM preparation.validate_matching_context((SELECT provider_config->'catalog_context' FROM preparation.ai_configurations WHERE version=p.configuration_version));
 IF preparation.eligible_input(p.workspace_id,p.input_id) IS DISTINCT FROM p.eligible_snapshot THEN RETURN false; END IF;
 FOR x IN SELECT * FROM jsonb_array_elements(a.data->'records') LOOP
  IF NOT EXISTS(SELECT FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id
   WHERE i.id=(x->>'record_key')::uuid AND i.workspace_id=p.workspace_id AND i.trashed_at IS NULL AND v.id=(x->>'item_version')::uuid AND v.input_id=p.input_id) THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
EXCEPTION WHEN data_exception OR insufficient_privilege THEN RETURN false;
END $$;

CREATE FUNCTION preparation.enqueue_workbench_packet(packet uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE a preparation.analysis_packets; p preparation.analysis_plans; job uuid; count_packets integer;
BEGIN
 SELECT * INTO STRICT a FROM preparation.analysis_packets WHERE packet_id=packet;
 SELECT * INTO STRICT p FROM preparation.analysis_plans WHERE plan_id=a.plan_id AND version=a.plan_version FOR UPDATE;
 SELECT job_id INTO job FROM preparation.packet_jobs WHERE packet_id=packet;
 IF job IS NOT NULL THEN RETURN job; END IF;
 SELECT count(*) INTO count_packets FROM preparation.packet_jobs q JOIN preparation.analysis_packets x USING(packet_id) WHERE x.plan_id=p.plan_id AND x.plan_version=p.version;
 IF count_packets>=(p.followup_limits->>'max_total_packets')::integer OR NOT preparation.workbench_packet_current(packet) THEN
  INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(p.plan_id,p.version,'blocked',jsonb_build_object('packet_id',packet,'code','packet_ineligible_or_limit'));
  RETURN NULL;
 END IF;
 INSERT INTO preparation.jobs(workspace_id,input_id,requester_actor_id,task,config_version,request_key,eligible_payload,locator_map,eligibility_policy_version)
 VALUES(p.workspace_id,p.input_id,p.actor_id,a.task,p.configuration_version,packet,p.eligible_snapshot-'locator_map',p.eligible_snapshot->'locator_map',p.eligible_snapshot->>'policy_version') RETURNING id INTO job;
 INSERT INTO preparation.packet_jobs VALUES(packet,job);
 INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(p.plan_id,p.version,'packet_queued',jsonb_build_object('packet_id',packet,'job_id',job));
 RETURN job;
END $$;

CREATE FUNCTION preparation.start_analysis_plan(wid uuid,pid uuid,pversion bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); p preparation.analysis_plans; a preparation.analysis_packets; result jsonb; body jsonb:=jsonb_build_object('plan_id',pid,'version',pversion);
BEGIN
 result:=preparation.replay(wid,'start_analysis_plan',body,key); IF result IS NOT NULL THEN RETURN result; END IF;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid FOR UPDATE;
 IF p.plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND kind='started') THEN
  INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(pid,pversion,'started',jsonb_build_object('actor_id',preparation.actor(),'request_key',key));
 END IF;
 FOR a IN SELECT * FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND stage='initial' LOOP PERFORM preparation.enqueue_workbench_packet(a.packet_id); END LOOP;
 RETURN preparation.receipt(wid,'start_analysis_plan',body,key,preparation.read_analysis_plan(wid,pid,pversion));
END $$;

ALTER FUNCTION preparation.claim_job(uuid) RENAME TO claim_job_text;
CREATE FUNCTION preparation.claim_job(worker uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE result jsonb; a preparation.analysis_packets;
BEGIN
 LOOP
  result:=preparation.claim_job_text(worker); IF result IS NULL OR result->>'task' NOT IN ('classify_cards','group_labels') THEN RETURN result; END IF;
  SELECT x.* INTO a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=(result->>'job_id')::uuid;
  IF NOT preparation.workbench_packet_current(a.packet_id) THEN
   UPDATE preparation.jobs SET state='cancelled',eligible_payload=NULL,locator_map=NULL,diagnostics='[{"code":"access_or_input_changed"}]' WHERE id=(result->>'job_id')::uuid;
   CONTINUE;
  END IF;
  -- The old queue remains the eligibility/lease authority. Its full source view
  -- never crosses the workbench worker boundary.
  RETURN result||jsonb_build_object('eligible_payload',a.request_body,'locator_map',NULL);
 END LOOP;
END $$;
ALTER FUNCTION preparation.start_dispatch(uuid,text) RENAME TO start_dispatch_text;
CREATE FUNCTION preparation.start_dispatch(job uuid,lease text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE j preparation.jobs; a preparation.analysis_packets; p preparation.analysis_plans; cfg preparation.ai_configurations; reserved bigint; ceiling bigint;
BEGIN
 PERFORM preparation.require_worker();
 SELECT * INTO j FROM preparation.jobs WHERE id=job;
 IF j.task NOT IN ('classify_cards','group_labels') THEN RETURN preparation.start_dispatch_text(job,lease); END IF;
 PERFORM 1 FROM preparation.workspaces WHERE id=j.workspace_id FOR UPDATE;
 j:=preparation.leased_job(job,lease);
 SELECT x.* INTO a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=job;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=a.plan_id AND version=a.plan_version FOR UPDATE;
 IF NOT preparation.workbench_packet_current(a.packet_id) THEN
  UPDATE preparation.jobs SET state='cancelled',eligible_payload=NULL,locator_map=NULL,diagnostics='[{"code":"access_or_input_changed"}]' WHERE id=job;
  RETURN '{"state":"cancelled"}'; END IF;
 SELECT * INTO cfg FROM preparation.ai_configurations WHERE version=j.config_version;
 ceiling:=ceil((cfg.max_input_tokens::numeric*cfg.input_rate_microusd_per_million+cfg.max_output_tokens::numeric*cfg.output_rate_microusd_per_million)/1000000)::bigint;
 SELECT COALESCE(sum(b.ceiling_microusd),0) INTO reserved FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.budget_reservations b ON b.job_id=q.job_id WHERE x.plan_id=p.plan_id AND x.plan_version=p.version;
 IF ceiling+reserved>(p.followup_limits->>'max_reserved_micro_usd')::bigint THEN
  UPDATE preparation.jobs SET state='failed',diagnostics='[{"code":"budget_exceeded"}]' WHERE id=job;
  INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(p.plan_id,p.version,'blocked',jsonb_build_object('packet_id',a.packet_id,'code','waiting_budget'));
  RETURN '{"state":"failed","code":"budget_exceeded"}'; END IF;
 RETURN preparation.start_dispatch_text(job,lease);
END $$;

CREATE FUNCTION preparation.workbench_codes(codes jsonb) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF jsonb_typeof(codes) IS DISTINCT FROM 'array' OR jsonb_array_length(codes)>100 OR EXISTS(SELECT FROM jsonb_array_elements(codes) c WHERE jsonb_typeof(c)<>'string' OR c#>>'{}' NOT IN (
 'invalid_shape','unsupported_field','unresolved_reference','incomplete_units','incomplete_bases','duplicate_unit','foreign_unit','invalid_unit','duplicate_proposal','unreferenced_proposal','missing_proposal','incomplete_catalog','insufficient_context','mixed_context','unknown_context','unsampled_occurrences','provider_refused','provider_incomplete','invalid_result')) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_diagnostics'; END IF;
END $$;
CREATE FUNCTION preparation.validate_workbench_result(a preparation.analysis_packets,result jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE u jsonb; requested jsonb; b jsonb; p jsonb; c jsonb; h jsonb; k jsonb; member jsonb; allowed_supports jsonb; weak_group boolean; known_context text; required jsonb:=a.manifest->'required_unit_keys';
BEGIN
 PERFORM preparation.closed(result,ARRAY['schema_version','task','request_digest','state','unit_results','unprocessed_unit_keys','proposals','diagnostics'],ARRAY['schema_version','task','request_digest','state','unit_results','unprocessed_unit_keys','proposals','diagnostics']);
 IF result->'schema_version' IS DISTINCT FROM '1'::jsonb OR result->>'task' IS DISTINCT FROM a.task OR result->>'request_digest' IS DISTINCT FROM preparation.workbench_digest(a.request_body) OR
  result->>'state' IS NULL OR result->>'state' NOT IN ('complete','incomplete','refused') OR jsonb_typeof(result->'unit_results') IS DISTINCT FROM 'array' OR jsonb_typeof(result->'unprocessed_unit_keys') IS DISTINCT FROM 'array' OR jsonb_typeof(result->'proposals') IS DISTINCT FROM 'array' OR jsonb_typeof(result->'diagnostics') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_result'; END IF;
 PERFORM preparation.workbench_codes(result->'diagnostics');
 IF EXISTS(SELECT FROM jsonb_array_elements(result->'unprocessed_unit_keys') x GROUP BY x HAVING count(*)>1) OR EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') x GROUP BY x->>'unit_key' HAVING count(*)>1) OR EXISTS(SELECT FROM jsonb_array_elements(result->'proposals') x GROUP BY x->>'proposal_key' HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(required) x WHERE NOT EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') y WHERE y->'unit_key'=x) AND NOT (result->'unprocessed_unit_keys') @> jsonb_build_array(x)) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_coverage_mismatch'; END IF;
 FOR k IN SELECT * FROM jsonb_array_elements(result->'unprocessed_unit_keys') LOOP
  IF NOT required @> jsonb_build_array(k) OR EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') x WHERE x->'unit_key'=k) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_coverage_mismatch'; END IF;
 END LOOP;
 FOR u IN SELECT * FROM jsonb_array_elements(result->'unit_results') LOOP
  PERFORM preparation.closed(u,ARRAY['unit_key','record_key','state','processed_basis_keys','unprocessed_basis_keys','proposal_keys','hypotheses','diagnostics'],ARRAY['unit_key','record_key','state','processed_basis_keys','unprocessed_basis_keys','proposal_keys','hypotheses','diagnostics']);
  SELECT x INTO requested FROM jsonb_array_elements(a.data->'units') x WHERE x->'unit_key'=u->'unit_key';
  IF requested IS NULL OR NOT required @> jsonb_build_array(u->'unit_key') OR u->'record_key' IS DISTINCT FROM requested->'record_key' OR u->>'state' IS NULL OR u->>'state' NOT IN ('analyzed','insufficient_context','not_analyzed') OR
   jsonb_typeof(u->'processed_basis_keys') IS DISTINCT FROM 'array' OR jsonb_typeof(u->'unprocessed_basis_keys') IS DISTINCT FROM 'array' OR jsonb_typeof(u->'proposal_keys') IS DISTINCT FROM 'array' OR jsonb_typeof(u->'hypotheses') IS DISTINCT FROM 'array' OR jsonb_typeof(u->'diagnostics') IS DISTINCT FROM 'array' OR
   NOT (requested->'basis_keys') @> ((u->'processed_basis_keys')||(u->'unprocessed_basis_keys')) OR NOT ((u->'processed_basis_keys')||(u->'unprocessed_basis_keys')) @> (requested->'basis_keys') OR
   EXISTS(SELECT FROM jsonb_array_elements(u->'processed_basis_keys') x JOIN jsonb_array_elements(u->'unprocessed_basis_keys') y ON x=y) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_unit_mismatch'; END IF;
  IF u->>'state'='not_analyzed' AND (u->'processed_basis_keys'<>'[]'::jsonb OR u->'hypotheses'<>'[]'::jsonb OR u->'proposal_keys'<>'[]'::jsonb) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_unit_mismatch'; END IF;
  PERFORM preparation.workbench_codes(u->'diagnostics');
  IF EXISTS(SELECT FROM jsonb_array_elements((u->'processed_basis_keys')||(u->'unprocessed_basis_keys')) x GROUP BY x HAVING count(*)>1) OR EXISTS(SELECT FROM jsonb_array_elements(u->'proposal_keys') x GROUP BY x HAVING count(*)>1) OR EXISTS(SELECT FROM jsonb_array_elements(u->'hypotheses') x GROUP BY x->>'hypothesis_key' HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_workbench_reference'; END IF;
  IF result->>'state'='complete' AND (u->>'state'='not_analyzed' OR u->'unprocessed_basis_keys'<>'[]'::jsonb) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='false_complete_workbench_result'; END IF;
  IF a.task='classify_cards' AND EXISTS(SELECT FROM jsonb_array_elements(u->'processed_basis_keys') bk WHERE (SELECT count(*) FROM jsonb_array_elements(result->'proposals') proposal WHERE proposal->'basis_key'=bk AND (u->'proposal_keys') @> jsonb_build_array(proposal->'proposal_key'))<>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='explicit_basis_outcome_required'; END IF;
  FOR k IN SELECT * FROM jsonb_array_elements(u->'proposal_keys') LOOP
   IF NOT EXISTS(SELECT FROM jsonb_array_elements(result->'proposals') x WHERE x->'proposal_key'=k AND (a.task='group_labels' OR (u->'processed_basis_keys') @> jsonb_build_array(x->'basis_key'))) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_proposal_ownership'; END IF;
  END LOOP;
  FOR h IN SELECT * FROM jsonb_array_elements(u->'hypotheses') LOOP
   PERFORM preparation.closed(h,ARRAY['hypothesis_key','kind','statement','status','trigger_support_keys','verification_needed'],ARRAY['hypothesis_key','kind','statement','status','trigger_support_keys','verification_needed']);
   IF h->>'kind' IS DISTINCT FROM 'abbreviation_expansion' OR h->>'status' IS DISTINCT FROM 'unverified' OR h->'verification_needed' IS DISTINCT FROM 'true'::jsonb OR jsonb_typeof(h->'statement') IS DISTINCT FROM 'string' OR length(btrim(h->>'statement')) NOT BETWEEN 1 AND 300 OR jsonb_typeof(h->'trigger_support_keys') IS DISTINCT FROM 'array' OR jsonb_array_length(h->'trigger_support_keys')=0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='model_hypothesis_verification_forbidden'; END IF;
   FOR k IN SELECT * FROM jsonb_array_elements(h->'trigger_support_keys') LOOP
    IF NOT EXISTS(SELECT FROM jsonb_array_elements(a.data->'supports') x WHERE x->'support_key'=k AND x->'record_key'=u->'record_key') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_workbench_support'; END IF;
   END LOOP;
  END LOOP;
 END LOOP;
 IF result->>'state'='complete' AND result->'unprocessed_unit_keys'<>'[]'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='false_complete_workbench_result'; END IF;
 FOR p IN SELECT * FROM jsonb_array_elements(result->'proposals') LOOP
  IF a.task='classify_cards' THEN
   PERFORM preparation.closed(p,ARRAY['proposal_key','basis_key','state','choices','missing_context'],ARRAY['proposal_key','basis_key','state','choices','missing_context']);
   SELECT x INTO b FROM jsonb_array_elements(a.data->'bases') x WHERE x->'basis_key'=p->'basis_key';
   IF b IS NULL OR p->>'state' IS NULL OR p->>'state' NOT IN ('proposed','no_supplied_match','insufficient_context') OR jsonb_typeof(p->'missing_context') IS DISTINCT FROM 'array' OR NOT EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') x WHERE (x->'processed_basis_keys') @> jsonb_build_array(p->'basis_key') AND (x->'proposal_keys') @> jsonb_build_array(p->'proposal_key')) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_workbench_proposal'; END IF;
   PERFORM preparation.workbench_codes(p->'missing_context');
  ELSE
   PERFORM preparation.closed(p,ARRAY['proposal_key','relation','unit_keys','membership_issues','choices','reason','support_keys'],ARRAY['proposal_key','relation','unit_keys','membership_issues','choices','reason','support_keys']);
   IF p->>'relation' IS NULL OR p->>'relation' NOT IN ('equivalent','related','ambiguous') OR jsonb_typeof(p->'unit_keys') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'unit_keys')<1 OR jsonb_typeof(p->'membership_issues') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_proposal'; END IF;
   FOR k IN SELECT * FROM jsonb_array_elements(p->'unit_keys') LOOP
    IF NOT EXISTS(SELECT FROM jsonb_array_elements(a.data->'labels') x WHERE x->'unit_key'=k) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_group_member'; END IF;
   END LOOP;
   IF jsonb_typeof(p->'reason') IS DISTINCT FROM 'string' OR length(btrim(p->>'reason')) NOT BETWEEN 1 AND 300 OR jsonb_typeof(p->'support_keys') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_reason'; END IF;
   IF jsonb_array_length(p->'unit_keys')=1 AND NOT EXISTS(SELECT FROM jsonb_array_elements(a.data->'labels') l WHERE l->'unit_key'=p#>'{unit_keys,0}' AND (SELECT count(DISTINCT jsonb_build_array(o->'record_key',o->'basis_key')) FROM jsonb_array_elements(l->'occurrences') o)>=2) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='insufficient_group_occurrences'; END IF;
   known_context:=preparation.workbench_digest(jsonb_build_object('scope',a.request_body#>'{shared_context,scope}','catalog_snapshot',a.request_body#>'{shared_context,catalog_snapshot}'));
   SELECT COALESCE(jsonb_agg(DISTINCT sk),'[]') INTO allowed_supports FROM jsonb_array_elements(a.data->'labels') l,jsonb_array_elements(l->'occurrences') occurrence,jsonb_array_elements(occurrence->'support_keys') sk WHERE (p->'unit_keys') @> jsonb_build_array(l->'unit_key');
   weak_group:=false;
   FOR member IN SELECT * FROM jsonb_array_elements(a.data->'labels') l WHERE (p->'unit_keys') @> jsonb_build_array(l->'unit_key') LOOP
    IF member->>'context_key' IS DISTINCT FROM known_context OR (member->>'count')::integer>jsonb_array_length(member->'occurrences') THEN
     weak_group:=true;
     IF NOT EXISTS(SELECT FROM jsonb_array_elements(p->'membership_issues') issue WHERE issue->'unit_key'=member->'unit_key') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_membership_issue_required'; END IF;
    END IF;
   END LOOP;
   IF weak_group AND (p->>'relation'='equivalent' OR p->'choices'<>'[]'::jsonb) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_context_not_applicable'; END IF;
   FOR member IN SELECT * FROM jsonb_array_elements(p->'membership_issues') LOOP
    PERFORM preparation.closed(member,ARRAY['unit_key','reason'],ARRAY['unit_key','reason']);
    IF NOT (p->'unit_keys') @> jsonb_build_array(member->'unit_key') OR jsonb_typeof(member->'reason') IS DISTINCT FROM 'string' OR length(btrim(member->>'reason')) NOT BETWEEN 1 AND 300 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_membership_issue'; END IF;
   END LOOP;
   IF NOT allowed_supports @> (p->'support_keys') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_group_support'; END IF;
   IF NOT EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') x JOIN jsonb_array_elements(a.data->'units') y ON y->'unit_key'=x->'unit_key' WHERE (x->'proposal_keys') @> jsonb_build_array(p->'proposal_key') AND (y->'member_keys') @> (p->'unit_keys')) OR EXISTS(SELECT FROM jsonb_array_elements(p->'unit_keys') x GROUP BY x HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_group_proposal'; END IF;
  END IF;
  IF jsonb_typeof(p->'proposal_key') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'choices') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'choices')>5 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_proposal'; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(result->'unit_results') x WHERE (x->'proposal_keys') @> jsonb_build_array(p->'proposal_key'))<>1 OR (a.task='classify_cards' AND ((p->>'state'='proposed' AND jsonb_array_length(p->'choices')=0) OR (p->>'state'<>'proposed' AND jsonb_array_length(p->'choices')<>0))) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_proposal_owner_or_state'; END IF;
  FOR c IN SELECT * FROM jsonb_array_elements(p->'choices') LOOP
   PERFORM preparation.closed(c,ARRAY['candidate_key','reason','support_keys'],ARRAY['candidate_key','reason','support_keys']);
   IF NOT EXISTS(SELECT FROM jsonb_array_elements(a.request_body#>'{catalog_context,entries}') x WHERE x->'candidate_key'=c->'candidate_key') OR jsonb_typeof(c->'reason') IS DISTINCT FROM 'string' OR length(btrim(c->>'reason')) NOT BETWEEN 1 AND 300 OR jsonb_typeof(c->'support_keys') IS DISTINCT FROM 'array' OR jsonb_array_length(c->'support_keys')=0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_choice'; END IF;
   IF a.task='group_labels' AND NOT allowed_supports @> (c->'support_keys') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_group_support'; END IF;
   IF a.task='classify_cards' AND EXISTS(SELECT FROM jsonb_array_elements(result->'unit_results') owner WHERE (owner->'proposal_keys') @> jsonb_build_array(p->'proposal_key') AND owner->'hypotheses'<>'[]'::jsonb AND NOT EXISTS(SELECT FROM jsonb_array_elements(c->'support_keys') sk WHERE NOT EXISTS(SELECT FROM jsonb_array_elements(owner->'hypotheses') hypothesis WHERE (hypothesis->'trigger_support_keys') @> jsonb_build_array(sk)))) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hypothesis_trigger_cannot_justify_category'; END IF;
   FOR k IN SELECT * FROM jsonb_array_elements(c->'support_keys') LOOP
    IF NOT EXISTS(SELECT FROM jsonb_array_elements(a.data->'supports') x WHERE x->'support_key'=k AND (a.task='group_labels' OR x->'record_key'=b->'record_key')) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_workbench_support'; END IF;
   END LOOP;
  END LOOP;
 END LOOP;
END $$;
CREATE FUNCTION preparation.reconcile_workbench_result(a preparation.analysis_packets,result jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE u jsonb; proposals jsonb; trial jsonb; retained jsonb:='[]'; kept jsonb:='[]'; unresolved jsonb; invalid boolean:=false; basis_key jsonb; requested jsonb; partial_unit jsonb; partial_proposals jsonb; partial_bases jsonb; one_proposals jsonb;
BEGIN
 -- Shape/digest failure invalidates the entire envelope. Only unit-local faults
 -- in a parseable correctly bound envelope may be recovered independently.
 PERFORM preparation.closed(result,ARRAY['schema_version','task','request_digest','state','unit_results','unprocessed_unit_keys','proposals','diagnostics'],ARRAY['schema_version','task','request_digest','state','unit_results','unprocessed_unit_keys','proposals','diagnostics']);
 IF result->'schema_version' IS DISTINCT FROM '1'::jsonb OR result->>'task' IS DISTINCT FROM a.task OR result->>'request_digest' IS DISTINCT FROM preparation.workbench_digest(a.request_body) OR
  result->>'state' IS NULL OR result->>'state' NOT IN ('complete','incomplete','refused') OR jsonb_typeof(result->'unit_results') IS DISTINCT FROM 'array' OR jsonb_typeof(result->'unprocessed_unit_keys') IS DISTINCT FROM 'array' OR jsonb_typeof(result->'proposals') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_result'; END IF;
 PERFORM preparation.workbench_codes(result->'diagnostics');
 FOR u IN SELECT * FROM jsonb_array_elements(result->'unit_results') LOOP
  IF (SELECT count(*) FROM jsonb_array_elements(result->'unit_results') x WHERE x->'unit_key'=u->'unit_key')<>1 OR
   EXISTS(SELECT FROM jsonb_array_elements(result->'proposals') x WHERE (u->'proposal_keys') @> jsonb_build_array(x->'proposal_key') GROUP BY x->>'proposal_key' HAVING count(*)>1) THEN invalid:=true; CONTINUE; END IF;
  SELECT COALESCE(jsonb_agg(x),'[]') INTO proposals FROM jsonb_array_elements(result->'proposals') x WHERE (u->'proposal_keys') @> jsonb_build_array(x->'proposal_key');
  SELECT COALESCE(jsonb_agg(k),'[]') INTO unresolved FROM jsonb_array_elements(a.manifest->'required_unit_keys') k WHERE k IS DISTINCT FROM u->'unit_key';
  trial:=result||jsonb_build_object('state','incomplete','unit_results',jsonb_build_array(u),'proposals',proposals,'unprocessed_unit_keys',unresolved);
  BEGIN
   PERFORM preparation.validate_workbench_result(a,trial);
   retained:=retained||jsonb_build_array(u); kept:=kept||proposals;
  EXCEPTION WHEN data_exception OR check_violation THEN
   invalid:=true; partial_bases:='[]'; partial_proposals:='[]';
   SELECT x INTO requested FROM jsonb_array_elements(a.data->'units') x WHERE x->'unit_key'=u->'unit_key';
   IF a.task='classify_cards' AND jsonb_typeof(u->'processed_basis_keys')='array' AND requested->'record_key'=u->'record_key' THEN
    FOR basis_key IN SELECT DISTINCT value FROM jsonb_array_elements(u->'processed_basis_keys') LOOP
     SELECT COALESCE(jsonb_agg(x),'[]') INTO one_proposals FROM jsonb_array_elements(proposals) x WHERE x->'basis_key'=basis_key;
     partial_unit:=u||jsonb_build_object('processed_basis_keys',jsonb_build_array(basis_key),'unprocessed_basis_keys',(SELECT COALESCE(jsonb_agg(k),'[]') FROM jsonb_array_elements(requested->'basis_keys') k WHERE k<>basis_key),
      'proposal_keys',(SELECT COALESCE(jsonb_agg(x->'proposal_key'),'[]') FROM jsonb_array_elements(one_proposals) x),'hypotheses',u->'hypotheses');
     BEGIN
      PERFORM preparation.validate_workbench_result(a,trial||jsonb_build_object('unit_results',jsonb_build_array(partial_unit),'proposals',one_proposals));
      partial_bases:=partial_bases||jsonb_build_array(basis_key); partial_proposals:=partial_proposals||one_proposals;
     EXCEPTION WHEN data_exception OR check_violation THEN NULL; END;
    END LOOP;
   END IF;
   IF partial_bases<>'[]'::jsonb THEN
    partial_unit:=u||jsonb_build_object('processed_basis_keys',partial_bases,'unprocessed_basis_keys',(SELECT COALESCE(jsonb_agg(k),'[]') FROM jsonb_array_elements(requested->'basis_keys') k WHERE NOT partial_bases @> jsonb_build_array(k)),
     'proposal_keys',(SELECT jsonb_agg(x->'proposal_key') FROM jsonb_array_elements(partial_proposals) x),'hypotheses',u->'hypotheses','diagnostics','["incomplete_bases"]'::jsonb);
    retained:=retained||jsonb_build_array(partial_unit); kept:=kept||partial_proposals;
   END IF;
  END;
 END LOOP;
 SELECT COALESCE(jsonb_agg(k),'[]') INTO unresolved FROM jsonb_array_elements(a.manifest->'required_unit_keys') k WHERE NOT EXISTS(SELECT FROM jsonb_array_elements(retained) u WHERE u->'unit_key'=k);
 trial:=result||jsonb_build_object('unit_results',retained,'proposals',kept,'unprocessed_unit_keys',unresolved,
  'state',CASE WHEN result->>'state'='complete' AND NOT invalid AND unresolved='[]'::jsonb AND NOT EXISTS(SELECT FROM jsonb_array_elements(retained) u WHERE u->>'state'='not_analyzed' OR u->'unprocessed_basis_keys'<>'[]'::jsonb) THEN 'complete' WHEN result->>'state'='refused' AND retained='[]'::jsonb THEN 'refused' ELSE 'incomplete' END,
  'diagnostics',CASE WHEN invalid THEN '["invalid_unit"]'::jsonb ELSE result->'diagnostics' END);
 PERFORM preparation.validate_workbench_result(a,trial);
 RETURN trial;
END $$;

ALTER FUNCTION preparation.finish_job(uuid,uuid,text,jsonb,jsonb) RENAME TO finish_job_text;
CREATE OR REPLACE FUNCTION preparation.finish_job_text(job uuid,dispatch uuid,lease text,result jsonb,usage jsonb) RETURNS jsonb
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
 UPDATE preparation.jobs SET candidate_ids=generated_ids,state=final_state,output=CASE WHEN applicable THEN result ELSE NULL END,usage=finish_job_text.usage,
  completion_digest=digest,finished_at=clock_timestamp(),diagnostics=CASE WHEN NOT applicable THEN '[{"code":"access_or_input_changed"}]'::jsonb
   WHEN final_state='failed' THEN '[{"code":"invalid_or_incomplete_output"}]'::jsonb ELSE '[]'::jsonb END WHERE jobs.id=job;
 RETURN jsonb_build_object('state',final_state,'settled',true);
END $$;
CREATE FUNCTION preparation.finish_job(job uuid,dispatch uuid,lease text,result jsonb,usage jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE j preparation.jobs; a preparation.analysis_packets;
BEGIN
 j:=preparation.leased_job(job,lease);
 IF j.task IN ('classify_cards','group_labels') THEN
  SELECT x.* INTO STRICT a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=job;
  BEGIN result:=preparation.reconcile_workbench_result(a,result);
  EXCEPTION WHEN data_exception OR check_violation THEN NULL; END;
 END IF;
 RETURN preparation.finish_job_text(job,dispatch,lease,result,usage);
END $$;
ALTER FUNCTION preparation.validate_job_result(preparation.jobs,jsonb) RENAME TO validate_job_result_text;
CREATE FUNCTION preparation.validate_job_result(j preparation.jobs,result jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE a preparation.analysis_packets;
BEGIN
 IF j.task NOT IN ('classify_cards','group_labels') THEN PERFORM preparation.validate_job_result_text(j,result); RETURN; END IF;
 SELECT x.* INTO STRICT a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=j.id;
 IF NOT preparation.workbench_packet_current(a.packet_id) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='stale_workbench_packet'; END IF;
 PERFORM preparation.validate_workbench_result(a,result);
END $$;

CREATE FUNCTION preparation.persist_workbench_units() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE a preparation.analysis_packets; u jsonb;
BEGIN
 IF NEW.task NOT IN ('classify_cards','group_labels') OR NEW.output IS NULL OR OLD.output IS NOT NULL THEN RETURN NEW; END IF;
 SELECT x.* INTO STRICT a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=NEW.id;
 PERFORM preparation.validate_workbench_result(a,NEW.output);
 FOR u IN SELECT * FROM jsonb_array_elements(NEW.output->'unit_results') LOOP
  INSERT INTO preparation.workbench_unit_results VALUES(a.packet_id,u->>'unit_key',NEW.id,u->>'record_key',u->>'state',u->'processed_basis_keys',u->'unprocessed_basis_keys',u);
 END LOOP;
 INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(a.plan_id,a.plan_version,'completed',jsonb_build_object('packet_id',a.packet_id,'state',NEW.output->>'state'));
 RETURN NEW;
END $$;
CREATE TRIGGER workbench_units AFTER UPDATE OF output ON preparation.jobs FOR EACH ROW EXECUTE FUNCTION preparation.persist_workbench_units();

CREATE FUNCTION preparation.read_analysis_coverage(wid uuid,pid uuid,pversion bigint,record_offset integer DEFAULT 0,page_size integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE p preparation.analysis_plans; selected jsonb; required jsonb; done jsonb; outcomes jsonb:='[]'; state text; states jsonb; summary jsonb;
 completed jsonb; pending jsonb; selected_labels jsonb; progress text; comparison_state text; total integer; insufficient boolean; latest_state text; latest_result_state text;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR record_offset IS NULL OR page_size NOT BETWEEN 1 AND 100 OR record_offset NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_coverage_page'; END IF;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid;
 IF p.plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 FOR selected IN SELECT * FROM jsonb_array_elements(p.selection) LOOP
  SELECT COALESCE(jsonb_agg(DISTINCT bk),'[]') INTO required FROM preparation.analysis_packets a,
   jsonb_array_elements(a.data->'units') u,jsonb_array_elements(u->'basis_keys') bk WHERE a.plan_id=pid AND a.plan_version=pversion AND a.stage='initial' AND a.task='classify_cards' AND u->'record_key'=selected->'record_key' AND (a.manifest->'required_unit_keys') @> jsonb_build_array(u->'unit_key');
  SELECT COALESCE(jsonb_agg(DISTINCT bk),'[]'),COALESCE(bool_or(r.state='insufficient_context'),false) INTO done,insufficient FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id),jsonb_array_elements(r.processed_basis_keys) bk WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards' AND r.record_key=selected->>'record_key';
  SELECT j.state,j.output->>'state' INTO latest_state,latest_result_state FROM preparation.analysis_packets a JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.jobs j ON j.id=q.job_id WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards' AND (a.manifest->'required_record_ids') @> jsonb_build_array(selected->'record_key') ORDER BY j.created_at DESC,j.id DESC LIMIT 1;
  IF NOT EXISTS(SELECT FROM preparation.items i WHERE i.id=(selected->>'record_key')::uuid AND i.workspace_id=wid AND i.trashed_at IS NULL AND i.current_version_id=(selected->>'item_version')::uuid) OR NOT EXISTS(SELECT FROM preparation.workspaces WHERE id=wid AND current_input_id=p.input_id) THEN state:='stale';
  ELSIF required='[]'::jsonb THEN state:='ineligible';
  ELSIF done @> required THEN state:=CASE WHEN insufficient THEN 'insufficient_context' ELSE 'validated' END;
  ELSIF jsonb_array_length(done)>0 THEN state:='partial';
  ELSE state:=CASE latest_state WHEN 'running' THEN 'running' WHEN 'leased' THEN 'running' WHEN 'queued' THEN 'queued' WHEN 'uncertain' THEN 'uncertain' WHEN 'cancelled' THEN 'cancelled' WHEN 'failed' THEN CASE WHEN latest_result_state='refused' THEN 'refused' ELSE 'invalid_result' END ELSE 'pending' END; END IF;
  comparison_state:=NULL;
  IF EXISTS(SELECT FROM jsonb_array_elements(p.comparison_seed->'labels') l,jsonb_array_elements(l->'occurrences') occurrence WHERE occurrence->'record_key'=selected->'record_key') THEN
   SELECT CASE WHEN bool_or(r.state='insufficient_context') THEN 'insufficient_context' ELSE 'compared' END INTO comparison_state FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='group_labels' AND r.state IN ('analyzed','insufficient_context') HAVING count(*)>0;
   comparison_state:=COALESCE(comparison_state,'awaiting_comparison');
  ELSIF EXISTS(SELECT FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id,jsonb_array_elements(COALESCE(v.payload->'interpreted_classifications','[]')) interpretation WHERE i.id=(selected->>'record_key')::uuid AND interpretation->>'state' IN ('proposed','confirmed') AND EXISTS(SELECT FROM preparation.analysis_packets a JOIN preparation.packet_jobs q USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND q.job_id::text=interpretation->>'job_id')) THEN comparison_state:='awaiting_new_preview';
  ELSIF EXISTS(SELECT FROM preparation.analysis_packets a JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.jobs j ON j.id=q.job_id,jsonb_array_elements(j.output->'proposals') proposal,jsonb_array_elements(a.data->'bases') b WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards' AND b->'record_key'=selected->'record_key' AND b->>'kind'='description' AND b->'basis_key'=proposal->'basis_key' AND jsonb_array_length(proposal->'choices')>0) THEN comparison_state:='awaiting_materialization';
  ELSE comparison_state:=CASE WHEN state IN ('pending','queued','running','partial') THEN 'awaiting_analysis' WHEN state IN ('validated','insufficient_context') THEN 'abstained' ELSE state END;
  END IF;
  outcomes:=outcomes||jsonb_build_array(jsonb_build_object('record_key',selected->'record_key','item_version',selected->'item_version','context_digest',p.context_digest,'last_event_id',(SELECT max(event_id) FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion),
   'accepted_results',(SELECT COALESCE(jsonb_agg(to_jsonb(link)),'[]') FROM (SELECT r.packet_id,r.job_id,r.unit_key,r.state FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND r.record_key=selected->>'record_key' AND jsonb_array_length(r.processed_basis_keys)>0 ORDER BY r.packet_id,r.unit_key LIMIT 100) link),
   'accepted_result_count',(SELECT count(*) FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND r.record_key=selected->>'record_key' AND jsonb_array_length(r.processed_basis_keys)>0),
   'state',state,'comparison_state',comparison_state,'required_basis_keys',required,'processed_basis_keys',done,
   'unprocessed_basis_keys',(SELECT COALESCE(jsonb_agg(v),'[]') FROM jsonb_array_elements(required) v WHERE NOT done @> jsonb_build_array(v))));
 END LOOP;
 SELECT jsonb_build_object('selected_records',count(*),'validated_records',count(*) FILTER(WHERE x->>'state'='validated'),'insufficient_context_records',count(*) FILTER(WHERE x->>'state'='insufficient_context'),
 'partial_records',count(*) FILTER(WHERE x->>'state'='partial'),'pending_records',count(*) FILTER(WHERE x->>'state' IN ('pending','queued','running')),'blocked_records',count(*) FILTER(WHERE x->>'state' IN ('ineligible','invalid_result','refused','uncertain','cancelled')),'stale_records',count(*) FILTER(WHERE x->>'state'='stale'),'scope_digest',p.selection_digest) INTO summary FROM jsonb_array_elements(outcomes) x;
 SELECT COALESCE(jsonb_agg(x->'unit_key'),'[]') INTO selected_labels FROM jsonb_array_elements(p.comparison_seed->'labels') x;
 SELECT COALESCE(jsonb_agg(DISTINCT r.unit_key),'[]') INTO completed FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='group_labels' AND r.state IN ('analyzed','insufficient_context');
 SELECT COALESCE(jsonb_agg(k),'[]') INTO pending FROM preparation.analysis_packets a,jsonb_array_elements(a.manifest->'required_unit_keys') k WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='group_labels' AND NOT completed @> jsonb_build_array(k);
 IF selected_labels<>'[]'::jsonb AND completed='[]'::jsonb AND pending='[]'::jsonb THEN pending:=jsonb_build_array('comparison:'||pid::text); END IF;
 progress:=CASE WHEN EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND body->>'code'='plan_cancelled') THEN 'cancelled'
  WHEN NOT EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND kind='started') THEN 'planned'
  WHEN EXISTS(SELECT FROM jsonb_array_elements(outcomes) x WHERE x->>'state' IN ('queued','running')) THEN 'running'
  WHEN EXISTS(SELECT FROM jsonb_array_elements(outcomes) x WHERE x->>'state'='uncertain') THEN 'waiting_retry'
  WHEN EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND body->>'code'='waiting_budget') THEN 'waiting_budget'
  WHEN (summary->>'validated_records')::integer+(summary->>'insufficient_context_records')::integer=(summary->>'selected_records')::integer AND pending='[]'::jsonb AND NOT EXISTS(SELECT FROM jsonb_array_elements(outcomes) o WHERE o->>'comparison_state' IN ('awaiting_materialization','awaiting_new_preview')) THEN 'finished' ELSE 'finished_with_gaps' END;
 RETURN jsonb_build_object('plan_id',pid,'plan_version',pversion,'progress',progress,'record_coverage',summary,
  'records',(SELECT COALESCE(jsonb_agg(v),'[]') FROM (SELECT value v FROM jsonb_array_elements(outcomes) WITH ORDINALITY e(value,n) ORDER BY n LIMIT page_size OFFSET record_offset) s),
  'total_records',jsonb_array_length(outcomes),'next_record_offset',CASE WHEN record_offset+page_size<jsonb_array_length(outcomes) THEN record_offset+page_size END,
  'awaiting_materialization_records',(SELECT count(*) FROM jsonb_array_elements(outcomes) o WHERE o->>'comparison_state'='awaiting_materialization'),
  'comparison_abstained_records',(SELECT count(*) FROM jsonb_array_elements(outcomes) o WHERE o->>'comparison_state'='abstained'),
  'comparison_coverage',jsonb_build_object('scope_digest',p.context_digest,'selected_unit_keys',selected_labels,'completed_scope_keys',completed,'pending_scope_keys',pending,'omitted_unit_keys','[]'::jsonb,'reference_unit_keys','[]'::jsonb,'limitations',CASE WHEN EXISTS(SELECT FROM jsonb_array_elements(outcomes) o WHERE o->>'comparison_state' IN ('awaiting_materialization','awaiting_new_preview')) THEN '["incomplete_units"]'::jsonb WHEN EXISTS(SELECT FROM jsonb_array_elements(outcomes) o WHERE o->>'comparison_state'='abstained') THEN '["insufficient_context"]'::jsonb ELSE '[]'::jsonb END));
END $$;

CREATE FUNCTION preparation.continue_analysis_plan(wid uuid,pid uuid,pversion bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); p preparation.analysis_plans; a preparation.analysis_packets; source jsonb; u jsonb; missing jsonb; units jsonb:='[]'; basis_keys jsonb:='[]'; data jsonb; packet uuid; predecessors jsonb; replay jsonb; body jsonb:=jsonb_build_object('plan_id',pid,'version',pversion);
BEGIN
 replay:=preparation.replay(wid,'continue_analysis_plan',body,key); IF replay IS NOT NULL THEN RETURN replay; END IF;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid FOR UPDATE;
 IF p.plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND kind='started') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='analysis_plan_not_started'; END IF;
 IF EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND body->>'code'='plan_cancelled') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='analysis_plan_cancelled'; END IF;
 IF EXISTS(SELECT FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.jobs j ON j.id=q.job_id WHERE x.plan_id=pid AND x.plan_version=pversion AND j.state IN ('queued','leased','running','uncertain')) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='analysis_plan_has_pending_dispatch'; END IF;
 FOR u IN SELECT * FROM jsonb_array_elements(p.comparison_seed->'units') LOOP
  SELECT COALESCE(jsonb_agg(b),'[]') INTO missing FROM jsonb_array_elements(u->'basis_keys') b WHERE NOT EXISTS(SELECT FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets x USING(packet_id) WHERE x.plan_id=pid AND x.plan_version=pversion AND x.task='classify_cards' AND r.record_key=u->>'record_key' AND r.processed_basis_keys @> jsonb_build_array(b));
  IF missing<>'[]'::jsonb THEN units:=units||jsonb_build_array(u||jsonb_build_object('basis_keys',missing)); basis_keys:=basis_keys||missing; END IF;
 END LOOP;
 IF units<>'[]'::jsonb THEN
  -- Preserve the original bounded partition; a continuation narrows each packet
  -- and never merges formerly separate source families into an oversized call.
  FOR a IN SELECT * FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND stage='initial' AND task='classify_cards' LOOP
   SELECT COALESCE(jsonb_agg(u),'[]') INTO source FROM jsonb_array_elements(units) u WHERE EXISTS(SELECT FROM jsonb_array_elements(a.data->'units') original WHERE original->'unit_key'=u->'unit_key');
   IF source='[]'::jsonb THEN CONTINUE; END IF;
   data:=a.data||jsonb_build_object('units',source,'labels','[]'::jsonb,'seed_groups','[]'::jsonb,'prior_proposals','[]'::jsonb,
    'records',(SELECT jsonb_agg(r) FROM jsonb_array_elements(a.data->'records') r WHERE EXISTS(SELECT FROM jsonb_array_elements(source) v WHERE v->'record_key'=r->'record_key')),
    'bases',(SELECT jsonb_agg(b) FROM jsonb_array_elements(a.data->'bases') b WHERE basis_keys @> jsonb_build_array(b->'basis_key')),
    'supports',(SELECT jsonb_agg(s) FROM jsonb_array_elements(a.data->'supports') s WHERE EXISTS(SELECT FROM jsonb_array_elements(source) v WHERE v->'record_key'=s->'record_key')));
   SELECT COALESCE(jsonb_agg(x.packet_id),'[]') INTO predecessors FROM preparation.analysis_packets x WHERE x.plan_id=pid AND x.plan_version=pversion AND x.task='classify_cards';
   packet:=preparation.freeze_workbench_packet(pid,pversion,'classify_cards','remaining_record_analysis',data,
    (SELECT jsonb_agg(r->'record_key') FROM jsonb_array_elements(data->'records') r),'[]',
    (SELECT jsonb_agg(v->'unit_key') FROM jsonb_array_elements(source) v),'[]',predecessors);
   PERFORM preparation.enqueue_workbench_packet(packet);
  END LOOP;
 ELSE PERFORM preparation.schedule_workbench_comparison(pid,pversion); END IF;
 RETURN preparation.receipt(wid,'continue_analysis_plan',body,key,preparation.read_analysis_coverage(wid,pid,pversion));
END $$;

CREATE FUNCTION preparation.schedule_workbench_comparison(pid uuid,pversion bigint) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE p preparation.analysis_plans; data jsonb; prior jsonb; predecessors jsonb; packet uuid; unit_key text:='comparison:'||pid::text;
BEGIN
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion FOR UPDATE;
 IF jsonb_array_length(p.comparison_seed->'labels')<1 OR EXISTS(SELECT FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND task='group_labels') THEN RETURN; END IF;
 IF EXISTS(SELECT FROM preparation.analysis_packets a JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.jobs j ON j.id=q.job_id WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards' AND j.state IN ('queued','leased','running','uncertain')) OR
  EXISTS(SELECT FROM jsonb_array_elements(p.comparison_seed->'units') u,jsonb_array_elements(u->'basis_keys') bk WHERE NOT EXISTS(SELECT FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards' AND r.record_key=u->>'record_key' AND r.processed_basis_keys @> jsonb_build_array(bk))) THEN RETURN; END IF;
 SELECT COALESCE(jsonb_agg(proposal||jsonb_build_object('proposal_key',a.packet_id::text||':'||(proposal->>'proposal_key'))),'[]') INTO prior FROM preparation.analysis_packets a JOIN preparation.packet_jobs q USING(packet_id) JOIN preparation.jobs j ON j.id=q.job_id,jsonb_array_elements(j.output->'proposals') proposal WHERE a.plan_id=pid AND a.plan_version=pversion AND a.task='classify_cards';
 SELECT COALESCE(jsonb_agg(packet_id),'[]') INTO predecessors FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND task='classify_cards';
 data:=p.comparison_seed||jsonb_build_object('prior_proposals',prior,'units',jsonb_build_array(jsonb_build_object('unit_key',unit_key,'record_key',NULL,'basis_keys','[]'::jsonb,'member_keys',(SELECT jsonb_agg(x->'unit_key') FROM jsonb_array_elements(p.comparison_seed->'labels') x))));
 packet:=preparation.freeze_workbench_packet(pid,pversion,'group_labels','cross_packet_comparison',data,'[]',
  (SELECT jsonb_agg(x->'record_key') FROM jsonb_array_elements(data->'records') x),jsonb_build_array(unit_key),'[]',predecessors);
 PERFORM preparation.enqueue_workbench_packet(packet);
EXCEPTION WHEN program_limit_exceeded THEN
 INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(pid,pversion,'blocked','{"code":"comparison_limit"}');
END $$;

CREATE FUNCTION preparation.auto_workbench_comparison() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE a preparation.analysis_packets;
BEGIN
 IF NEW.task='classify_cards' AND NEW.output IS NOT NULL AND OLD.output IS NULL THEN
  SELECT x.* INTO STRICT a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=NEW.id;
  PERFORM preparation.schedule_workbench_comparison(a.plan_id,a.plan_version);
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER zz_workbench_comparison AFTER UPDATE OF output ON preparation.jobs FOR EACH ROW EXECUTE FUNCTION preparation.auto_workbench_comparison();

CREATE FUNCTION preparation.select_workbench_result(wid uuid,job uuid,item uuid,expected uuid,keys jsonb,key uuid,hypotheses boolean) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); j preparation.jobs; a preparation.analysis_packets; iv preparation.item_versions; frozen uuid; field_path text; pointer text[]; p jsonb; k jsonb; proposal jsonb; b jsonb; anchor jsonb; c jsonb; target jsonb; candidates jsonb; ids jsonb; basis jsonb; context jsonb; entries jsonb:='[]'; result jsonb; kind text:=CASE WHEN hypotheses THEN 'select_workbench_hypotheses' ELSE 'select_workbench_proposals' END; body jsonb:=jsonb_build_object('job_id',job,'item_id',item,'expected_version',expected,'keys',keys);
BEGIN
 result:=preparation.replay(wid,kind,body,key); IF result IS NOT NULL THEN RETURN result; END IF;
 IF jsonb_typeof(keys) IS DISTINCT FROM 'array' OR jsonb_array_length(keys) NOT BETWEEN 1 AND 100 OR EXISTS(SELECT FROM jsonb_array_elements(keys) x GROUP BY x HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_workbench_selection'; END IF;
 SELECT * INTO j FROM preparation.jobs WHERE id=job AND workspace_id=wid AND task='classify_cards' AND output IS NOT NULL;
 SELECT x.* INTO a FROM preparation.analysis_packets x JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=job;
 SELECT v.* INTO iv FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.id=item AND i.workspace_id=wid AND i.trashed_at IS NULL AND v.id=expected;
 SELECT (r->>'item_version')::uuid INTO frozen FROM jsonb_array_elements(a.data->'records') r WHERE r->>'record_key'=item::text;
 IF j.id IS NULL OR iv.id IS NULL OR frozen IS NULL OR w.current_input_id IS DISTINCT FROM j.input_id OR preparation.eligible_input(wid,j.input_id) IS DISTINCT FROM (j.eligible_payload||jsonb_build_object('locator_map',j.locator_map)) OR
  NOT EXISTS(SELECT FROM preparation.ai_settings WHERE singleton AND enabled AND config_version=j.config_version) THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='workbench_selection_stale'; END IF;
 PERFORM preparation.validate_matching_context((SELECT provider_config->'catalog_context' FROM preparation.ai_configurations WHERE version=j.config_version));
 p:=iv.payload||jsonb_build_object('schema_version',3,'source_facts',COALESCE(iv.payload->'source_facts','[]'),'resolutions',COALESCE(iv.payload->'resolutions','[]'),
  'interpreted_classifications',COALESCE(iv.payload->'interpreted_classifications','[]'),'interpretation_hypotheses',COALESCE(iv.payload->'interpretation_hypotheses','[]'));
 context:=(a.request_body#>'{catalog_context,context}')||jsonb_build_object('catalog_digest',a.request_body#>>'{catalog_context,digest}','as_of',a.request_body#>>'{catalog_context,as_of}');
 FOR k IN SELECT * FROM jsonb_array_elements(keys) LOOP
  IF hypotheses THEN
   SELECT h INTO proposal FROM jsonb_array_elements(j.output->'unit_results') u,jsonb_array_elements(u->'hypotheses') h WHERE u->>'record_key'=item::text AND h->'hypothesis_key'=k;
   SELECT x INTO b FROM jsonb_array_elements(a.data->'bases') x WHERE x->>'record_key'=item::text AND EXISTS(SELECT FROM jsonb_array_elements(a.data->'supports') s WHERE s->>'origin'='source' AND s->'record_key'=x->'record_key' AND (x->'support_keys') @> jsonb_build_array(s->'support_key') AND (proposal->'trigger_support_keys') @> jsonb_build_array(s->'support_key')) LIMIT 1;
  ELSE
   SELECT x INTO proposal FROM jsonb_array_elements(j.output->'proposals') x WHERE x->'proposal_key'=k;
   SELECT x INTO b FROM jsonb_array_elements(a.data->'bases') x WHERE x->'basis_key'=proposal->'basis_key' AND x->>'record_key'=item::text;
  END IF;
  IF proposal IS NULL OR b IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='workbench_selection_record_mismatch'; END IF;
  -- Context-only proposals remain interpretations. Their private basis anchors
  -- the original owned description; the frozen job retains the weak context.
  SELECT x INTO anchor FROM jsonb_array_elements(a.data->'bases') x WHERE x->>'record_key'=item::text AND x->>'kind' IN ('description','category_label') AND
   (x->'basis_key'=b->'basis_key' OR b->>'kind'='source_context') ORDER BY (x->'basis_key'=b->'basis_key') DESC LIMIT 1;
  SELECT COALESCE(jsonb_agg(DISTINCT e->'id'),'[]') INTO ids FROM jsonb_array_elements(iv.evidence) e JOIN jsonb_array_elements(a.data->'supports') s ON s->>'origin'='source' AND s->>'field_path'=e->>'path' AND s->>'record_key'=item::text WHERE (anchor->'support_keys') @> jsonb_build_array(s->'support_key') AND e ? 'span';
  IF anchor IS NULL OR ids='[]'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_basis_required_for_materialization'; END IF;
  SELECT s->>'field_path' INTO field_path FROM jsonb_array_elements(a.data->'supports') s WHERE (anchor->'support_keys') @> jsonb_build_array(s->'support_key') AND s->>'origin'='source' LIMIT 1;
  SELECT array_agg(replace(replace(part,'~1','/'),'~0','~') ORDER BY n) INTO pointer FROM unnest(string_to_array(substr(field_path,2),'/')) WITH ORDINALITY e(part,n);
  IF iv.payload#>pointer IS DISTINCT FROM anchor->'value' OR iv.payload#>>ARRAY['field_origins',field_path,'state'] IN ('manual','cleared') THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='workbench_selection_basis_changed'; END IF;
  basis:=jsonb_build_object('item_version',frozen,'field_path',field_path,'value_digest',preparation.digest(anchor->'value'),'evidence_ids',ids);
  IF hypotheses THEN entries:=entries||jsonb_build_array(jsonb_build_object('hypothesis_id',gen_random_uuid(),'kind','abbreviation_expansion','statement',proposal->>'statement','state','unverified','basis',basis,'trigger_evidence_ids',ids,'job_id',job,'verification',NULL));
  ELSE
   candidates:='[]';
   FOR c IN SELECT * FROM jsonb_array_elements(proposal->'choices') LOOP
    SELECT x->'target' INTO target FROM jsonb_array_elements(a.request_body#>'{catalog_context,entries}') x WHERE x->'candidate_key'=c->'candidate_key';
    PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',(context-'catalog_digest'-'as_of'),target);
    candidates:=candidates||jsonb_build_array(jsonb_build_object('target',target,'reason',c->>'reason','support_evidence_ids',ids));
   END LOOP;
   entries:=entries||jsonb_build_array(jsonb_build_object('interpretation_id',gen_random_uuid(),'basis',basis,'context',context,'candidates',candidates,'state','proposed','selected',NULL,'method','ai','job_id',job));
  END IF;
 END LOOP;
 IF hypotheses THEN p:=jsonb_set(p,'{interpretation_hypotheses}',(p->'interpretation_hypotheses')||entries);
 ELSE p:=jsonb_set(p,'{interpreted_classifications}',(p->'interpreted_classifications')||entries); END IF;
 result:=preparation.save_items(wid,jsonb_build_array(jsonb_build_object('item_id',item,'expected_version',expected,'payload',p)),gen_random_uuid());
 RETURN preparation.receipt(wid,kind,body,key,result);
END $$;
CREATE FUNCTION preparation.select_workbench_proposals(wid uuid,job uuid,item uuid,expected uuid,keys jsonb,key uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT preparation.select_workbench_result(wid,job,item,expected,keys,key,false) $$;
CREATE FUNCTION preparation.select_workbench_hypotheses(wid uuid,job uuid,item uuid,expected uuid,keys jsonb,key uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT preparation.select_workbench_result(wid,job,item,expected,keys,key,true) $$;

CREATE FUNCTION preparation.retry_uncertain_analysis_packet(wid uuid,old_packet uuid,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); old preparation.analysis_packets; p preparation.analysis_plans; packet uuid:=gen_random_uuid(); result jsonb; body jsonb:=jsonb_build_object('packet_id',old_packet); manifest jsonb; request jsonb;
BEGIN
 result:=preparation.replay(wid,'retry_uncertain_analysis_packet',body,key); IF result IS NOT NULL THEN RETURN result; END IF;
 SELECT a.* INTO old FROM preparation.analysis_packets a JOIN preparation.analysis_plans p ON p.plan_id=a.plan_id AND p.version=a.plan_version WHERE a.packet_id=old_packet AND p.workspace_id=wid;
 SELECT * INTO p FROM preparation.analysis_plans WHERE plan_id=old.plan_id AND version=old.plan_version FOR UPDATE;
 IF p.plan_id IS NULL OR NOT EXISTS(SELECT FROM preparation.packet_jobs q JOIN preparation.jobs j ON j.id=q.job_id WHERE q.packet_id=old_packet AND j.state='uncertain') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='explicit_uncertain_packet_required'; END IF;
 IF NOT preparation.workbench_packet_current(old_packet) THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='analysis_packet_stale'; END IF;
 IF (SELECT count(*) FROM preparation.analysis_packets WHERE plan_id=p.plan_id AND plan_version=p.version)>=(p.followup_limits->>'max_total_packets')::integer THEN RAISE EXCEPTION USING ERRCODE='54000',MESSAGE='plan_packet_limit'; END IF;
 -- This is a separately authorized paid retry, not a residual-analysis followup.
 -- The old reservation remains held/uncertain and is included in dispatch caps.
 manifest:=old.manifest||jsonb_build_object('packet_id',packet,'stage','explicit_uncertain_retry','predecessor_packet_ids',jsonb_build_array(old_packet));
 request:=old.request_body||jsonb_build_object('packet_key',packet);
 INSERT INTO preparation.analysis_packets VALUES(packet,p.plan_id,p.version,old.task,'explicit_uncertain_retry',manifest,old.data,request);
 PERFORM preparation.enqueue_workbench_packet(packet);
 INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(p.plan_id,p.version,'previewed',jsonb_build_object('operation','explicit_uncertain_retry','old_packet_id',old_packet,'new_packet_id',packet,'actor_id',preparation.actor()));
 RETURN preparation.receipt(wid,'retry_uncertain_analysis_packet',body,key,jsonb_build_object('packet_id',packet,'old_packet_id',old_packet,'old_reservation','held','coverage',preparation.read_analysis_coverage(wid,p.plan_id,p.version)));
END $$;

CREATE FUNCTION preparation.cancel_analysis_plan(wid uuid,pid uuid,pversion bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); result jsonb; body jsonb:=jsonb_build_object('plan_id',pid,'version',pversion);
BEGIN
 result:=preparation.replay(wid,'cancel_analysis_plan',body,key); IF result IS NOT NULL THEN RETURN result; END IF;
 IF NOT EXISTS(SELECT FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid) THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 UPDATE preparation.jobs j SET state='cancelled',cancelled_at=clock_timestamp() FROM preparation.packet_jobs q,preparation.analysis_packets a WHERE j.id=q.job_id AND q.packet_id=a.packet_id AND a.plan_id=pid AND a.plan_version=pversion AND j.state IN ('queued','leased','running','uncertain');
 INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES(pid,pversion,'blocked',jsonb_build_object('code','plan_cancelled','actor_id',preparation.actor()));
 RETURN preparation.receipt(wid,'cancel_analysis_plan',body,key,preparation.read_analysis_coverage(wid,pid,pversion));
END $$;

CREATE FUNCTION preparation.amend_analysis_plan(wid uuid,pid uuid,pversion bigint,selection uuid[],configuration text,limits jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); result jsonb;
BEGIN
 IF NOT EXISTS(SELECT FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid) THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 result:=preparation.preview_analysis_plan(wid,selection,configuration,limits,key);
 IF (result->>'plan_id')::uuid=pid THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='amendment_requires_new_plan_identity'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=(result->>'plan_id')::uuid AND body->>'operation'='amended_from') THEN
  INSERT INTO preparation.plan_events(plan_id,plan_version,kind,body) VALUES((result->>'plan_id')::uuid,(result->>'version')::bigint,'previewed',jsonb_build_object('operation','amended_from','plan_id',pid,'plan_version',pversion)); END IF;
 RETURN preparation.read_analysis_plan(wid,(result->>'plan_id')::uuid,(result->>'version')::bigint);
END $$;
REVOKE ALL ON FUNCTION preparation.retry_uncertain_analysis_packet(uuid,uuid,uuid),preparation.cancel_analysis_plan(uuid,uuid,bigint,uuid),preparation.amend_analysis_plan(uuid,uuid,bigint,uuid[],text,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.retry_uncertain_analysis_packet(uuid,uuid,uuid),preparation.cancel_analysis_plan(uuid,uuid,bigint,uuid),preparation.amend_analysis_plan(uuid,uuid,bigint,uuid[],text,jsonb,uuid) TO egi_editorial;

CREATE OR REPLACE FUNCTION preparation.read_analysis_plan(wid uuid,pid uuid,pversion bigint,packet_offset integer DEFAULT 0,page_size integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p preparation.analysis_plans; result jsonb;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR packet_offset IS NULL OR page_size NOT BETWEEN 1 AND 100 OR packet_offset NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_plan_page'; END IF;
 SELECT * INTO p FROM preparation.analysis_plans WHERE workspace_id=wid AND plan_id=pid AND version=pversion;
 IF p.plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='plan_not_found'; END IF;
 SELECT COALESCE(jsonb_agg(x.manifest ORDER BY x.packet_id),'[]') INTO result FROM
  (SELECT packet_id,manifest FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion ORDER BY packet_id LIMIT page_size OFFSET packet_offset) x;
 RETURN (to_jsonb(p)-'eligible_snapshot'-'comparison_seed')||jsonb_build_object('shared_context',(SELECT body FROM preparation.shared_contexts WHERE context_id=p.context_id),
  'selection_manifest_digest',p.selection_digest,
  'initial_packet_ids',(SELECT COALESCE(jsonb_agg(packet_id ORDER BY packet_id),'[]') FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion AND stage='initial'),
  'packets',result,'total_packets',(SELECT count(*) FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion),
  'preparation_id',p.workspace_id,
  'configuration',(SELECT jsonb_build_object('version',version,'model',provider_config->>'model','provider',provider_config->>'provider','max_input_tokens',max_input_tokens,'max_output_tokens',max_output_tokens,'input_rate_microusd_per_million',input_rate_microusd_per_million,'output_rate_microusd_per_million',output_rate_microusd_per_million,'price_reference',price_reference,'verified_at',verified_at) FROM preparation.ai_configurations WHERE version=p.configuration_version),
  'packet_jobs',(SELECT COALESCE(jsonb_agg(jsonb_build_object('packet_id',a.packet_id,'job_id',j.id,'state',j.state,'diagnostics',j.diagnostics) ORDER BY a.packet_id),'[]') FROM (SELECT packet_id FROM preparation.analysis_packets WHERE plan_id=pid AND plan_version=pversion ORDER BY packet_id LIMIT page_size OFFSET packet_offset) a LEFT JOIN preparation.packet_jobs q USING(packet_id) LEFT JOIN preparation.jobs j ON j.id=q.job_id),
  'total_events',(SELECT count(*) FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion),
  'last_event_id',(SELECT max(event_id) FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion),
  'events',(SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id',event_id,'kind',kind,'body',body) ORDER BY event_id),'[]') FROM (SELECT * FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion ORDER BY event_id LIMIT 100) e),
  'next_event_id',(SELECT CASE WHEN count(*)>100 THEN (SELECT event_id FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion ORDER BY event_id LIMIT 1 OFFSET 99) END FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion));
END $$;
ALTER FUNCTION preparation.read_workspace(uuid) RENAME TO read_workspace_before_workbench;
CREATE FUNCTION preparation.read_analysis_events(wid uuid,pid uuid,pversion bigint,after_event bigint DEFAULT 0,page_size integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; last_id bigint;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR after_event IS NULL OR page_size NOT BETWEEN 1 AND 100 OR after_event<0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_event_page'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid) THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_plan_not_found'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id',event_id,'kind',kind,'body',body,'created_at',created_at) ORDER BY event_id),'[]'),max(event_id) INTO result,last_id FROM (SELECT * FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND event_id>after_event ORDER BY event_id LIMIT page_size) e;
 RETURN jsonb_build_object('events',result,'total_events',(SELECT count(*) FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion),'next_event_id',CASE WHEN EXISTS(SELECT FROM preparation.plan_events WHERE plan_id=pid AND plan_version=pversion AND event_id>last_id) THEN last_id END);
END $$;
CREATE FUNCTION preparation.read_analysis_record_results(wid uuid,pid uuid,pversion bigint,item uuid,result_offset integer DEFAULT 0,page_size integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; total bigint;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR result_offset IS NULL OR page_size NOT BETWEEN 1 AND 100 OR result_offset<0 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_result_page'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.analysis_plans WHERE plan_id=pid AND version=pversion AND workspace_id=wid AND selection @> jsonb_build_array(jsonb_build_object('record_key',item::text))) THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='analysis_record_not_found'; END IF;
 SELECT count(*) INTO total FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND r.record_key=item::text AND jsonb_array_length(r.processed_basis_keys)>0;
 SELECT COALESCE(jsonb_agg(to_jsonb(page)),'[]') INTO result FROM (SELECT r.* FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets a USING(packet_id) WHERE a.plan_id=pid AND a.plan_version=pversion AND r.record_key=item::text AND jsonb_array_length(r.processed_basis_keys)>0 ORDER BY r.packet_id,r.unit_key LIMIT page_size OFFSET result_offset) page;
 RETURN jsonb_build_object('results',result,'total_results',total,'next_result_offset',CASE WHEN result_offset+page_size<total THEN result_offset+page_size END);
END $$;
REVOKE ALL ON FUNCTION preparation.read_analysis_events(uuid,uuid,bigint,bigint,integer),preparation.read_analysis_record_results(uuid,uuid,bigint,uuid,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.read_analysis_events(uuid,uuid,bigint,bigint,integer),preparation.read_analysis_record_results(uuid,uuid,bigint,uuid,integer,integer) TO egi_editorial;
CREATE OR REPLACE FUNCTION preparation.read_workspace_before_workbench(id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb:=preparation.read_workspace_initial(id); summaries jsonb;
BEGIN
 SELECT COALESCE(jsonb_agg(jsonb_build_object('job_id',j.id,'input_id',j.input_id,'config_version',j.config_version,
  'state',j.state,'created_at',j.created_at,'diagnostics',j.diagnostics) ORDER BY j.created_at,j.id),'[]') INTO summaries
  FROM preparation.jobs j WHERE j.workspace_id=read_workspace_before_workbench.id;
 RETURN jsonb_set(r,'{jobs}',summaries);
END $$;
CREATE FUNCTION preparation.read_workspace(wid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_column
DECLARE result jsonb:=preparation.read_workspace_before_workbench(wid); latest jsonb;
BEGIN
 SELECT jsonb_build_object('plan_id',plan_id,'version',version,'snapshot_key',snapshot_key,'created_at',created_at) INTO latest FROM preparation.analysis_plans WHERE workspace_id=wid ORDER BY created_at DESC,plan_id DESC,version DESC LIMIT 1;
 RETURN result||jsonb_build_object('latest_analysis_plan',latest);
END $$;

ALTER FUNCTION preparation.purge_job_payloads(uuid) RENAME TO purge_job_payloads_before_coverage;
CREATE FUNCTION preparation.purge_job_payloads(wid uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NOT preparation.retention_login() OR NOT EXISTS(SELECT FROM preparation.workspaces WHERE id=wid AND state IN ('trash','purged') AND trashed_at<=clock_timestamp()-interval '30 days') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='expired_retention_workspace_required'; END IF;
 DELETE FROM preparation.workbench_unit_results r USING preparation.analysis_packets a,preparation.analysis_plans p WHERE r.packet_id=a.packet_id AND a.plan_id=p.plan_id AND a.plan_version=p.version AND p.workspace_id=wid;
 PERFORM preparation.purge_job_payloads_before_coverage(wid);
END $$;
REVOKE ALL ON FUNCTION preparation.purge_job_payloads(uuid),preparation.purge_job_payloads_before_coverage(uuid),preparation.read_workspace_before_workbench(uuid),preparation.select_workbench_result(uuid,uuid,uuid,uuid,jsonb,uuid,boolean),preparation.select_workbench_proposals(uuid,uuid,uuid,uuid,jsonb,uuid),preparation.select_workbench_hypotheses(uuid,uuid,uuid,uuid,jsonb,uuid),preparation.read_workspace(uuid) FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
GRANT EXECUTE ON FUNCTION preparation.select_workbench_proposals(uuid,uuid,uuid,uuid,jsonb,uuid),preparation.select_workbench_hypotheses(uuid,uuid,uuid,uuid,jsonb,uuid),preparation.read_workspace(uuid) TO egi_editorial;

REVOKE ALL ON FUNCTION preparation.read_analysis_coverage(uuid,uuid,bigint,integer,integer),preparation.continue_analysis_plan(uuid,uuid,bigint,uuid),preparation.schedule_workbench_comparison(uuid,bigint),preparation.auto_workbench_comparison() FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
GRANT EXECUTE ON FUNCTION preparation.read_analysis_coverage(uuid,uuid,bigint,integer,integer),preparation.continue_analysis_plan(uuid,uuid,bigint,uuid) TO egi_editorial;
REVOKE ALL ON FUNCTION preparation.finish_job_text(uuid,uuid,text,jsonb,jsonb),preparation.reconcile_workbench_result(preparation.analysis_packets,jsonb),preparation.workbench_codes(jsonb),preparation.claim_job_text(uuid),preparation.start_dispatch_text(uuid,text),preparation.validate_job_result_text(preparation.jobs,jsonb),preparation.validate_job_result(preparation.jobs,jsonb),preparation.workbench_packet_current(uuid),preparation.enqueue_workbench_packet(uuid),preparation.validate_workbench_result(preparation.analysis_packets,jsonb),preparation.persist_workbench_units() FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
REVOKE ALL ON FUNCTION preparation.finish_job(uuid,uuid,text,jsonb,jsonb),preparation.start_analysis_plan(uuid,uuid,bigint,uuid),preparation.claim_job(uuid),preparation.start_dispatch(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.start_analysis_plan(uuid,uuid,bigint,uuid) TO egi_editorial;
GRANT EXECUTE ON FUNCTION preparation.finish_job(uuid,uuid,text,jsonb,jsonb),preparation.claim_job(uuid),preparation.start_dispatch(uuid,text) TO egi_preparation_worker;
COMMIT;
