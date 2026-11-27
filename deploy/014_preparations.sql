-- Deploy egi_database:014_preparations
-- requires: 013_editorial_observations
-- EGI-100: private, explicitly shared preparation aggregates. The editorial role
-- gets functions, never table privileges. No implicit Admin access.
BEGIN;
CREATE SCHEMA preparation;
REVOKE ALL ON SCHEMA preparation FROM PUBLIC;

CREATE TABLE preparation.workspaces (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 owner_actor_id uuid NOT NULL REFERENCES governance.actors,
 source_id uuid NOT NULL REFERENCES sources.registry,
 metadata_revision bigint NOT NULL DEFAULT 1 CHECK(metadata_revision>0),
 current_input_id uuid,
 title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 200),
 state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','trash','purged')),
 trashed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((state='trash')=(trashed_at IS NOT NULL))
);
CREATE INDEX workspaces_owner ON preparation.workspaces(owner_actor_id);
CREATE TABLE preparation.grants (
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 permission text NOT NULL CHECK(permission IN ('read','edit')),
 granted_by uuid NOT NULL REFERENCES governance.actors,
 granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(workspace_id,actor_id)
);
CREATE INDEX grants_actor ON preparation.grants(actor_id,workspace_id);
CREATE TABLE preparation.inputs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 input_number bigint NOT NULL CHECK(input_number>0),
 kind text NOT NULL CHECK(kind IN ('text','csv')),
 original_bytes bytea NOT NULL,
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
 encoding text NOT NULL DEFAULT 'UTF-8' CHECK(encoding='UTF-8'),
 public_attestation jsonb NOT NULL CHECK(jsonb_typeof(public_attestation)='boolean'),
 attested_by uuid NOT NULL REFERENCES governance.actors,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(workspace_id,input_number), UNIQUE(id,workspace_id)
);
ALTER TABLE preparation.workspaces ADD CONSTRAINT workspace_current_input
 FOREIGN KEY(current_input_id,id) REFERENCES preparation.inputs(id,workspace_id);
CREATE TABLE preparation.items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 origin_input_id uuid NOT NULL,
 origin_locator jsonb NOT NULL,
 current_version_id uuid,
 trashed_at timestamptz,
 UNIQUE(id,workspace_id), UNIQUE(workspace_id,origin_locator),
 FOREIGN KEY(origin_input_id,workspace_id) REFERENCES preparation.inputs(id,workspace_id)
);
CREATE TABLE preparation.operations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 kind text NOT NULL CHECK(kind IN ('create','edit','undo')),
 parent_operation_id uuid,
 changed_item_versions jsonb NOT NULL DEFAULT '[]',
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(id,workspace_id),
 FOREIGN KEY(parent_operation_id,workspace_id) REFERENCES preparation.operations(id,workspace_id)
);
CREATE TABLE preparation.item_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 item_id uuid NOT NULL REFERENCES preparation.items,
 version_number bigint NOT NULL CHECK(version_number>0),
 parent_id uuid,
 input_id uuid NOT NULL REFERENCES preparation.inputs,
 payload jsonb NOT NULL,
 evidence jsonb NOT NULL,
 field_origins jsonb NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('review','confirmed','trash')),
 actor_id uuid NOT NULL REFERENCES governance.actors,
 operation_id uuid NOT NULL REFERENCES preparation.operations,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(item_id,version_number), UNIQUE(id,item_id),
 FOREIGN KEY(parent_id,item_id) REFERENCES preparation.item_versions(id,item_id)
);
ALTER TABLE preparation.items ADD CONSTRAINT item_current_version
 FOREIGN KEY(current_version_id,id) REFERENCES preparation.item_versions(id,item_id);
CREATE TABLE preparation.requests (
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 request_key uuid NOT NULL,
 operation_kind text NOT NULL,
 request_digest text NOT NULL,
 result_ids jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(workspace_id,actor_id,request_key)
);

-- Internal helpers have no EXECUTE grant to the editorial login.
CREATE FUNCTION preparation.actor() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE a uuid;
BEGIN
 PERFORM access.require_editorial_login();
 a:=governance.current_actor();
 IF NOT EXISTS(SELECT FROM access.accounts c JOIN governance.actors g USING(actor_id)
  WHERE c.actor_id=a AND c.state='active' AND g.enabled) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='session_invalid';
 END IF;
 RETURN a;
END $$;

CREATE FUNCTION preparation.authorize(wid uuid,writing boolean DEFAULT false,owner_only boolean DEFAULT false)
RETURNS preparation.workspaces
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE a uuid:=preparation.actor(); w preparation.workspaces; p text;
BEGIN
 IF writing THEN SELECT * INTO w FROM preparation.workspaces WHERE id=wid FOR UPDATE;
 ELSE SELECT * INTO w FROM preparation.workspaces WHERE id=wid; END IF;
 SELECT permission INTO p FROM preparation.grants WHERE workspace_id=wid AND actor_id=a;
 IF w.id IS NULL OR w.state='purged' OR (w.owner_actor_id<>a AND p IS NULL) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='preparation_not_found';
 END IF;
 IF writing AND (w.state<>'active' OR NOT EXISTS(
  SELECT FROM access.accounts c JOIN governance.actors g USING(actor_id)
  WHERE c.actor_id=w.owner_actor_id AND c.state='active' AND g.enabled)) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_inactive';
 END IF;
 IF (owner_only AND w.owner_actor_id<>a) OR
    (writing AND w.owner_actor_id<>a AND p<>'edit') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='preparation_permission_denied';
 END IF;
 RETURN w;
END $$;

CREATE FUNCTION preparation.immutable_row() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_immutable'; END $$;
CREATE TRIGGER inputs_immutable BEFORE UPDATE OR DELETE ON preparation.inputs
 FOR EACH ROW EXECUTE FUNCTION preparation.immutable_row();
CREATE TRIGGER versions_immutable BEFORE UPDATE OR DELETE ON preparation.item_versions
 FOR EACH ROW EXECUTE FUNCTION preparation.immutable_row();

CREATE FUNCTION preparation.digest(value jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT encode(sha256(convert_to(value::text,'UTF8')),'hex') $$;
CREATE FUNCTION preparation.replay(wid uuid,kind text,body jsonb,rkey uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE r preparation.requests;
BEGIN
 IF rkey IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='request_key_required'; END IF;
 SELECT * INTO r FROM preparation.requests
  WHERE workspace_id=wid AND actor_id=preparation.actor() AND request_key=rkey;
 IF FOUND THEN
  IF r.operation_kind<>kind OR r.request_digest<>preparation.digest(body) THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='request_key_conflict';
  END IF;
  RETURN r.result_ids;
 END IF;
 RETURN NULL;
END $$;
CREATE FUNCTION preparation.receipt(wid uuid,kind text,body jsonb,rkey uuid,result jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 INSERT INTO preparation.requests VALUES(wid,preparation.actor(),rkey,kind,preparation.digest(body),result,clock_timestamp());
 RETURN result;
END $$;

-- Reject open JSON objects at every structured boundary. Incomplete facts remain
-- possible, but a misspelled key cannot disappear silently during acceptance.
CREATE FUNCTION preparation.closed(value jsonb,allowed text[],required text[] DEFAULT ARRAY[]::text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF jsonb_typeof(value) IS DISTINCT FROM 'object' OR
  EXISTS(SELECT FROM jsonb_object_keys(value) k WHERE NOT k=ANY(allowed)) OR
  NOT value ?& required THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_shape';
 END IF;
END $$;
CREATE FUNCTION preparation.validate_component(value jsonb,kind text) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE allowed text[]; entry jsonb; k text; t text;
BEGIN
 allowed:=CASE kind
 WHEN 'contacts' THEN ARRAY['component_id','channel_type','value','normalized_value','purpose_code','label','sort_order','is_public']
 WHEN 'addresses' THEN ARRAY['component_id','address_kind','formatted','line1','locality','postal_code','administrative_area','country_code','normalization_state']
 WHEN 'organizations' THEN ARRAY['component_id','organization_id','role_code']
 WHEN 'conditions' THEN ARRAY['component_id','condition_kind','requirement_state','details']
 WHEN 'contact_links' THEN ARRAY['component_id','target_entity_id','target_contact_component_id','purpose_code','label']
 WHEN 'languages' THEN ARRAY['language_code','availability_kind','note']
 WHEN 'coverage' THEN ARRAY['component_id','territory_id','geometry_wkt','description']
 WHEN 'classifications' THEN ARRAY['adoption_id','term_id']
 WHEN 'place' THEN ARRAY['component_id','location_id','territory_id','area_description']
 WHEN 'schedules' THEN ARRAY['component_id','scope','timezone','contact_component_id','valid_from','valid_until','completeness','days']
 WHEN 'days' THEN ARRAY['weekday','state','completeness','intervals']
 WHEN 'intervals' THEN ARRAY['component_id','opens','closes','end_day_offset']
 WHEN 'calendar_links' THEN ARRAY['schedule_id','calendar_id','effects']
 WHEN 'effects' THEN ARRAY['component_id','event_version_id','kind','intervals'] END;
 IF allowed IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_component_kind'; END IF;
 PERFORM preparation.closed(value,allowed);
 FOR k,entry IN SELECT * FROM jsonb_each(value) LOOP
  t:=jsonb_typeof(entry);
  IF k IN ('days','intervals','effects') THEN
   IF t<>'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='component_array_required'; END IF;
   FOR entry IN SELECT * FROM jsonb_array_elements(entry) LOOP
    PERFORM preparation.validate_component(entry,k);
   END LOOP;
  ELSIF k IN ('sort_order','weekday','end_day_offset') THEN
   IF t<>'number' OR entry::text !~ '^-?[0-9]+$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='component_integer_required'; END IF;
  ELSIF k='is_public' THEN
   IF t<>'boolean' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='component_boolean_required'; END IF;
  ELSE
   IF t<>'string' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='component_string_required'; END IF;
   IF k ~ '_id$' THEN PERFORM (entry#>>'{}')::uuid; END IF;
  END IF;
 END LOOP;
END $$;
CREATE FUNCTION preparation.validate_body(value jsonb,kind text) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE allowed text[]; k text; v jsonb; child jsonb; t text;
BEGIN
 allowed:=CASE kind WHEN 'service' THEN ARRAY['name','description','original_language','delivery_mode','operational_status','cost_state','cost_note','valid_from','valid_until','closure_date','closure_reason','contacts','territories','place','organizations','conditions','contact_links','languages','coverage','classifications','schedules','calendar_links']
 ELSE ARRAY['name','original_language','location_kind','latitude','longitude','coordinate_state','selected_geocoding_result_id','parent_location_id','addresses','contacts','organizations','territories','schedules','calendar_links'] END;
 PERFORM preparation.closed(value,allowed);
 FOR k,v IN SELECT * FROM jsonb_each(value) LOOP
  t:=jsonb_typeof(v);
  IF k IN ('contacts','territories','organizations','conditions','contact_links','languages','coverage','classifications','schedules','calendar_links','addresses') THEN
   IF t<>'array' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='body_array_required'; END IF;
   FOR child IN SELECT * FROM jsonb_array_elements(v) LOOP
    IF k='territories' THEN
     IF jsonb_typeof(child)<>'string' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='territory_uuid_required'; END IF;
     PERFORM (child#>>'{}')::uuid;
    ELSE PERFORM preparation.validate_component(child,k); END IF;
   END LOOP;
  ELSIF k='place' THEN PERFORM preparation.validate_component(v,k);
  ELSIF k IN ('latitude','longitude') THEN
   IF t<>'number' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='coordinate_number_required'; END IF;
  ELSE
   IF t<>'string' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='body_string_required'; END IF;
   IF k ~ '_id$' THEN PERFORM (v#>>'{}')::uuid; END IF;
  END IF;
 END LOOP;
 IF value ? 'delivery_mode' AND value->>'delivery_mode' NOT IN ('in_person','telephone','online','itinerant') OR
    value ? 'cost_state' AND value->>'cost_state' NOT IN ('free','paid','variable','unknown') OR
    value ? 'operational_status' AND value->>'operational_status' NOT IN ('active','inactive','temporarily_closed','defunct','unknown') OR
    value ? 'coordinate_state' AND value->>'coordinate_state' NOT IN ('known','unknown','uncertain') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_vocabulary'; END IF;
END $$;

CREATE FUNCTION preparation.validate_payload(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE v jsonb; loc jsonb:=payload->'location'; k text; inp preparation.inputs; decoded text; start_at integer; end_at integer;
BEGIN
 PERFORM preparation.closed(payload,ARRAY['schema_version','service','location','target','field_origins','evidence','outcome'],
  ARRAY['schema_version','service','location','target','field_origins','evidence','outcome']);
 IF payload->'schema_version'<>'1'::jsonb OR payload->>'outcome' NOT IN ('review','confirmed','trash') OR
  jsonb_typeof(payload->'outcome')<>'string' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_item_envelope'; END IF;
 PERFORM preparation.validate_body(payload->'service','service');
 v:=payload->'target';
 IF v->>'kind'='new' THEN PERFORM preparation.closed(v,ARRAY['kind']);
 ELSIF v->>'kind'='existing' THEN
  PERFORM preparation.closed(v,ARRAY['kind','service_id','expected_work','expected_public'],ARRAY['kind','service_id','expected_work','expected_public']);
  IF NOT EXISTS(SELECT FROM governance.entity_revisions r JOIN data.services s ON s.entity_id=r.entity_id
   WHERE r.entity_id=(v->>'service_id')::uuid AND r.revision_id=(v->>'expected_work')::uuid) OR
   (v->>'expected_public' IS NOT NULL AND NOT EXISTS(SELECT FROM governance.entity_revisions r
     WHERE r.entity_id=(v->>'service_id')::uuid AND r.revision_id=(v->>'expected_public')::uuid)) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_target'; END IF;
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_target'; END IF;
 IF loc->>'kind'='none' THEN PERFORM preparation.closed(loc,ARRAY['kind']);
 ELSIF loc->>'kind'='new' THEN
  PERFORM preparation.closed(loc,ARRAY['kind','body'],ARRAY['kind','body']);
  PERFORM preparation.validate_body(loc->'body','location');
 ELSIF loc->>'kind'='existing' THEN
  PERFORM preparation.closed(loc,ARRAY['kind','location_id','expected_work','expected_public','action','body'],
   ARRAY['kind','location_id','expected_work','expected_public','action']);
  IF jsonb_typeof(loc->'action') IS DISTINCT FROM 'string' OR loc->>'action' NOT IN ('reuse','revise') OR
   (loc->>'action'='reuse' AND loc ? 'body') OR (loc->>'action'='revise' AND NOT loc ? 'body') OR
   NOT EXISTS(SELECT FROM governance.entity_revisions r JOIN data.locations l ON l.entity_id=r.entity_id
    WHERE r.entity_id=(loc->>'location_id')::uuid AND r.revision_id=(loc->>'expected_work')::uuid) OR
   (loc->>'expected_public' IS NOT NULL AND NOT EXISTS(SELECT FROM governance.entity_revisions r
    WHERE r.entity_id=(loc->>'location_id')::uuid AND r.revision_id=(loc->>'expected_public')::uuid)) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_location'; END IF;
  IF loc ? 'body' THEN PERFORM preparation.validate_body(loc->'body','location'); END IF;
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_location'; END IF;
 IF jsonb_typeof(payload->'field_origins')<>'object' OR jsonb_typeof(payload->'evidence')<>'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_item_metadata'; END IF;
 FOR k,v IN SELECT * FROM jsonb_each(payload->'field_origins') LOOP
  IF k !~ '^/(service|location)/' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_field_path'; END IF;
  PERFORM preparation.closed(v,ARRAY['state','input_id','job_id'],ARRAY['state']);
  IF jsonb_typeof(v->'state') IS DISTINCT FROM 'string' OR v->>'state' NOT IN ('input','generated','manual','cleared') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_field_origin'; END IF;
  IF v ? 'job_id' THEN
   IF jsonb_typeof(v->'job_id') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_job_origin'; END IF;
   PERFORM (v->>'job_id')::uuid;
  END IF;
  IF v ? 'input_id' AND NOT EXISTS(SELECT FROM preparation.inputs WHERE id=(v->>'input_id')::uuid AND workspace_id=wid) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='input_not_in_preparation'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') e GROUP BY e->>'id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_evidence_id'; END IF;
 FOR v IN SELECT * FROM jsonb_array_elements(payload->'evidence') LOOP
  PERFORM preparation.closed(v,ARRAY['id','path','input_id','input_hash','kind','span','cell','quote','note'],
   ARRAY['id','path','input_id','input_hash','kind']);
  IF jsonb_typeof(v->'id') IS DISTINCT FROM 'string' OR jsonb_typeof(v->'path') IS DISTINCT FROM 'string' OR jsonb_typeof(v->'kind') IS DISTINCT FROM 'string' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_evidence_locator'; END IF;
  PERFORM (v->>'id')::uuid;
  IF v->>'kind' NOT IN ('stated','interpreted','manual') OR v->>'path' !~ '^/(service|location)/' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_evidence_locator'; END IF;
  SELECT * INTO inp FROM preparation.inputs WHERE id=(v->>'input_id')::uuid AND workspace_id=wid;
  IF inp.id IS NULL OR inp.sha256 IS DISTINCT FROM v->>'input_hash' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_evidence_input'; END IF;
  IF v ? 'cell' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='csv_evidence_not_available'; END IF;
  IF v ? 'span' THEN
   PERFORM preparation.closed(v->'span',ARRAY['start','end'],ARRAY['start','end']);
   IF jsonb_typeof(v->'span'->'start') IS DISTINCT FROM 'number' OR jsonb_typeof(v->'span'->'end') IS DISTINCT FROM 'number' OR (v->'span'->>'start') !~ '^[0-9]+$' OR (v->'span'->>'end') !~ '^[0-9]+$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_evidence_span'; END IF;
   start_at:=(v->'span'->>'start')::integer; end_at:=(v->'span'->>'end')::integer;
   decoded:=convert_from(inp.original_bytes,'UTF8');
   IF left(decoded,1)=chr(65279) THEN decoded:=substr(decoded,2); END IF;
   IF end_at<=start_at OR end_at>length(decoded) OR jsonb_typeof(v->'quote') IS DISTINCT FROM 'string' OR
    v->>'quote' IS DISTINCT FROM substr(decoded,start_at+1,end_at-start_at) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='evidence_quote_mismatch'; END IF;
  ELSIF v->>'kind'='stated' OR v ? 'quote' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='evidence_span_required';
  END IF;
 END LOOP;
END $$;

CREATE FUNCTION preparation.read_workspace(id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id); a uuid:=preparation.actor(); result jsonb;
BEGIN
 result:=to_jsonb(w)||jsonb_build_object('permission',CASE WHEN w.owner_actor_id=a THEN 'owner' ELSE
  (SELECT permission FROM preparation.grants WHERE workspace_id=id AND actor_id=a) END,
  'items',COALESCE((SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'current_version_id',i.current_version_id,
    'outcome',v.outcome,'payload',v.payload,'version_number',v.version_number,'trashed_at',i.trashed_at) ORDER BY i.id)
   FROM preparation.items i JOIN preparation.item_versions v ON v.id=i.current_version_id WHERE i.workspace_id=id),'[]'),
  'jobs','[]'::jsonb);
 IF w.owner_actor_id=a THEN
  result:=result||jsonb_build_object('grants',COALESCE((SELECT jsonb_agg(jsonb_build_object('actor_id',g.actor_id,
    'permission',g.permission)) FROM preparation.grants g WHERE workspace_id=id),'[]'));
 END IF;
 RETURN result;
END $$;
CREATE FUNCTION preparation.list_workspaces(include_trash boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE a uuid:=preparation.actor(); result jsonb;
BEGIN
 SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY w.created_at DESC,w.id),'[]') INTO result
 FROM preparation.workspaces w WHERE (w.owner_actor_id=a OR EXISTS(
  SELECT FROM preparation.grants g WHERE g.workspace_id=w.id AND g.actor_id=a))
 AND (w.state='active' OR (include_trash AND w.state='trash'));
 RETURN result;
END $$;
CREATE FUNCTION preparation.create_workspace(source uuid,title text,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE a uuid:=preparation.actor(); wid uuid; body jsonb:=jsonb_build_object('source',source,'title',title); r jsonb;
BEGIN
 IF key IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='request_key_required'; END IF;
 -- Creation has no workspace row to lock yet; serialize this actor/key pair only.
 PERFORM pg_advisory_xact_lock(hashtextextended(a::text||key::text,0));
 SELECT workspace_id INTO wid FROM preparation.requests
  WHERE actor_id=a AND request_key=key AND operation_kind='create_workspace';
 IF wid IS NOT NULL THEN
  PERFORM preparation.authorize(wid);
  RETURN preparation.replay(wid,'create_workspace',body,key);
 END IF;
 INSERT INTO preparation.workspaces(owner_actor_id,source_id,title) VALUES(a,source,title) RETURNING id INTO wid;
 r:=preparation.read_workspace(wid);
 RETURN preparation.receipt(wid,'create_workspace',body,key,r);
END $$;
CREATE FUNCTION preparation.set_grant(id uuid,actor uuid,permission text,expected bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true,true); r jsonb;
 body jsonb:=jsonb_build_object('actor',actor,'permission',permission,'expected',expected);
BEGIN
 r:=preparation.replay(id,'set_grant',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF expected IS DISTINCT FROM w.metadata_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='metadata_conflict'; END IF;
 IF actor=w.owner_actor_id OR NOT EXISTS(SELECT FROM access.accounts c JOIN governance.actors g USING(actor_id)
  WHERE c.actor_id=actor AND c.state='active' AND g.enabled) OR permission IS NOT NULL AND permission NOT IN ('read','edit') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_preparation_grant'; END IF;
 IF permission IS NULL THEN DELETE FROM preparation.grants WHERE workspace_id=id AND actor_id=actor;
 ELSE INSERT INTO preparation.grants(workspace_id,actor_id,permission,granted_by)
  VALUES(id,actor,permission,preparation.actor()) ON CONFLICT(workspace_id,actor_id)
  DO UPDATE SET permission=excluded.permission,granted_by=excluded.granted_by,granted_at=clock_timestamp(); END IF;
 UPDATE preparation.workspaces SET metadata_revision=metadata_revision+1 WHERE workspaces.id=set_grant.id;
 r:=jsonb_build_object('workspace_id',id,'metadata_revision',w.metadata_revision+1,'actor_id',actor,'permission',permission);
 RETURN preparation.receipt(id,'set_grant',body,key,r);
END $$;
CREATE FUNCTION preparation.put_input(id uuid,expected bigint,kind text,bytes bytea,attestation jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb; iid uuid; decoded text;
 body jsonb:=jsonb_build_object('expected',expected,'kind',kind,'hash',encode(sha256(bytes),'hex'),'attestation',attestation);
BEGIN
 r:=preparation.replay(id,'put_input',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF expected IS DISTINCT FROM w.metadata_revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='metadata_conflict'; END IF;
 -- CSV is a later approved milestone; do not pretend its row/encoding parser exists.
 IF kind IS DISTINCT FROM 'text' OR bytes IS NULL OR octet_length(bytes)>200003 OR jsonb_typeof(attestation) IS DISTINCT FROM 'boolean' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_text_input'; END IF;
 decoded:=convert_from(bytes,'UTF8'); IF left(decoded,1)=chr(65279) THEN decoded:=substr(decoded,2); END IF;
 IF length(decoded)>50000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='text_too_large'; END IF;
 INSERT INTO preparation.inputs(workspace_id,input_number,kind,original_bytes,sha256,public_attestation,attested_by)
  VALUES(id,COALESCE((SELECT max(input_number)+1 FROM preparation.inputs WHERE workspace_id=id),1),kind,bytes,
   encode(sha256(bytes),'hex'),attestation,preparation.actor()) RETURNING inputs.id INTO iid;
 UPDATE preparation.workspaces SET current_input_id=iid,metadata_revision=metadata_revision+1 WHERE workspaces.id=put_input.id;
 r:=jsonb_build_object('input_id',iid,'input_hash',encode(sha256(bytes),'hex'),'metadata_revision',w.metadata_revision+1);
 RETURN preparation.receipt(id,'put_input',body,key,r);
END $$;
CREATE FUNCTION preparation.read_input(id uuid,input uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id); r jsonb;
BEGIN
 SELECT (to_jsonb(i)-'original_bytes')||jsonb_build_object('original_base64',encode(original_bytes,'base64')) INTO r
 FROM preparation.inputs i WHERE i.id=input AND workspace_id=id;
 IF r IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='input_not_found'; END IF;
 RETURN r;
END $$;
CREATE FUNCTION preparation.read_item(id uuid,item uuid,version uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id); r jsonb;
BEGIN
 SELECT jsonb_build_object('item_id',i.id,'origin_input_id',i.origin_input_id,'version',to_jsonb(v)) INTO r
 FROM preparation.items i JOIN preparation.item_versions v ON v.item_id=i.id AND v.id=COALESCE(version,i.current_version_id)
 WHERE i.id=item AND i.workspace_id=id;
 IF r IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
 RETURN r;
END $$;
CREATE FUNCTION preparation.create_items(id uuid,input uuid,job uuid,selections jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb; item uuid; ver uuid; op uuid;
 locator jsonb; payload jsonb:='{"schema_version":1,"service":{},"location":{"kind":"none"},"target":{"kind":"new"},"field_origins":{},"evidence":[],"outcome":"review"}';
 body jsonb:=jsonb_build_object('input',input,'job',job,'selections',selections);
BEGIN
 r:=preparation.replay(id,'create_items',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF input IS DISTINCT FROM w.current_input_id OR input IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='input_conflict'; END IF;
 IF job IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='interpretation_not_available'; END IF;
 IF jsonb_typeof(selections) IS DISTINCT FROM 'array' OR jsonb_array_length(selections)<>1 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='manual_creation_key_required'; END IF;
 PERFORM preparation.closed(selections->0,ARRAY['creation_key'],ARRAY['creation_key']);
 PERFORM (selections->0->>'creation_key')::uuid;
 IF selections->0->>'creation_key' IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='manual_creation_key_required'; END IF;
 locator:=jsonb_build_object('manual',selections->0->>'creation_key');
 SELECT i.id,i.current_version_id INTO item,ver FROM preparation.items i WHERE workspace_id=id AND origin_locator=locator;
 IF item IS NULL THEN
  INSERT INTO preparation.operations(workspace_id,actor_id,kind) VALUES(id,preparation.actor(),'create') RETURNING operations.id INTO op;
  INSERT INTO preparation.items(workspace_id,origin_input_id,origin_locator) VALUES(id,input,locator) RETURNING items.id INTO item;
  INSERT INTO preparation.item_versions(item_id,version_number,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
   VALUES(item,1,input,payload,'[]','{}','review',preparation.actor(),op) RETURNING item_versions.id INTO ver;
  UPDATE preparation.items SET current_version_id=ver WHERE items.id=item;
  UPDATE preparation.operations SET changed_item_versions=jsonb_build_array(jsonb_build_object('item_id',item,'before',NULL,'after',ver)) WHERE operations.id=op;
 END IF;
 r:=jsonb_build_object('items',jsonb_build_array(jsonb_build_object('item_id',item,'version_id',ver)));
 RETURN preparation.receipt(id,'create_items',body,key,r);
END $$;
CREATE FUNCTION preparation.save_items(id uuid,changes jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb; change jsonb; i preparation.items;
 previous preparation.item_versions; ver uuid; op uuid; changed jsonb:='[]'; payload jsonb; locator jsonb; path text[];
BEGIN
 r:=preparation.replay(id,'save_items',changes,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF jsonb_typeof(changes) IS DISTINCT FROM 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 1000 OR
  EXISTS(SELECT FROM jsonb_array_elements(changes) c GROUP BY c->>'item_id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_item_changes'; END IF;
 INSERT INTO preparation.operations(workspace_id,actor_id,kind) VALUES(id,preparation.actor(),'edit') RETURNING operations.id INTO op;
 FOR change IN SELECT * FROM jsonb_array_elements(changes) LOOP
  PERFORM preparation.closed(change,ARRAY['item_id','expected_version','payload'],ARRAY['item_id','expected_version','payload']);
  SELECT * INTO i FROM preparation.items WHERE items.id=(change->>'item_id')::uuid AND workspace_id=id;
  IF i.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
  IF i.current_version_id IS DISTINCT FROM (change->>'expected_version')::uuid THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='item_version_conflict',DETAIL=i.id::text; END IF;
  payload:=change->'payload'; PERFORM preparation.validate_payload(id,payload);
  SELECT * INTO previous FROM preparation.item_versions WHERE item_versions.id=i.current_version_id;
  -- A retained quotation must not silently follow a changed manual value.
  FOR locator IN SELECT * FROM jsonb_array_elements(payload->'evidence') LOOP
   path:=string_to_array(substr(locator->>'path',2),'/');
   SELECT array_agg(replace(replace(part,'~1','/'),'~0','~') ORDER BY ord) INTO path
    FROM unnest(path) WITH ORDINALITY AS p(part,ord);
   IF locator->>'kind'<>'manual' AND (previous.payload#>path) IS DISTINCT FROM (payload#>path) AND
    EXISTS(SELECT FROM jsonb_array_elements(previous.evidence) old WHERE old->>'id'=locator->>'id') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='citation_value_conflict';
   END IF;
  END LOOP;
  INSERT INTO preparation.item_versions(item_id,version_number,parent_id,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
   VALUES(i.id,previous.version_number+1,previous.id,previous.input_id,payload,payload->'evidence',payload->'field_origins',payload->>'outcome',preparation.actor(),op)
   RETURNING item_versions.id INTO ver;
  UPDATE preparation.items SET current_version_id=ver,trashed_at=CASE WHEN payload->>'outcome'='trash' THEN COALESCE(trashed_at,clock_timestamp()) ELSE NULL END WHERE items.id=i.id;
  changed:=changed||jsonb_build_array(jsonb_build_object('item_id',i.id,'before',previous.id,'after',ver));
 END LOOP;
 UPDATE preparation.operations SET changed_item_versions=changed WHERE operations.id=op;
 r:=jsonb_build_object('operation_id',op,'items',changed);
 RETURN preparation.receipt(id,'save_items',changes,key,r);
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA preparation FROM PUBLIC,egi_editorial;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA preparation FROM PUBLIC,egi_editorial;
GRANT USAGE ON SCHEMA preparation TO egi_editorial;
GRANT EXECUTE ON FUNCTION preparation.create_workspace(uuid,text,uuid),preparation.list_workspaces(boolean),
 preparation.read_workspace(uuid),preparation.set_grant(uuid,uuid,text,bigint,uuid),
 preparation.put_input(uuid,bigint,text,bytea,jsonb,uuid),preparation.read_input(uuid,uuid),
 preparation.create_items(uuid,uuid,uuid,jsonb,uuid),preparation.read_item(uuid,uuid,uuid),
 preparation.save_items(uuid,jsonb,uuid) TO egi_editorial;
COMMIT;
