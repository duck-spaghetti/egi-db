-- Revert egi_database:027_preparation_category_matches
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT FROM preparation.ai_configurations WHERE provider_config ? 'catalog_context') THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='category_matching_protocol_in_use'; END IF;
END $$;
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
DROP TRIGGER matching_configuration ON preparation.ai_configurations;
DROP FUNCTION preparation.guard_matching_configuration();
DROP FUNCTION preparation.validate_job_result(preparation.jobs,jsonb);
ALTER FUNCTION preparation.validate_job_result_without_matches(preparation.jobs,jsonb) RENAME TO validate_job_result;
DROP FUNCTION preparation.merge_candidate(jsonb,jsonb,uuid,uuid);
ALTER FUNCTION preparation.merge_candidate_without_matches(jsonb,jsonb,uuid,uuid) RENAME TO merge_candidate;
DROP FUNCTION preparation.literal_candidate_payload(jsonb,uuid,uuid);
ALTER FUNCTION preparation.literal_candidate_payload_without_matches(jsonb,uuid,uuid) RENAME TO literal_candidate_payload;
DROP FUNCTION preparation.matching_resolutions(jsonb,jsonb,jsonb),preparation.validate_matching_context(jsonb);
DROP FUNCTION preparation.canonical_json(jsonb);
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
   IF EXISTS(SELECT FROM jsonb_array_elements(NEW.payload->'resolutions') r WHERE r->>'fact_id'=fact->>'fact_id' AND r->>'state'='confirmed') AND
    EXISTS(SELECT FROM jsonb_array_elements(previous->'source_facts') p WHERE p->>'fact_id'=fact->>'fact_id' AND p->'value' IS DISTINCT FROM fact->'value') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_fact_resolution_stale'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
COMMIT;
