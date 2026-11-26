-- Deploy egi_database:017_preparation_jobs
-- requires: 016_community_sources
-- EGI-103: one-dispatch leases, conservative public payloads and a USD 10 ledger.
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_preparation_worker') THEN CREATE ROLE egi_preparation_worker NOLOGIN; END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='egi_preparation_worker' AND
  (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)) OR
  pg_has_role('egi_preparation_worker','egi_editorial','MEMBER') OR
  pg_has_role('egi_preparation_worker','egi_writer','MEMBER') OR
  pg_has_role('egi_preparation_worker','egi_reader','MEMBER') OR
  EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='egi_preparation_worker')) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='preparation_worker_not_isolated'; END IF;
END $$;
-- Environment-owned frozen configurations. No real model, price or dispatch
-- authorization is seeded. Fixture configurations never authorize provider calls.
CREATE TABLE preparation.ai_configurations (
 version text PRIMARY KEY CHECK(length(version) BETWEEN 1 AND 100),
 provider_config jsonb NOT NULL CHECK(jsonb_typeof(provider_config)='object'),
 max_input_tokens bigint NOT NULL CHECK(max_input_tokens>0),
 max_output_tokens bigint NOT NULL CHECK(max_output_tokens>0),
 input_rate_microusd_per_million bigint NOT NULL CHECK(input_rate_microusd_per_million>=0),
 cached_rate_microusd_per_million bigint NOT NULL CHECK(cached_rate_microusd_per_million>=0),
 output_rate_microusd_per_million bigint NOT NULL CHECK(output_rate_microusd_per_million>=0),
 verified_at timestamptz NOT NULL,
 price_reference text NOT NULL CHECK(btrim(price_reference)<>''),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(cached_rate_microusd_per_million<=input_rate_microusd_per_million)
);
CREATE TRIGGER configurations_immutable BEFORE UPDATE OR DELETE ON preparation.ai_configurations
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE TABLE preparation.ai_settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 config_version text NOT NULL REFERENCES preparation.ai_configurations,
 enabled boolean NOT NULL DEFAULT false
);
CREATE TABLE preparation.jobs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 input_id uuid,
 requester_actor_id uuid NOT NULL REFERENCES governance.actors,
 task text NOT NULL CHECK(task IN ('extract_text','map_csv')),
 config_version text NOT NULL REFERENCES preparation.ai_configurations,
 request_key uuid NOT NULL,
 state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','leased','running','succeeded','failed','uncertain','cancelled')),
 lease_hash text,
 lease_expires_at timestamptz,
 lease_login name,
 worker_id uuid,
 dispatch_id uuid UNIQUE,
 eligible_payload jsonb,
 locator_map jsonb,
 eligibility_policy_version text NOT NULL DEFAULT 'public-contacts-v1',
 output jsonb,
 candidate_ids jsonb NOT NULL DEFAULT '{}',
 diagnostics jsonb NOT NULL DEFAULT '[]',
 usage jsonb,
 completion_digest text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 dispatched_at timestamptz,
 finished_at timestamptz,
 cancelled_at timestamptz,
 UNIQUE(workspace_id,requester_actor_id,request_key),
 FOREIGN KEY(input_id,workspace_id) REFERENCES preparation.inputs(id,workspace_id)
);
CREATE INDEX jobs_queue ON preparation.jobs(created_at,id) WHERE state='queued';
CREATE INDEX jobs_workspace ON preparation.jobs(workspace_id,created_at);
CREATE TABLE preparation.budget_periods (
 period_start date PRIMARY KEY CHECK(extract(day FROM period_start)=1),
 currency text NOT NULL DEFAULT 'USD' CHECK(currency='USD'),
 limit_microusd bigint NOT NULL DEFAULT 10000000 CHECK(limit_microusd=10000000),
 committed_microusd bigint NOT NULL DEFAULT 0 CHECK(committed_microusd>=0),
 reserved_microusd bigint NOT NULL DEFAULT 0 CHECK(reserved_microusd>=0),
 CHECK(committed_microusd+reserved_microusd<=limit_microusd)
);
CREATE TABLE preparation.budget_reservations (
 job_id uuid PRIMARY KEY REFERENCES preparation.jobs,
 period_start date NOT NULL REFERENCES preparation.budget_periods,
 ceiling_microusd bigint NOT NULL CHECK(ceiling_microusd>=0),
 settled_microusd bigint CHECK(settled_microusd>=0 AND settled_microusd<=ceiling_microusd),
 state text NOT NULL CHECK(state IN ('reserved','settled','uncertain')),
 CHECK((state='settled')=(settled_microusd IS NOT NULL))
);

CREATE FUNCTION preparation.worker_login() RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles u ON u.oid=m.member
  WHERE g.rolname='egi_preparation_worker' AND u.rolname=session_user AND u.rolcanlogin
   AND NOT (u.rolsuper OR u.rolcreaterole OR u.rolcreatedb OR u.rolreplication OR u.rolbypassrls))
  AND NOT EXISTS(SELECT FROM pg_auth_members extra JOIN pg_roles parent ON parent.oid=extra.roleid
   JOIN pg_roles login ON login.oid=extra.member WHERE login.rolname=session_user AND parent.rolname<>'egi_preparation_worker')
  AND NOT pg_has_role(session_user,'egi_editorial','MEMBER') AND NOT pg_has_role(session_user,'egi_writer','MEMBER')
  AND NOT pg_has_role(session_user,'egi_reader','MEMBER') AND NOT pg_has_role(session_user,'egi_sync','MEMBER')
  AND NOT pg_has_role(session_user,'egi_intake','MEMBER') AND NOT pg_has_role(session_user,'egi_retention','MEMBER') AND NOT pg_has_role(session_user,'egi_privacy_moderator','MEMBER')
$$;
CREATE FUNCTION preparation.require_worker() RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NOT preparation.worker_login() THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='worker_login_required'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='write_requires_read_committed'; END IF;
END $$;
CREATE FUNCTION preparation.requester_authorized(wid uuid,actor uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM preparation.workspaces w
  JOIN access.accounts owner ON owner.actor_id=w.owner_actor_id AND owner.state='active'
  JOIN governance.actors own ON own.actor_id=owner.actor_id AND own.enabled
  JOIN access.accounts requester ON requester.actor_id=actor AND requester.state='active'
  JOIN governance.actors person ON person.actor_id=requester.actor_id AND person.enabled
  WHERE w.id=wid AND w.state='active' AND (w.owner_actor_id=actor OR EXISTS(
   SELECT FROM preparation.grants g WHERE g.workspace_id=wid AND g.actor_id=actor AND permission='edit')))
$$;

-- Redaction preserves code-point offsets by replacing removed text with spaces.
-- Use the existing phone identity/hold rules, never a second phone normalizer.
CREATE FUNCTION preparation.redact_text(wid uuid,text_value text) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE probe text; redacted text; spans jsonb:='[]'; token text; pos integer; scan integer;
 keys text[]; protected text[]; holds boolean; value text; matched boolean; token_row record;
BEGIN
 redacted:=text_value;
 SELECT COALESCE(string_agg(CASE WHEN governance.protection_phone_whitespace(ch)='' THEN ' ' ELSE ch END,'' ORDER BY ord),'')
  INTO probe FROM regexp_split_to_table(text_value,'') WITH ORDINALITY AS c(ch,ord);
 SELECT COALESCE(array_agg(DISTINCT key),ARRAY[]::text[]) INTO protected FROM (
  SELECT p.number_key AS key FROM governance.contact_protections p WHERE p.kind='number'
   AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.protection_id=p.protection_id AND r.scope_id IS NULL)
   AND EXISTS(SELECT FROM governance.contact_protection_scopes s WHERE s.protection_id=p.protection_id
    AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id))
  UNION SELECT unnest(governance.protection_phone_keys(c.value)) FROM data.contact_entries c
   WHERE NOT c.is_public AND EXISTS(SELECT FROM governance.working_heads h WHERE h.revision_id=c.revision_id
    UNION ALL SELECT FROM governance.published_heads h WHERE h.revision_id=c.revision_id)
  UNION SELECT unnest(governance.protection_phone_keys(c->>'value'))
   FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id
   CROSS JOIN LATERAL jsonb_array_elements(COALESCE(v.payload#>'{service,contacts}','[]')||COALESCE(v.payload#>'{location,body,contacts}','[]')) c
   WHERE i.workspace_id=wid AND c->'is_public'='false'::jsonb
 ) numbers;
 SELECT EXISTS(SELECT FROM governance.contact_protections p WHERE p.kind='phone_hold'
   AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.protection_id=p.protection_id AND r.scope_id IS NULL)
   AND EXISTS(SELECT FROM governance.contact_protection_scopes s WHERE s.protection_id=p.protection_id
    AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id))) OR
  EXISTS(SELECT FROM data.contact_entries c WHERE NOT c.is_public AND governance.protection_phone_uncertain(c.channel_type,c.value,NULL)
   AND EXISTS(SELECT FROM governance.working_heads h WHERE h.revision_id=c.revision_id
    UNION ALL SELECT FROM governance.published_heads h WHERE h.revision_id=c.revision_id)) INTO holds;
 -- Token iteration retains original positions; even repeated phone strings are
 -- redacted independently. A global unresolved hold conservatively removes phones.
 scan:=1;
 FOR token_row IN SELECT regexp_matches(probe,'[+0-9][0-9 ()/.\t\r\n-]{2,}','g') AS parts LOOP
  token:=token_row.parts[1]; pos:=scan-1+strpos(substr(probe,scan),token);
  scan:=pos+length(token);
  keys:=governance.protection_phone_keys(substr(text_value,pos,length(token)));
  matched:=keys && protected OR (holds AND (cardinality(keys)>0 OR governance.protection_phone_uncertain('other',token,'Telefono')));
  IF NOT matched THEN
   matched:=EXISTS(SELECT FROM unnest(protected) k WHERE strpos(regexp_replace(token,'[^0-9]','','g'),k)>0);
  END IF;
  IF matched THEN
   redacted:=overlay(redacted PLACING repeat(' ',length(token)) FROM pos FOR length(token));
   spans:=spans||jsonb_build_array(jsonb_build_object('start',pos-1,'end',pos-1+length(token)));
  END IF;
 END LOOP;
 -- Exact non-phone private values and operator-marked private card values are
 -- removed too. Phone variants above use the authoritative identity functions.
 FOR value IN
  SELECT DISTINCT c.value FROM data.contact_entries c WHERE NOT c.is_public AND length(c.value)>0
   AND EXISTS(SELECT FROM governance.working_heads h WHERE h.revision_id=c.revision_id
    UNION ALL SELECT FROM governance.published_heads h WHERE h.revision_id=c.revision_id)
  UNION SELECT c->>'value' FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id
   CROSS JOIN LATERAL jsonb_array_elements(COALESCE(v.payload#>'{service,contacts}','[]')||COALESCE(v.payload#>'{location,body,contacts}','[]')) c
   WHERE i.workspace_id=wid AND c->'is_public'='false'::jsonb AND length(c->>'value')>0
 LOOP
  scan:=1;
  LOOP
   pos:=strpos(lower(substr(text_value,scan)),lower(value)); EXIT WHEN pos=0;
   pos:=pos+scan-1;
   redacted:=overlay(redacted PLACING repeat(' ',length(value)) FROM pos FOR length(value));
   spans:=spans||jsonb_build_array(jsonb_build_object('start',pos-1,'end',pos-1+length(value)));
   scan:=pos+length(value);
  END LOOP;
 END LOOP;
 RETURN jsonb_build_object('text',redacted,'locator_map',jsonb_build_object('kind','identity_with_redactions','redactions',spans),
  'policy_version','public-contacts-v1');
END $$;
CREATE FUNCTION preparation.eligible_input(wid uuid,iid uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE inp preparation.inputs; decoded text; result jsonb; metadata jsonb; metadata_redactions jsonb:='{}'; k text; v jsonb; safe jsonb;
BEGIN
 SELECT * INTO inp FROM preparation.inputs WHERE id=iid AND workspace_id=wid;
 IF inp.id IS NULL OR inp.kind<>'text' OR inp.public_attestation<>'true'::jsonb THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='public_source_attestation_required'; END IF;
 decoded:=convert_from(inp.original_bytes,'UTF8'); IF left(decoded,1)=chr(65279) THEN decoded:=substr(decoded,2); END IF;
 result:=preparation.redact_text(wid,decoded);
 SELECT to_jsonb(r)-'source_id'-'code' INTO metadata FROM preparation.workspaces w JOIN sources.registry r USING(source_id) WHERE w.id=wid;
 FOR k,v IN SELECT * FROM jsonb_each(metadata) LOOP
  IF jsonb_typeof(v)='string' THEN
   safe:=preparation.redact_text(wid,v#>>'{}'); metadata:=jsonb_set(metadata,ARRAY[k],safe->'text');
   IF jsonb_array_length(safe#>'{locator_map,redactions}')>0 THEN
    metadata_redactions:=metadata_redactions||jsonb_build_object(k,safe#>'{locator_map,redactions}'); END IF;
  END IF;
 END LOOP;
 RETURN result||jsonb_build_object('input_id',inp.id,'input_hash',inp.sha256,'source_metadata',metadata,
  'source_metadata_redactions',metadata_redactions);
END $$;

CREATE FUNCTION preparation.request_interpretation(id uuid,input uuid,task text,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb; config text; eligible jsonb; job uuid;
 body jsonb:=jsonb_build_object('input',input,'task',task);
BEGIN
 r:=preparation.replay(id,'request_interpretation',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF input IS DISTINCT FROM w.current_input_id OR input IS NULL THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='input_conflict'; END IF;
 IF task IS DISTINCT FROM 'extract_text' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_task_not_available'; END IF;
 SELECT config_version INTO config FROM preparation.ai_settings WHERE enabled;
 IF config IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='ai_not_configured'; END IF;
 eligible:=preparation.eligible_input(id,input);
 SELECT j.id,jsonb_build_object('job_id',j.id,'state',j.state,'reused',true) INTO job,r FROM preparation.jobs j
  WHERE j.workspace_id=id AND j.input_id=input AND j.config_version=config AND j.task=request_interpretation.task
   AND j.state IN ('queued','leased','running','succeeded') AND j.eligible_payload=eligible-'locator_map' AND j.locator_map=eligible->'locator_map'
   AND preparation.requester_authorized(id,j.requester_actor_id) ORDER BY j.created_at DESC LIMIT 1;
 IF job IS NOT NULL THEN RETURN preparation.receipt(id,'request_interpretation',body,key,r); END IF;
 INSERT INTO preparation.jobs(workspace_id,input_id,requester_actor_id,task,config_version,request_key,eligible_payload,locator_map)
  VALUES(id,input,preparation.actor(),task,config,key,eligible-'locator_map',eligible->'locator_map') RETURNING jobs.id INTO job;
 r:=jsonb_build_object('job_id',job,'state','queued');
 RETURN preparation.receipt(id,'request_interpretation',body,key,r);
END $$;
CREATE FUNCTION preparation.read_job(id uuid,job uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id); r jsonb;
BEGIN
 SELECT jsonb_build_object('job_id',j.id,'input_id',j.input_id,'config_version',j.config_version,'state',j.state,'candidate_ids',j.candidate_ids,
  'output',j.output,'diagnostics',j.diagnostics,'created_at',j.created_at,'finished_at',j.finished_at) INTO r
 FROM preparation.jobs j WHERE j.id=job AND j.workspace_id=id;
 IF r IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='job_not_found'; END IF;
 RETURN r;
END $$;
CREATE FUNCTION preparation.cancel_job(id uuid,job uuid,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); j preparation.jobs; r jsonb; body jsonb:=jsonb_build_object('job',job);
BEGIN
 r:=preparation.replay(id,'cancel_job',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT * INTO j FROM preparation.jobs WHERE jobs.id=job AND workspace_id=id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='job_not_found'; END IF;
 IF j.state IN ('queued','leased','running','uncertain') THEN
  UPDATE preparation.jobs SET state='cancelled',cancelled_at=COALESCE(cancelled_at,clock_timestamp()),output=NULL,diagnostics='[{"code":"cancelled"}]' WHERE jobs.id=job;
 END IF;
 r:=jsonb_build_object('job_id',job,'state',CASE WHEN j.state IN ('queued','leased','running','uncertain') THEN 'cancelled' ELSE j.state END);
 RETURN preparation.receipt(id,'cancel_job',body,key,r);
END $$;

CREATE FUNCTION preparation.claim_job(worker uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j preparation.jobs; secret text; config jsonb;
BEGIN
 PERFORM preparation.require_worker();
 IF worker IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='worker_id_required'; END IF;
 -- Recovery never causes a second paid dispatch. No reservation is released here.
 WITH expired AS (UPDATE preparation.jobs SET state=CASE WHEN cancelled_at IS NULL THEN 'uncertain' ELSE 'cancelled' END,diagnostics='[{"code":"dispatch_uncertain"}]'
  WHERE state IN ('running','cancelled') AND dispatch_id IS NOT NULL AND finished_at IS NULL AND lease_expires_at<=clock_timestamp() RETURNING id)
 UPDATE preparation.budget_reservations SET state='uncertain' WHERE job_id IN (SELECT id FROM expired) AND state='reserved';
 UPDATE preparation.jobs SET state='queued',lease_hash=NULL,lease_login=NULL,worker_id=NULL,lease_expires_at=NULL
  WHERE state='leased' AND dispatch_id IS NULL AND lease_expires_at<=clock_timestamp();
 FOR j IN SELECT * FROM preparation.jobs WHERE state='queued' ORDER BY created_at,id FOR UPDATE SKIP LOCKED LOOP
  IF NOT preparation.requester_authorized(j.workspace_id,j.requester_actor_id) OR
   NOT EXISTS(SELECT FROM preparation.workspaces w WHERE w.id=j.workspace_id AND w.current_input_id=j.input_id) THEN
   UPDATE preparation.jobs SET state='cancelled',eligible_payload=NULL,locator_map=NULL,diagnostics='[{"code":"access_or_input_changed"}]' WHERE id=j.id;
   CONTINUE;
  END IF;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  UPDATE preparation.jobs SET state='leased',lease_hash=encode(sha256(convert_to(secret,'UTF8')),'hex'),
   lease_login=session_user,worker_id=worker,lease_expires_at=clock_timestamp()+interval '60 seconds' WHERE id=j.id;
  SELECT provider_config INTO config FROM preparation.ai_configurations WHERE version=j.config_version;
  RETURN jsonb_build_object('job_id',j.id,'workspace_id',j.workspace_id,'input_id',j.input_id,'task',j.task,'config_version',j.config_version,
   'lease',secret,'lease_seconds',60,'eligible_payload',j.eligible_payload,'locator_map',j.locator_map,'provider_config',config);
 END LOOP;
 RETURN NULL;
END $$;
CREATE FUNCTION preparation.leased_job(job uuid,lease text) RETURNS preparation.jobs
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE j preparation.jobs;
BEGIN
 PERFORM preparation.require_worker();
 SELECT * INTO j FROM preparation.jobs WHERE id=job FOR UPDATE;
 IF j.id IS NULL OR j.lease_login IS DISTINCT FROM session_user OR
  j.lease_hash IS DISTINCT FROM encode(sha256(convert_to(lease,'UTF8')),'hex') OR lease IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='job_lease_invalid'; END IF;
 RETURN j;
END $$;
CREATE FUNCTION preparation.heartbeat_job(job uuid,lease text,dispatch uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j preparation.jobs:=preparation.leased_job(job,lease);
BEGIN
 IF j.state NOT IN ('leased','running') OR j.dispatch_id IS DISTINCT FROM dispatch OR j.lease_expires_at<=clock_timestamp() OR
  NOT preparation.requester_authorized(j.workspace_id,j.requester_actor_id) THEN RETURN false; END IF;
 UPDATE preparation.jobs SET lease_expires_at=clock_timestamp()+interval '60 seconds' WHERE id=job;
 RETURN true;
END $$;
CREATE FUNCTION preparation.start_dispatch(job uuid,lease text) RETURNS jsonb
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

CREATE FUNCTION preparation.fail_job(job uuid,lease text,code text,dispatched boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE j preparation.jobs:=preparation.leased_job(job,lease);
BEGIN
 IF code IS NULL OR code NOT IN ('provider_timeout','provider_transport','provider_failure','invalid_output','worker_interrupted') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_job_error_code'; END IF;
 IF dispatched IS DISTINCT FROM (j.dispatch_id IS NOT NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='dispatch_state_mismatch'; END IF;
 IF j.completion_digest IS NOT NULL THEN RETURN jsonb_build_object('state',j.state); END IF;
 IF j.state NOT IN ('leased','running','uncertain','cancelled') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='job_not_running'; END IF;
 UPDATE preparation.jobs SET state=CASE WHEN cancelled_at IS NOT NULL THEN 'cancelled' WHEN dispatched THEN 'uncertain' ELSE 'failed' END,
  diagnostics=jsonb_build_array(jsonb_build_object('code',CASE WHEN dispatched THEN 'dispatch_uncertain' ELSE code END)) WHERE id=job;
 IF dispatched THEN UPDATE preparation.budget_reservations SET state='uncertain' WHERE job_id=job AND state='reserved'; END IF;
 RETURN jsonb_build_object('state',CASE WHEN dispatched THEN 'uncertain' ELSE 'failed' END);
END $$;

CREATE FUNCTION preparation.validate_diagnostics(value jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE d jsonb;
BEGIN
 IF jsonb_typeof(value) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_diagnostic'; END IF;
 FOR d IN SELECT * FROM jsonb_array_elements(value) LOOP
  PERFORM preparation.closed(d,ARRAY['code','path','candidate_key'],ARRAY['code']);
  IF d->>'code' IS NULL OR d->>'code' NOT IN ('ambiguous','conflicting_values','missing_value','unsupported_field','invalid_quote',
   'invalid_shape','provider_refused','provider_incomplete','provider_uncertain','provider_failure','unresolved_reference','redacted_value','no_services') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_diagnostic'; END IF;
 END LOOP;
END $$;

CREATE FUNCTION preparation.validate_job_result(j preparation.jobs,result jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c jsonb; e jsonb; d jsonb; payload jsonb; span jsonb;
BEGIN
 PERFORM preparation.closed(result,ARRAY['schema_version','input_id','input_hash','config_version','state','candidates','mapping','diagnostics'],
  ARRAY['schema_version','input_id','input_hash','config_version','state','candidates','mapping','diagnostics']);
 IF result->'schema_version'<>'1'::jsonb OR jsonb_typeof(result->'state') IS DISTINCT FROM 'string' OR
  result->>'state' NOT IN ('complete','incomplete','refused') OR result->>'input_id' IS DISTINCT FROM j.input_id::text OR
  result->>'input_hash' IS DISTINCT FROM j.eligible_payload->>'input_hash' OR result->>'config_version' IS DISTINCT FROM j.config_version OR
  result->'mapping'<>'null'::jsonb OR jsonb_typeof(result->'candidates') IS DISTINCT FROM 'array' OR
  jsonb_typeof(result->'diagnostics') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_result'; END IF;
 IF jsonb_array_length(result->'candidates')>1000 OR EXISTS(SELECT FROM jsonb_array_elements(result->'candidates') candidate_row
  GROUP BY candidate_row->>'candidate_key' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_candidates'; END IF;
 PERFORM preparation.validate_diagnostics(result->'diagnostics');
 FOR c IN SELECT * FROM jsonb_array_elements(result->'candidates') LOOP
  PERFORM preparation.closed(c,ARRAY['candidate_key','service','location','evidence','diagnostics'],ARRAY['candidate_key','service','location','evidence','diagnostics']);
  IF jsonb_typeof(c->'candidate_key') IS DISTINCT FROM 'string' OR length(c->>'candidate_key') NOT BETWEEN 1 AND 100 OR
   c#>>'{location,kind}' NOT IN ('none','new') OR jsonb_array_length(COALESCE(c#>'{service,territories}','[]'))>0 OR jsonb_typeof(c->'diagnostics') IS DISTINCT FROM 'array' OR
   EXISTS(SELECT FROM jsonb_path_query(c->'service','$.** ? (@.type() == "object").keyvalue()') p WHERE p->>'key' IN
    ('component_id','organization_id','location_id','territory_id','calendar_id','schedule_id','adoption_id','term_id','event_version_id',
     'target_entity_id','target_contact_component_id','selected_geocoding_result_id','parent_location_id','contact_component_id')) OR
   EXISTS(SELECT FROM jsonb_path_query(c->'location','$.** ? (@.type() == "object").keyvalue()') p WHERE p->>'key' LIKE '%_id') OR
   EXISTS(SELECT FROM jsonb_array_elements(COALESCE(c#>'{service,contacts}','[]')||COALESCE(c#>'{location,body,contacts}','[]')) x
    WHERE x->'is_public'='true'::jsonb) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='provider_identity_or_permission_forbidden'; END IF;
  payload:=jsonb_build_object('schema_version',1,'service',c->'service','location',c->'location',
   'target',jsonb_build_object('kind','new'),'field_origins','{}'::jsonb,'evidence',c->'evidence','outcome','review');
  PERFORM preparation.validate_payload(j.workspace_id,payload);
  FOR e IN SELECT * FROM jsonb_array_elements(c->'evidence') LOOP
   IF e->>'kind'='manual' OR e->>'input_id' IS DISTINCT FROM j.input_id::text OR e ? 'cell' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_evidence'; END IF;
   IF e ? 'span' THEN
    IF e->>'quote' IS DISTINCT FROM substr(j.eligible_payload->>'text',(e#>>'{span,start}')::integer+1,
      (e#>>'{span,end}')::integer-(e#>>'{span,start}')::integer) OR EXISTS(
     SELECT FROM jsonb_array_elements(j.locator_map->'redactions') r
      WHERE (r->>'start')::integer<(e#>>'{span,end}')::integer AND (r->>'end')::integer>(e#>>'{span,start}')::integer) THEN
     RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_evidence'; END IF;
   END IF;
  END LOOP;
  -- Candidate diagnostics use the same catalog as the result, never raw errors.
  PERFORM preparation.validate_diagnostics(c->'diagnostics');
 END LOOP;
END $$;

CREATE FUNCTION preparation.finish_job(job uuid,dispatch uuid,lease text,result jsonb,usage jsonb) RETURNS jsonb
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

-- Workspace lifecycle is authoritative even when called outside the UI.
CREATE FUNCTION preparation.cancel_trashed_jobs() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NEW.state IN ('trash','purged') THEN
  UPDATE preparation.jobs SET state='cancelled',cancelled_at=COALESCE(cancelled_at,clock_timestamp()),output=NULL
   WHERE workspace_id=NEW.id AND state IN ('queued','leased','running','uncertain');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER workspace_cancel_jobs AFTER UPDATE OF state ON preparation.workspaces
 FOR EACH ROW EXECUTE FUNCTION preparation.cancel_trashed_jobs();
ALTER FUNCTION preparation.read_workspace(uuid) RENAME TO read_workspace_initial;
REVOKE EXECUTE ON FUNCTION preparation.read_workspace_initial(uuid) FROM egi_editorial;
CREATE FUNCTION preparation.read_workspace(id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb:=preparation.read_workspace_initial(id); summaries jsonb;
BEGIN
 SELECT COALESCE(jsonb_agg(jsonb_build_object('job_id',j.id,'input_id',j.input_id,'config_version',j.config_version,
  'state',j.state,'created_at',j.created_at,'diagnostics',j.diagnostics) ORDER BY j.created_at,j.id),'[]') INTO summaries
  FROM preparation.jobs j WHERE j.workspace_id=read_workspace.id;
 RETURN jsonb_set(r,'{jobs}',summaries);
END $$;

CREATE OR REPLACE FUNCTION preparation.purge_job_payloads(wid uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 UPDATE preparation.jobs SET state='cancelled',cancelled_at=COALESCE(cancelled_at,clock_timestamp()),input_id=NULL,eligible_payload=NULL,locator_map=NULL,output=NULL,candidate_ids='{}',
  diagnostics='[]' WHERE workspace_id=wid;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA preparation FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA preparation FROM PUBLIC;
GRANT USAGE ON SCHEMA preparation TO egi_preparation_worker;
GRANT EXECUTE ON FUNCTION preparation.read_workspace(uuid),preparation.trash_workspace(uuid,bigint,uuid),preparation.request_interpretation(uuid,uuid,text,uuid),preparation.read_job(uuid,uuid),preparation.cancel_job(uuid,uuid,uuid) TO egi_editorial;
GRANT EXECUTE ON FUNCTION preparation.claim_job(uuid),preparation.heartbeat_job(uuid,text,uuid),preparation.start_dispatch(uuid,text),
 preparation.finish_job(uuid,uuid,text,jsonb,jsonb),preparation.fail_job(uuid,text,text,boolean) TO egi_preparation_worker;
COMMIT;
