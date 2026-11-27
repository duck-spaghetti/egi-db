-- Deploy egi_database:027_preparation_category_matches
-- requires: 026_community_reference_acceptance
-- EGI-117 provider completion for EGI-118's optional same-exchange suggestions.
BEGIN;
CREATE FUNCTION preparation.canonical_json(value jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE jsonb_typeof(value)
  WHEN 'object' THEN '{'||COALESCE((SELECT string_agg(to_jsonb(k)::text||':'||preparation.canonical_json(v),',' ORDER BY k COLLATE "C") FROM jsonb_each(value) x(k,v)),'')||'}'
  WHEN 'array' THEN '['||COALESCE((SELECT string_agg(preparation.canonical_json(v),',' ORDER BY n) FROM jsonb_array_elements(value) WITH ORDINALITY x(v,n)),'')||']'
  ELSE value::text END
$$;

-- The immutable environment configuration may supply only actual published
-- adopted labels. Check before insertion, before dispatch and before persistence.
CREATE FUNCTION preparation.validate_matching_context(context jsonb) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE entry jsonb; target jsonb; scope jsonb:=context->'context'; adoption taxonomy.territory_adoptions; actual_label text; parents jsonb; as_of date;
BEGIN
 PERFORM preparation.closed(context,ARRAY['schema_version','kind','context','as_of','entries','complete','digest'],ARRAY['schema_version','kind','context','as_of','entries','complete','digest']);
 PERFORM preparation.closed(scope,ARRAY['territory_id','axis_id'],ARRAY['territory_id','axis_id']);
 IF context->'schema_version' IS DISTINCT FROM '1'::jsonb OR context->>'kind' IS DISTINCT FROM 'classification' OR
  jsonb_typeof(context->'complete') IS DISTINCT FROM 'boolean' OR jsonb_typeof(context->'entries') IS DISTINCT FROM 'array' OR
  jsonb_array_length(context->'entries')>100 OR COALESCE(context->>'as_of','') !~ '^\d{4}-\d{2}-\d{2}$' OR
  context->>'digest' IS DISTINCT FROM encode(sha256(convert_to(preparation.canonical_json(context-'digest'),'UTF8')),'hex') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_matching_context'; END IF;
 as_of:=(context->>'as_of')::date;
 IF as_of>current_date OR NOT EXISTS(SELECT FROM taxonomy.axes WHERE axis_id=(scope->>'axis_id')::uuid) OR
  NOT EXISTS(SELECT FROM geo.territories WHERE entity_id=(scope->>'territory_id')::uuid) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_matching_context'; END IF;
 FOR entry IN SELECT * FROM jsonb_array_elements(context->'entries') LOOP
  PERFORM preparation.closed(entry,ARRAY['candidate_key','label','target','published','active','effective_from','effective_until','broader'],ARRAY['candidate_key','label','target','published','active','effective_from','effective_until','broader']);
  target:=entry->'target';
  PERFORM preparation.closed(target,ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  IF jsonb_typeof(entry->'label') IS DISTINCT FROM 'string' OR length(entry->>'label') NOT BETWEEN 1 AND 4000 OR jsonb_typeof(entry->'candidate_key') IS DISTINCT FROM 'string' OR length(entry->>'candidate_key') NOT BETWEEN 1 AND 100 OR
   entry->'published' IS DISTINCT FROM 'true'::jsonb OR entry->'active' IS DISTINCT FROM 'true'::jsonb OR
   target->>'kind' IS DISTINCT FROM 'classification' OR target->>'axis_id' IS DISTINCT FROM scope->>'axis_id' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_matching_context'; END IF;
  SELECT a.* INTO adoption FROM taxonomy.territory_adoptions a JOIN taxonomy.releases r USING(release_id)
   JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id
   WHERE a.adoption_id=(target->>'adoption_id')::uuid AND a.release_id=(target->>'release_id')::uuid
    AND a.territory_id=(scope->>'territory_id')::uuid AND rt.axis_id=(scope->>'axis_id')::uuid AND rt.term_id=(target->>'term_id')::uuid
    AND a.effective_from<=least(current_date,as_of) AND (a.effective_until IS NULL OR a.effective_until>=greatest(current_date,as_of)) AND r.sealed_at IS NOT NULL AND tr.active;
  IF adoption.adoption_id IS NULL OR entry->>'effective_from' IS DISTINCT FROM adoption.effective_from::text OR
   entry->'effective_until' IS DISTINCT FROM COALESCE(to_jsonb(adoption.effective_until),'null'::jsonb) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='matching_context_stale'; END IF;
  SELECT c.original_text INTO actual_label FROM taxonomy.release_terms rt JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name'
   JOIN i18n.content_units c USING(content_id) WHERE rt.release_id=adoption.release_id AND rt.term_id=(target->>'term_id')::uuid;
  SELECT COALESCE(jsonb_agg(b.parent_term_id ORDER BY b.parent_term_id),'[]') INTO parents FROM taxonomy.broader_links b WHERE b.release_id=adoption.release_id AND b.child_term_id=(target->>'term_id')::uuid;
  IF entry->>'label' IS DISTINCT FROM actual_label OR entry->'broader' IS DISTINCT FROM parents THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='matching_context_stale'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(context->'entries') e GROUP BY e->>'candidate_key' HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(context->'entries') e GROUP BY e->'target' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_matching_context'; END IF;
 IF context->'complete'='true'::jsonb AND jsonb_array_length(context->'entries')<>(SELECT count(*) FROM taxonomy.territory_adoptions a
  JOIN taxonomy.releases r USING(release_id) JOIN taxonomy.release_terms rt USING(release_id) JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id
  WHERE a.territory_id=(scope->>'territory_id')::uuid AND rt.axis_id=(scope->>'axis_id')::uuid AND a.effective_from<=current_date
   AND (a.effective_until IS NULL OR a.effective_until>=current_date) AND r.sealed_at IS NOT NULL AND tr.active) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='matching_context_incomplete'; END IF;
END $$;
CREATE FUNCTION preparation.guard_matching_configuration() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NEW.provider_config ? 'catalog_context' THEN
  IF NEW.provider_config->'interpretation_version' IS DISTINCT FROM '2'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_version_conflict'; END IF;
  PERFORM preparation.validate_matching_context(NEW.provider_config->'catalog_context');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER matching_configuration BEFORE INSERT ON preparation.ai_configurations FOR EACH ROW EXECUTE FUNCTION preparation.guard_matching_configuration();

-- Resolve local candidate/fact keys against the frozen context and the exact
-- materialized literal locators. Nothing here can confirm or populate a service.
CREATE FUNCTION preparation.matching_resolutions(candidate jsonb,payload jsonb,context jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE match jsonb; choice jsonb; entry jsonb; fact jsonb; id uuid; idx integer; source_index integer; r jsonb:='[]'; candidates jsonb; rank integer;
 mapping jsonb:='{}'; used uuid[]:=ARRAY[]::uuid[];
BEGIN
 IF jsonb_typeof(candidate->'matches') IS DISTINCT FROM 'array' OR jsonb_array_length(candidate->'matches')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_category_matches'; END IF;
 FOR fact,source_index IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(candidate->'source_facts') WITH ORDINALITY LOOP
  SELECT p.value->>'fact_id' INTO id FROM jsonb_array_elements(payload->'source_facts') WITH ORDINALITY p
   WHERE p.value->>'kind'=fact->>'kind' AND p.value->>'subject'=fact->>'subject' AND p.value->>'source_value'=fact->>'source_value'
    AND NOT (p.value->>'fact_id')::uuid=ANY(used) AND EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') pe CROSS JOIN jsonb_array_elements(candidate->'evidence') ce
     WHERE pe->>'path'='/source_facts/'||(p.ordinality-1)||'/source_value' AND ce->>'path'='/source_facts/'||source_index||'/source_value'
      AND pe->'input_id'=ce->'input_id' AND pe->'span'=ce->'span' AND pe->'input_hash'=ce->'input_hash' AND pe->'quote'=ce->'quote') ORDER BY p.ordinality LIMIT 1;
  IF id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='matching_fact_not_found'; END IF;
  used:=array_append(used,id); mapping:=mapping||jsonb_build_object(fact->>'fact_key',id);
 END LOOP;
 FOR match IN SELECT * FROM jsonb_array_elements(candidate->'matches') LOOP
  PERFORM preparation.closed(match,ARRAY['fact_key','context_digest','choices'],ARRAY['fact_key','context_digest','choices']);
  SELECT f INTO fact FROM jsonb_array_elements(candidate->'source_facts') f WHERE f->>'fact_key'=match->>'fact_key';
  IF jsonb_typeof(match->'fact_key') IS DISTINCT FROM 'string' OR jsonb_typeof(match->'context_digest') IS DISTINCT FROM 'string' OR fact->>'kind' IS DISTINCT FROM 'category_label' OR fact->>'subject' IS DISTINCT FROM 'service' OR
   match->>'context_digest' IS DISTINCT FROM context->>'digest' OR jsonb_typeof(match->'choices') IS DISTINCT FROM 'array' OR jsonb_array_length(match->'choices')>100 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_category_matches'; END IF;
  candidates:='[]'; rank:=0;
  FOR choice IN SELECT * FROM jsonb_array_elements(match->'choices') LOOP
   PERFORM preparation.closed(choice,ARRAY['candidate_key','reason'],ARRAY['candidate_key','reason']);
   SELECT e INTO entry FROM jsonb_array_elements(context->'entries') e WHERE e->>'candidate_key'=choice->>'candidate_key';
   IF entry IS NULL OR jsonb_typeof(choice->'candidate_key') IS DISTINCT FROM 'string' OR jsonb_typeof(choice->'reason') IS DISTINCT FROM 'string' OR length(btrim(choice->>'reason')) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_category_matches'; END IF;
   rank:=rank+1; candidates:=candidates||jsonb_build_array(jsonb_build_object('target',entry->'target','rank',rank,'reason',choice->'reason'));
  END LOOP;
  IF EXISTS(SELECT FROM jsonb_array_elements(match->'choices') c GROUP BY c->>'candidate_key' HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_category_matches'; END IF;
  r:=r||jsonb_build_array(jsonb_build_object('fact_id',mapping->(match->>'fact_key'),'state',CASE WHEN rank=0 THEN 'unresolved' ELSE 'proposed' END,
   'context',CASE WHEN rank=0 THEN '{}'::jsonb ELSE context->'context' END,'candidates',candidates));
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(candidate->'matches') m GROUP BY m->>'fact_key' HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_category_matches'; END IF;
 RETURN r;
END $$;

ALTER FUNCTION preparation.literal_candidate_payload(jsonb,uuid,uuid) RENAME TO literal_candidate_payload_without_matches;
CREATE FUNCTION preparation.literal_candidate_payload(candidate jsonb,input uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE payload jsonb:=preparation.literal_candidate_payload_without_matches(candidate,input,job); context jsonb;
BEGIN
 IF candidate ? 'matches' THEN
  SELECT c.provider_config->'catalog_context' INTO context FROM preparation.jobs j JOIN preparation.ai_configurations c ON c.version=j.config_version WHERE j.id=job;
  IF context IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unexpected_category_matches'; END IF;
  PERFORM preparation.validate_matching_context(context);
  payload:=jsonb_set(payload,'{resolutions}',preparation.matching_resolutions(candidate,payload,context));
 END IF;
 RETURN payload;
END $$;
ALTER FUNCTION preparation.validate_job_result(preparation.jobs,jsonb) RENAME TO validate_job_result_without_matches;
CREATE FUNCTION preparation.validate_job_result(j preparation.jobs,result jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb; c jsonb; stripped jsonb:='[]'; proxy jsonb;
BEGIN
 SELECT provider_config->'catalog_context' INTO context FROM preparation.ai_configurations WHERE version=j.config_version;
 IF context IS NULL THEN PERFORM preparation.validate_job_result_without_matches(j,result); RETURN; END IF;
 PERFORM preparation.validate_matching_context(context);
 FOR c IN SELECT * FROM jsonb_array_elements(result->'candidates') LOOP stripped:=stripped||jsonb_build_array(c-'matches'); END LOOP;
 proxy:=jsonb_set(result,'{candidates}',stripped);
 PERFORM preparation.validate_job_result_without_matches(j,proxy);
 FOR c IN SELECT * FROM jsonb_array_elements(result->'candidates') LOOP
  PERFORM preparation.closed(c,ARRAY['candidate_key','service','location','evidence','diagnostics','source_facts','matches'],ARRAY['candidate_key','service','location','evidence','diagnostics','source_facts','matches']);
  PERFORM preparation.validate_payload(j.workspace_id,preparation.literal_candidate_payload(c,j.input_id,j.id));
 END LOOP;
END $$;
ALTER FUNCTION preparation.merge_candidate(jsonb,jsonb,uuid,uuid) RENAME TO merge_candidate_without_matches;
CREATE FUNCTION preparation.merge_candidate(old jsonb,candidate jsonb,input uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE merged jsonb:=preparation.merge_candidate_without_matches(old,candidate,input,job); payload jsonb:=merged->'payload'; context jsonb; r jsonb; resolutions jsonb:=COALESCE(payload->'resolutions','[]'); idx integer;
BEGIN
 IF NOT candidate ? 'matches' THEN RETURN merged; END IF;
 SELECT c.provider_config->'catalog_context' INTO context FROM preparation.jobs j JOIN preparation.ai_configurations c ON c.version=j.config_version WHERE j.id=job;
 FOR r IN SELECT * FROM jsonb_array_elements(preparation.matching_resolutions(candidate,payload,context)) LOOP
  SELECT n::integer-1 INTO idx FROM jsonb_array_elements(payload->'source_facts') WITH ORDINALITY x(f,n) WHERE f->>'fact_id'=r->>'fact_id';
  IF payload#>>ARRAY['field_origins','/source_facts/'||idx||'/value','state'] IN ('manual','cleared') OR
   EXISTS(SELECT FROM jsonb_array_elements(resolutions) prior WHERE prior->>'fact_id'=r->>'fact_id' AND prior->>'state' IN ('confirmed','ignored')) THEN CONTINUE; END IF;
  SELECT COALESCE(jsonb_agg(prior),'[]') INTO resolutions FROM jsonb_array_elements(resolutions) prior WHERE prior->>'fact_id'<>r->>'fact_id';
  resolutions:=resolutions||jsonb_build_array(r);
 END LOOP;
 RETURN jsonb_set(merged,'{payload,resolutions}',resolutions);
END $$;
REVOKE ALL ON FUNCTION preparation.canonical_json(jsonb),preparation.validate_matching_context(jsonb),preparation.guard_matching_configuration(),preparation.matching_resolutions(jsonb,jsonb,jsonb),
 preparation.literal_candidate_payload_without_matches(jsonb,uuid,uuid),preparation.literal_candidate_payload(jsonb,uuid,uuid),
 preparation.validate_job_result_without_matches(preparation.jobs,jsonb),preparation.validate_job_result(preparation.jobs,jsonb),
 preparation.merge_candidate_without_matches(jsonb,jsonb,uuid,uuid),preparation.merge_candidate(jsonb,jsonb,uuid,uuid) FROM PUBLIC,egi_editorial,egi_retention,egi_preparation_worker;
CREATE OR REPLACE FUNCTION preparation.start_dispatch(job uuid,lease text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j preparation.jobs; w preparation.workspaces; config preparation.ai_configurations; eligible jsonb;
 period date:=date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC')::date; ceiling bigint; ledger preparation.budget_periods; dispatch uuid;
BEGIN
 PERFORM preparation.require_worker();
 SELECT * INTO w FROM preparation.workspaces WHERE id=(SELECT workspace_id FROM preparation.jobs WHERE id=job) FOR UPDATE;
 j:=preparation.leased_job(job,lease);
 IF j.state<>'leased' OR j.dispatch_id IS NOT NULL OR j.lease_expires_at<=clock_timestamp() THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='job_not_dispatchable'; END IF;
 IF NOT preparation.requester_authorized(j.workspace_id,j.requester_actor_id) OR w.current_input_id IS DISTINCT FROM j.input_id THEN
  UPDATE preparation.jobs SET state='cancelled',eligible_payload=NULL,locator_map=NULL,diagnostics='[{"code":"access_or_input_changed"}]' WHERE id=job;
  RETURN jsonb_build_object('state','cancelled'); END IF;
 SELECT * INTO config FROM preparation.ai_configurations WHERE version=j.config_version;
 IF config.provider_config ? 'catalog_context' THEN
  BEGIN PERFORM preparation.validate_matching_context(config.provider_config->'catalog_context');
  EXCEPTION WHEN data_exception THEN
   UPDATE preparation.jobs SET state='failed',diagnostics='[{"code":"catalog_context_changed"}]' WHERE id=job;
   RETURN jsonb_build_object('state','failed','code','catalog_context_changed');
  END;
 END IF;
 IF NOT EXISTS(SELECT FROM preparation.ai_settings WHERE enabled AND config_version=j.config_version) THEN
  UPDATE preparation.jobs SET state='failed',diagnostics='[{"code":"ai_configuration_changed"}]' WHERE id=job;
  RETURN jsonb_build_object('state','failed','code','ai_configuration_changed'); END IF;
 eligible:=preparation.eligible_input(j.workspace_id,j.input_id);
 IF eligible-'locator_map' IS DISTINCT FROM j.eligible_payload OR eligible->'locator_map' IS DISTINCT FROM j.locator_map THEN
  UPDATE preparation.jobs SET state='failed',diagnostics='[{"code":"eligibility_changed"}]' WHERE id=job;
  RETURN jsonb_build_object('state','failed','code','eligibility_changed'); END IF;
 ceiling:=ceil((config.max_input_tokens::numeric*config.input_rate_microusd_per_million+
  config.max_output_tokens::numeric*config.output_rate_microusd_per_million)/1000000)::bigint;
 INSERT INTO preparation.budget_periods(period_start) VALUES(period) ON CONFLICT DO NOTHING;
 SELECT * INTO ledger FROM preparation.budget_periods WHERE period_start=period FOR UPDATE;
 IF ceiling>ledger.limit_microusd-ledger.committed_microusd-ledger.reserved_microusd THEN
  UPDATE preparation.jobs SET state='failed',diagnostics='[{"code":"budget_exceeded"}]' WHERE id=job;
  RETURN jsonb_build_object('state','failed','code','budget_exceeded'); END IF;
 UPDATE preparation.budget_periods SET reserved_microusd=reserved_microusd+ceiling WHERE period_start=period;
 INSERT INTO preparation.budget_reservations(job_id,period_start,ceiling_microusd,state) VALUES(job,period,ceiling,'reserved');
 dispatch:=gen_random_uuid();
 UPDATE preparation.jobs SET state='running',dispatch_id=dispatch,dispatched_at=clock_timestamp() WHERE id=job;
 RETURN jsonb_build_object('state','running','dispatch_id',dispatch,'ceiling_microusd',ceiling,'provider_config',config.provider_config,
  'max_input_tokens',config.max_input_tokens,'max_output_tokens',config.max_output_tokens);
END $$;
CREATE OR REPLACE FUNCTION preparation.guard_source_fact_version() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE wid uuid; previous jsonb; op text; fact jsonb; identity preparation.fact_identities; evidence_input uuid; idx integer;
BEGIN
 SELECT i.workspace_id,v.payload INTO wid,previous FROM preparation.items i
  LEFT JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.id=NEW.item_id;
 IF previous->'schema_version'='2'::jsonb AND NEW.payload->'schema_version'='1'::jsonb THEN
  SELECT kind INTO op FROM preparation.operations WHERE id=NEW.operation_id;
  IF op='undo' THEN NEW.payload:=NEW.payload||'{"schema_version":2,"source_facts":[],"resolutions":[]}';
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='item_schema_downgrade'; END IF;
 END IF;
 IF NEW.payload->'schema_version'='2'::jsonb THEN
  PERFORM preparation.validate_payload(wid,NEW.payload);
  FOR fact,idx IN SELECT value,ordinality::integer-1 FROM jsonb_array_elements(NEW.payload->'source_facts') WITH ORDINALITY LOOP
   SELECT (e->>'input_id')::uuid INTO evidence_input FROM jsonb_array_elements(NEW.payload->'evidence') e
    WHERE e->>'path'='/source_facts/'||idx||'/source_value' LIMIT 1;
   INSERT INTO preparation.fact_identities(fact_id,item_id,input_id,subject,kind,source_value)
    VALUES((fact->>'fact_id')::uuid,NEW.item_id,evidence_input,fact->>'subject',fact->>'kind',fact->>'source_value') ON CONFLICT DO NOTHING;
   SELECT * INTO identity FROM preparation.fact_identities WHERE fact_id=(fact->>'fact_id')::uuid;
   IF identity.item_id<>NEW.item_id OR identity.subject<>fact->>'subject' OR identity.kind<>fact->>'kind' OR identity.source_value<>fact->>'source_value' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_identity_conflict'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements(NEW.payload->'resolutions') r WHERE r->>'fact_id'=fact->>'fact_id' AND r->>'state' IN ('confirmed','proposed')) AND
    EXISTS(SELECT FROM jsonb_array_elements(previous->'source_facts') p WHERE p->>'fact_id'=fact->>'fact_id' AND p->'value' IS DISTINCT FROM fact->'value') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_resolution_stale'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
COMMIT;
