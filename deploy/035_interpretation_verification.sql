-- Deploy egi_database:035_interpretation_verification
-- requires: 034_workbench_context
BEGIN;
CREATE OR REPLACE FUNCTION preparation.validate_payload(wid uuid,payload jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb; c jsonb; h jsonb; v preparation.item_versions; eid jsonb;
BEGIN
 IF payload->'schema_version' IS DISTINCT FROM '3'::jsonb THEN
  PERFORM preparation.validate_payload_v2(wid,payload); RETURN; END IF;
 PERFORM preparation.closed(payload,ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions','interpreted_classifications','interpretation_hypotheses'],
 ARRAY['schema_version','service','location','target','field_origins','evidence','outcome','source_facts','resolutions','interpreted_classifications','interpretation_hypotheses']);
 PERFORM preparation.validate_payload_v2(wid,(payload-'interpreted_classifications'-'interpretation_hypotheses')||'{"schema_version":2}');
 IF jsonb_typeof(payload->'interpreted_classifications') IS DISTINCT FROM 'array' OR jsonb_typeof(payload->'interpretation_hypotheses') IS DISTINCT FROM 'array' OR
  jsonb_array_length(payload->'interpreted_classifications')>1000 OR jsonb_array_length(payload->'interpretation_hypotheses')>1000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretations'; END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(payload->'interpreted_classifications') LOOP
  PERFORM preparation.closed(r,ARRAY['interpretation_id','basis','context','candidates','state','selected','method','job_id'],ARRAY['interpretation_id','basis','context','candidates','state','selected','method','job_id']);
  PERFORM (r->>'interpretation_id')::uuid;
  v:=preparation.interpretation_basis(wid,r->'basis');
  PERFORM preparation.closed(r->'context',ARRAY['territory_id','axis_id','catalog_digest','as_of'],ARRAY['territory_id','axis_id','catalog_digest','as_of']);
  IF r->>'state' NOT IN ('proposed','confirmed','rejected','stale') OR r->>'method' NOT IN ('ai','manual') OR
   r->>'state' IS NULL OR r->>'method' IS NULL OR jsonb_typeof(r->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(r->'candidates')>5 OR
   (r->>'method'='manual' AND r->'job_id'<>'null'::jsonb) OR (r->>'method'='ai' AND NOT EXISTS(SELECT FROM preparation.jobs WHERE id=(r->>'job_id')::uuid AND workspace_id=wid)) OR
   jsonb_typeof(r#>'{context,territory_id}') IS DISTINCT FROM 'string' OR jsonb_typeof(r#>'{context,axis_id}') IS DISTINCT FROM 'string' OR
   jsonb_typeof(r#>'{context,catalog_digest}') IS DISTINCT FROM 'string' OR COALESCE(r#>>'{context,catalog_digest}','') !~ '^[0-9a-f]{64}$' OR
   jsonb_typeof(r#>'{context,as_of}') IS DISTINCT FROM 'string' OR (r#>>'{context,as_of}')::date IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpreted_classification'; END IF;
  PERFORM (r#>>'{context,territory_id}')::uuid; PERFORM (r#>>'{context,axis_id}')::uuid;
  IF NOT EXISTS(SELECT FROM geo.territories WHERE entity_id=(r#>>'{context,territory_id}')::uuid) OR NOT EXISTS(SELECT FROM taxonomy.axes WHERE axis_id=(r#>>'{context,axis_id}')::uuid) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_context'; END IF;
  FOR c IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP
   PERFORM preparation.closed(c,ARRAY['target','reason','support_evidence_ids'],ARRAY['target','reason','support_evidence_ids']);
   IF jsonb_typeof(c->'reason') IS DISTINCT FROM 'string' OR length(btrim(c->>'reason')) NOT BETWEEN 1 AND 4000 OR jsonb_typeof(c->'support_evidence_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(c->'support_evidence_ids')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_candidate'; END IF;
   FOR eid IN SELECT * FROM jsonb_array_elements(c->'support_evidence_ids') LOOP
    IF NOT EXISTS(SELECT FROM jsonb_array_elements(v.evidence) evidence WHERE evidence->>'id'=eid#>>'{}' AND evidence->>'kind' IN ('stated','interpreted') AND evidence ? 'span') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unbound_interpretation_support'; END IF;
   END LOOP;
   PERFORM preparation.closed(c->'target',ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  END LOOP;
  IF r->>'state'='confirmed' THEN
   PERFORM preparation.closed(r->'selected',ARRAY['target','actor_id','confirmed_at'],ARRAY['target','actor_id','confirmed_at']);
   PERFORM preparation.closed(r#>'{selected,target}',ARRAY['kind','adoption_id','release_id','term_id','axis_id'],ARRAY['kind','adoption_id','release_id','term_id','axis_id']);
  ELSIF r->'selected'<>'null'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unconfirmed_interpretation_selection'; END IF;
 END LOOP;
 FOR h IN SELECT * FROM jsonb_array_elements(payload->'interpretation_hypotheses') LOOP
  PERFORM preparation.closed(h,ARRAY['hypothesis_id','kind','statement','state','basis','trigger_evidence_ids','job_id','verification'],ARRAY['hypothesis_id','kind','statement','state','basis','trigger_evidence_ids','job_id','verification']);
  PERFORM (h->>'hypothesis_id')::uuid; v:=preparation.interpretation_basis(wid,h->'basis');
  IF h->>'kind' IS DISTINCT FROM 'abbreviation_expansion' OR h->>'state' IS NULL OR h->>'state' NOT IN ('unverified','verified','rejected','stale') OR
   jsonb_typeof(h->'statement') IS DISTINCT FROM 'string' OR length(btrim(h->>'statement')) NOT BETWEEN 1 AND 4000 OR
   jsonb_typeof(h->'trigger_evidence_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(h->'trigger_evidence_ids')=0 OR
   NOT (h#>'{basis,evidence_ids}') @> (h->'trigger_evidence_ids') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_interpretation_hypothesis'; END IF;
  IF h->'job_id'<>'null'::jsonb AND NOT EXISTS(SELECT FROM preparation.jobs WHERE id=(h->>'job_id')::uuid AND workspace_id=wid) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_hypothesis_job'; END IF;
  IF h->>'state'='verified' THEN
   PERFORM preparation.closed(h->'verification',ARRAY['actor_id','verified_at','decision_id','evidence_ids'],ARRAY['actor_id','verified_at','decision_id','evidence_ids']);
   IF jsonb_typeof(h#>'{verification,evidence_ids}') IS DISTINCT FROM 'array' OR jsonb_array_length(h#>'{verification,evidence_ids}')=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hypothesis_verification_support_required'; END IF;
   FOR eid IN SELECT * FROM jsonb_array_elements(h#>'{verification,evidence_ids}') LOOP
    IF (h->'trigger_evidence_ids') @> jsonb_build_array(eid) OR NOT EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') e WHERE e->>'id'=eid#>>'{}') OR
     EXISTS(SELECT FROM jsonb_array_elements(payload->'evidence') e,jsonb_array_elements(v.evidence) trigger_quote
      WHERE e->>'id'=eid#>>'{}' AND (h->'trigger_evidence_ids') @> jsonb_build_array(trigger_quote->'id') AND
       e->'input_id'=trigger_quote->'input_id' AND e->'input_hash'=trigger_quote->'input_hash' AND e->'span'=trigger_quote->'span' AND e->'quote'=trigger_quote->'quote') THEN
     RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hypothesis_trigger_is_not_verification'; END IF;
   END LOOP;
  ELSIF h->'verification'<>'null'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unverified_hypothesis_verification'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(payload->'interpreted_classifications') x GROUP BY x->>'interpretation_id' HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(payload->'interpretation_hypotheses') x GROUP BY x->>'hypothesis_id' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_interpretation_id'; END IF;
END $$;
CREATE OR REPLACE FUNCTION preparation.guard_interpretation_version() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE wid uuid; previous jsonb; base uuid; r jsonb; old jsonb; a jsonb; result jsonb; field text; idfield text; v preparation.item_versions; pointer text[]; identity preparation.interpretation_identities; undoing boolean; stale boolean; support_evidence jsonb; support_pointer text[];
BEGIN
 SELECT i.workspace_id,i.current_version_id,p.payload INTO wid,base,previous FROM preparation.items i LEFT JOIN preparation.item_versions p ON p.id=i.current_version_id WHERE i.id=NEW.item_id;
 SELECT kind='undo' INTO undoing FROM preparation.operations WHERE id=NEW.operation_id;
 IF previous->'schema_version'='3'::jsonb AND NEW.payload->'schema_version'<>'3'::jsonb THEN
  IF undoing THEN NEW.payload:=NEW.payload||jsonb_build_object('schema_version',3,'source_facts',COALESCE(NEW.payload->'source_facts','[]'::jsonb),'resolutions',COALESCE(NEW.payload->'resolutions','[]'::jsonb),'interpreted_classifications','[]'::jsonb,'interpretation_hypotheses','[]'::jsonb);
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='item_schema_downgrade'; END IF;
 END IF;
 IF NEW.payload->'schema_version'<>'3'::jsonb THEN RETURN NEW; END IF;
 FOREACH field IN ARRAY ARRAY['interpreted_classifications','interpretation_hypotheses'] LOOP
  result:='[]'; idfield:=CASE field WHEN 'interpreted_classifications' THEN 'interpretation_id' ELSE 'hypothesis_id' END;
  FOR r IN SELECT * FROM jsonb_array_elements(NEW.payload->field) LOOP
   v:=preparation.interpretation_basis(wid,r->'basis');
   IF v.item_id<>NEW.item_id THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_item_mismatch'; END IF;
   INSERT INTO preparation.interpretation_identities(id,item_id,kind) VALUES((r->>idfield)::uuid,NEW.item_id,CASE field WHEN 'interpreted_classifications' THEN 'classification' ELSE 'hypothesis' END) ON CONFLICT DO NOTHING;
   SELECT * INTO identity FROM preparation.interpretation_identities WHERE id=(r->>idfield)::uuid;
   IF identity.item_id<>NEW.item_id OR identity.kind<>(CASE field WHEN 'interpreted_classifications' THEN 'classification' ELSE 'hypothesis' END) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_identity_conflict'; END IF;
   SELECT x INTO old FROM jsonb_array_elements(COALESCE(previous->field,'[]')) x WHERE x->>idfield=r->>idfield;
   SELECT array_agg(replace(replace(p,'~1','/'),'~0','~') ORDER BY n) INTO pointer FROM unnest(string_to_array(substr(r#>>'{basis,field_path}',2),'/')) WITH ORDINALITY t(p,n);
   stale:=NEW.payload#>pointer IS DISTINCT FROM v.payload#>pointer OR
    (pointer[1]<>'source_facts' AND NEW.payload#>>ARRAY['field_origins',r#>>'{basis,field_path}','state'] IN ('manual','cleared')) OR
    (pointer[1]='source_facts' AND (NEW.payload#>ARRAY['source_facts',pointer[2],'fact_id'] IS DISTINCT FROM v.payload#>ARRAY['source_facts',pointer[2],'fact_id'] OR
     NEW.payload#>ARRAY['source_facts',pointer[2],'value'] IS DISTINCT FROM NEW.payload#>ARRAY['source_facts',pointer[2],'source_value']));
   IF field='interpreted_classifications' THEN
    FOR support_evidence IN SELECT evidence FROM jsonb_array_elements(v.evidence) evidence WHERE EXISTS(SELECT FROM jsonb_array_elements(r->'candidates') candidate WHERE (candidate->'support_evidence_ids') @> jsonb_build_array(evidence->'id')) LOOP
     SELECT array_agg(replace(replace(part,'~1','/'),'~0','~') ORDER BY n) INTO support_pointer FROM unnest(string_to_array(substr(support_evidence->>'path',2),'/')) WITH ORDINALITY source(part,n);
     IF NEW.payload#>support_pointer IS DISTINCT FROM v.payload#>support_pointer OR
      (support_pointer[1]<>'source_facts' AND NEW.payload#>>ARRAY['field_origins',support_evidence->>'path','state'] IN ('manual','cleared')) OR
      (support_pointer[1]='source_facts' AND (NEW.payload#>ARRAY['source_facts',support_pointer[2],'fact_id'] IS DISTINCT FROM v.payload#>ARRAY['source_facts',support_pointer[2],'fact_id'] OR NEW.payload#>ARRAY['source_facts',support_pointer[2],'value'] IS DISTINCT FROM NEW.payload#>ARRAY['source_facts',support_pointer[2],'source_value'])) THEN stale:=true; END IF;
    END LOOP;
   END IF;
   IF field='interpreted_classifications' AND r->>'state' IN ('proposed','confirmed') THEN
    BEGIN
     FOR a IN SELECT * FROM jsonb_array_elements(r->'candidates') LOOP PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',(r->'context')-'catalog_digest'-'as_of',a->'target'); END LOOP;
     IF r->>'state'='confirmed' THEN PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',(r->'context')-'catalog_digest'-'as_of',r#>'{selected,target}'); END IF;
    EXCEPTION WHEN serialization_failure OR invalid_parameter_value THEN stale:=true; END;
   END IF;
   IF stale THEN r:=r||jsonb_build_object('state','stale',CASE field WHEN 'interpreted_classifications' THEN 'selected' ELSE 'verification' END,NULL);
   ELSIF field='interpreted_classifications' AND r->>'state'='confirmed' AND old->>'state'='confirmed' AND old->'selected'=r->'selected' AND (old->'basis' IS DISTINCT FROM r->'basis' OR old->'context' IS DISTINCT FROM r->'context') THEN
    r:=r||jsonb_build_object('state','proposed','selected',NULL);
   ELSIF field='interpreted_classifications' AND r->>'state'='confirmed' AND old->>'state'='confirmed' AND old->'selected'=r->'selected' AND old->'basis'=r->'basis' AND old->'context'=r->'context' AND NOT COALESCE(NEW.payload#>'{service,classifications}','[]'::jsonb) @> jsonb_build_array(jsonb_build_object('adoption_id',r#>'{selected,target,adoption_id}','term_id',r#>'{selected,target,term_id}')) THEN
    r:=r||jsonb_build_object('state','proposed','selected',NULL);
   ELSIF field='interpreted_classifications' AND r->>'state'='confirmed' THEN
    IF old->>'state'='confirmed' AND old->'selected'=r->'selected' AND old->'basis'=r->'basis' AND old->'context'=r->'context' THEN r:=jsonb_set(r,'{selected}',old->'selected');
    ELSE
     r:=jsonb_set(r,'{selected}',jsonb_build_object('target',r#>'{selected,target}','actor_id',preparation.actor(),'confirmed_at',clock_timestamp()));
     a:=jsonb_build_object('adoption_id',r#>'{selected,target,adoption_id}','term_id',r#>'{selected,target,term_id}');
     IF NOT COALESCE(NEW.payload#>'{service,classifications}','[]') @> jsonb_build_array(a) THEN
      NEW.payload:=jsonb_set(NEW.payload,'{service}',(NEW.payload->'service')||jsonb_build_object('classifications',COALESCE(NEW.payload#>'{service,classifications}','[]')||jsonb_build_array(a)));
      IF NEW.payload#>>'{field_origins,/service/classifications,state}'='cleared' THEN NEW.payload:=jsonb_set(NEW.payload,ARRAY['field_origins','/service/classifications'],jsonb_build_object('state','manual')); END IF;
     END IF;
    END IF;
   ELSIF field='interpretation_hypotheses' AND r->>'state'='verified' AND old->>'state'='verified' AND old->'verification'=r->'verification' AND (old-'verification'-'state') IS DISTINCT FROM (r-'verification'-'state') THEN
    r:=r||jsonb_build_object('state','unverified','verification',NULL);
   ELSIF field='interpretation_hypotheses' AND r->>'state'='verified' AND (old->>'state' IS DISTINCT FROM 'verified' OR old->'verification' IS DISTINCT FROM r->'verification') THEN
    r:=jsonb_set(r,'{verification}',(r->'verification')||jsonb_build_object('actor_id',preparation.actor(),'verified_at',clock_timestamp(),'decision_id',gen_random_uuid()));
   END IF;
   result:=result||jsonb_build_array(r);
  END LOOP;
  NEW.payload:=jsonb_set(NEW.payload,ARRAY[field],result);
 END LOOP;
 PERFORM preparation.validate_payload(wid,NEW.payload);
 NEW.evidence:=NEW.payload->'evidence'; NEW.field_origins:=NEW.payload->'field_origins';
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION editorial.snapshot_interpretation_support() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r jsonb; v preparation.item_versions; supports jsonb:='[]'; quotes jsonb; ids jsonb; metadata jsonb; j preparation.jobs; a preparation.analysis_packets;
BEGIN
 IF NEW.values->'schema_version'<>'3'::jsonb THEN RETURN NEW; END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(NEW.values->'interpreted_classifications') UNION ALL SELECT * FROM jsonb_array_elements(NEW.values->'interpretation_hypotheses') LOOP
  v:=preparation.interpretation_basis(NEW.preparation_id,r->'basis');
  IF v.item_id<>NEW.item_id THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='interpretation_basis_item_mismatch'; END IF;
  ids:=r#>'{basis,evidence_ids}';
  SELECT ids||COALESCE(jsonb_agg(eid),'[]') INTO ids FROM jsonb_array_elements(COALESCE(r->'candidates','[]')) candidate,jsonb_array_elements(candidate->'support_evidence_ids') eid;
  ids:=ids||COALESCE(r#>'{verification,evidence_ids}','[]');
  SELECT COALESCE(jsonb_agg(e),'[]') INTO quotes FROM (SELECT DISTINCT ON (e->>'id') e FROM (SELECT * FROM jsonb_array_elements(v.evidence) UNION ALL SELECT * FROM jsonb_array_elements(NEW.evidence)) source(e) WHERE ids @> jsonb_build_array(e->'id') ORDER BY e->>'id') selected;
  metadata:='[]';
  IF r ? 'interpretation_id' AND r->>'job_id' IS NOT NULL THEN
   SELECT * INTO j FROM preparation.jobs WHERE id=(r->>'job_id')::uuid AND workspace_id=NEW.preparation_id;
   SELECT packet.* INTO a FROM preparation.analysis_packets packet JOIN preparation.packet_jobs q USING(packet_id) WHERE q.job_id=j.id AND packet.task='classify_cards';
   IF a.packet_id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(DISTINCT support),'[]') INTO metadata FROM jsonb_array_elements(a.data->'supports') support
    WHERE support->>'record_key'=NEW.item_id::text AND support->>'origin'='source_metadata' AND EXISTS(
     SELECT FROM jsonb_array_elements(j.output->'proposals') proposal,jsonb_array_elements(proposal->'choices') choice,
      jsonb_array_elements(a.data->'bases') basis,jsonb_array_elements(a.request_body#>'{catalog_context,entries}') entry,
      jsonb_array_elements(r->'candidates') candidate
     WHERE basis->'basis_key'=proposal->'basis_key' AND basis->>'record_key'=NEW.item_id::text AND choice->'candidate_key'=entry->'candidate_key' AND entry->'target'=candidate->'target' AND (choice->'support_keys') @> jsonb_build_array(support->'support_key'));
   END IF;
  END IF;
  supports:=supports||jsonb_build_array(jsonb_build_object('basis',r->'basis','evidence',quotes,'context_support',metadata));
 END LOOP;
 NEW.values:=NEW.values||jsonb_build_object('interpretation_support',supports);
 RETURN NEW;
END $$;

COMMIT;
