-- Deploy egi_database:033_private_groups
-- requires: 032_workbench_coverage
BEGIN;
CREATE TABLE preparation.private_groups (
 group_id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES preparation.workspaces, current_version uuid
);
CREATE TABLE preparation.group_revisions (
 version uuid PRIMARY KEY, group_id uuid NOT NULL REFERENCES preparation.private_groups,
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces, body jsonb NOT NULL,
 actor_id uuid NOT NULL REFERENCES governance.actors, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(version,group_id)
);
ALTER TABLE preparation.private_groups ADD FOREIGN KEY(current_version,group_id) REFERENCES preparation.group_revisions(version,group_id);
CREATE TABLE preparation.group_applications (
 operation_id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES preparation.workspaces, actor_id uuid NOT NULL REFERENCES governance.actors,
 group_version uuid NOT NULL REFERENCES preparation.group_revisions, kind text NOT NULL CHECK(kind IN ('apply','undo')),
 original_operation uuid REFERENCES preparation.group_applications, request_key uuid NOT NULL, request_digest text NOT NULL,
 frozen_context jsonb NOT NULL, frozen_mapping jsonb NOT NULL, selection jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), UNIQUE(workspace_id,actor_id,request_key)
);
CREATE TABLE preparation.group_member_receipts (
 operation_id uuid NOT NULL REFERENCES preparation.group_applications, item_id uuid NOT NULL,
 workspace_id uuid NOT NULL REFERENCES preparation.workspaces, members jsonb NOT NULL, expected_version uuid NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','applied','skipped','conflict')),
 reason text CHECK(reason IN ('already_selected','manual_or_cleared','invalid_context','stale_item','ineligible_item','unsupported_member','invalid_card')),
 before_version uuid, after_version uuid, item_operation uuid,
 PRIMARY KEY(operation_id,item_id), CHECK((status='pending')=(reason IS NULL AND before_version IS NULL AND after_version IS NULL))
);
CREATE TRIGGER immutable_group_revision BEFORE UPDATE OR DELETE ON preparation.group_revisions FOR EACH ROW EXECUTE FUNCTION preparation.workbench_immutable();
CREATE TRIGGER immutable_group_application BEFORE UPDATE OR DELETE ON preparation.group_applications FOR EACH ROW EXECUTE FUNCTION preparation.workbench_immutable();
CREATE FUNCTION preparation.group_receipt_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF OLD.status<>'pending' OR (to_jsonb(OLD)-'status'-'reason'-'before_version'-'after_version'-'item_operation') IS DISTINCT FROM
  (to_jsonb(NEW)-'status'-'reason'-'before_version'-'after_version'-'item_operation') THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='group_receipt_immutable'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guarded_group_receipt BEFORE UPDATE ON preparation.group_member_receipts FOR EACH ROW EXECUTE FUNCTION preparation.group_receipt_guard();
CREATE TRIGGER immutable_group_receipt_delete BEFORE DELETE ON preparation.group_member_receipts FOR EACH ROW EXECUTE FUNCTION preparation.workbench_immutable();

CREATE FUNCTION preparation.group_catalog_context(territory uuid,axis uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE page jsonb; entries jsonb:='[]'; offset_at integer:=0; scope jsonb:=jsonb_build_object('territory_id',territory,'axis_id',axis);
BEGIN
 IF NOT EXISTS(SELECT FROM governance.published_heads WHERE entity_id=territory) OR NOT EXISTS(SELECT FROM taxonomy.axes WHERE axis_id=axis) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_context'; END IF;
 LOOP
  page:=preparation.catalog(scope||jsonb_build_object('kind','classification','limit',50,'offset',offset_at));
  entries:=entries||(page->'entries');
  IF jsonb_array_length(entries)>100 THEN RAISE EXCEPTION USING ERRCODE='54000',MESSAGE='group_catalog_limit'; END IF;
  EXIT WHEN page->'next_offset'='null'::jsonb;
  offset_at:=(page->>'next_offset')::integer;
  IF offset_at>100000 THEN RAISE EXCEPTION USING ERRCODE='54000',MESSAGE='group_catalog_limit'; END IF;
 END LOOP;
 RETURN scope||jsonb_build_object('catalog_digest',preparation.workbench_digest(jsonb_build_object('scope',scope,'entries',entries)),'as_of',current_date);
END $$;
CREATE FUNCTION preparation.get_group_context(wid uuid,territory uuid,axis uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM preparation.authorize(wid);
 RETURN preparation.group_catalog_context(territory,axis);
END $$;
CREATE FUNCTION preparation.validate_group_context(context jsonb,mapping jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE matched boolean; candidate jsonb;
BEGIN
 PERFORM preparation.closed(context,ARRAY['territory_id','axis_id','catalog_digest','as_of'],ARRAY['territory_id','axis_id','catalog_digest','as_of']);
 IF COALESCE(context->>'catalog_digest','') !~ '^[0-9a-f]{64}$' OR (context->>'as_of')::date IS NULL OR (context->>'as_of')::date>current_date THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_context'; END IF;
 matched:=context->>'catalog_digest'=preparation.group_catalog_context((context->>'territory_id')::uuid,(context->>'axis_id')::uuid)->>'catalog_digest';
 IF NOT matched THEN
  -- Reviewer packets use their maintained candidate-key profile digest. Accept
  -- that identity only after validating the actual current published catalog.
  FOR candidate IN SELECT provider_config->'catalog_context' FROM preparation.ai_configurations
   WHERE provider_config#>>'{catalog_context,context,territory_id}'=context->>'territory_id' AND provider_config#>>'{catalog_context,context,axis_id}'=context->>'axis_id' LOOP
   BEGIN
    PERFORM preparation.validate_matching_context(candidate);
    IF candidate->>'digest'=context->>'catalog_digest' THEN matched:=true; EXIT; END IF;
    candidate:=jsonb_set(candidate,'{entries}',(SELECT COALESCE(jsonb_agg(x||jsonb_build_object('definition',NULL,'aliases','[]'::jsonb)),'[]') FROM jsonb_array_elements(candidate->'entries') x));
    IF preparation.workbench_digest(candidate-'digest')=context->>'catalog_digest' THEN matched:=true; EXIT; END IF;
   EXCEPTION WHEN data_exception OR serialization_failure THEN NULL;
   END;
  END LOOP;
 END IF;
 IF NOT matched THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_context'; END IF;
 PERFORM preparation.validate_reference('{"kind":"category_label","subject":"service"}',context-'catalog_digest'-'as_of',mapping);
END $$;
CREATE FUNCTION preparation.group_member(wid uuid,member jsonb) RETURNS preparation.item_versions
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE v preparation.item_versions;
BEGIN
 PERFORM preparation.closed(member,ARRAY['item_id','expected_version','basis_kind','basis_id'],ARRAY['item_id','expected_version','basis_kind','basis_id']);
 SELECT iv.* INTO v FROM preparation.items i JOIN preparation.item_versions iv ON iv.id=(member->>'expected_version')::uuid AND iv.item_id=i.id
 WHERE i.id=(member->>'item_id')::uuid AND i.workspace_id=wid;
 IF v.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_member_not_found'; END IF;
 IF member->>'basis_kind'='source_fact' THEN
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(COALESCE(v.payload->'source_facts','[]')) f WHERE f->>'fact_id'=member->>'basis_id' AND f->>'kind'='category_label' AND f->>'subject'='service') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unsupported_group_member'; END IF;
 ELSIF member->>'basis_kind'='interpreted_classification' THEN
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(COALESCE(v.payload->'interpreted_classifications','[]')) x WHERE x->>'interpretation_id'=member->>'basis_id') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unsupported_group_member'; END IF;
 ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unsupported_group_member'; END IF;
 RETURN v;
END $$;
CREATE FUNCTION preparation.save_group(wid uuid,expected uuid,revision jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); g preparation.private_groups; m jsonb; parent uuid; pg preparation.private_groups; result jsonb;
 proposal jsonb; proposal_catalog jsonb; archiving boolean:=false; gid uuid:=(revision->>'group_id')::uuid; ver uuid:=(revision->>'version')::uuid; v preparation.item_versions; body jsonb:=jsonb_build_object('expected',expected,'revision',revision);
BEGIN
 result:=preparation.replay(wid,'save_group',body,key); IF result IS NOT NULL THEN RETURN result; END IF;
 PERFORM preparation.closed(revision,ARRAY['group_id','version','parent_versions','preparation_id','context','members','mapping','state','method','proposal_id'],ARRAY['group_id','version','parent_versions','preparation_id','context','members','mapping','state','method','proposal_id']);
 IF gid IS NULL OR ver IS NULL OR revision->>'preparation_id' IS DISTINCT FROM wid::text OR revision->>'state' IS NULL OR revision->>'state' NOT IN ('proposed','accepted','archived') OR
  revision->>'method' IS NULL OR revision->>'method' NOT IN ('deterministic','ai','manual') OR jsonb_typeof(revision->'members') IS DISTINCT FROM 'array' OR
  jsonb_array_length(revision->'members') NOT BETWEEN 1 AND 1000 OR jsonb_typeof(revision->'parent_versions') IS DISTINCT FROM 'array' OR jsonb_array_length(revision->'parent_versions')>100 OR
  jsonb_typeof(revision->'context') IS DISTINCT FROM 'object' OR EXISTS(SELECT FROM jsonb_array_elements(revision->'parent_versions') x GROUP BY x HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_revision'; END IF;
 SELECT * INTO g FROM preparation.private_groups WHERE group_id=gid;
 IF g.group_id IS NOT NULL AND g.workspace_id<>wid THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_not_found'; END IF;
 IF g.current_version IS DISTINCT FROM expected THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='group_head_conflict'; END IF;
 archiving:=g.group_id IS NOT NULL AND revision->>'state'='archived' AND revision->'parent_versions'=jsonb_build_array(expected) AND
  (revision-'version'-'parent_versions'-'state')=(SELECT r.body-'version'-'parent_versions'-'state' FROM preparation.group_revisions r WHERE r.version=expected);
 IF revision->>'state'='archived' AND NOT archiving THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='archival_content_must_match_head'; END IF;
 IF NOT archiving THEN
 -- AI-linked persistence is supplied by retained proposals only, never arbitrary caller labels.
 IF revision->'proposal_id'<>'null'::jsonb THEN
  SELECT x,p.request_body->'catalog_context' INTO proposal,proposal_catalog
   FROM preparation.workbench_unit_results r JOIN preparation.analysis_packets p USING(packet_id) JOIN preparation.jobs j ON j.id=r.job_id
   JOIN preparation.analysis_plans a ON a.plan_id=p.plan_id AND a.version=p.plan_version,
   jsonb_array_elements(COALESCE(j.output->'proposals','[]')) x
   WHERE a.workspace_id=wid AND (p.packet_id::text||':'||(x->>'proposal_key'))=revision->>'proposal_id'
    AND (r.result->'proposal_keys') @> jsonb_build_array(x->'proposal_key') AND p.task='group_labels';
  IF proposal IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_proposal_not_retained'; END IF;
  IF revision->>'state'='accepted' AND (proposal->>'relation'<>'equivalent' OR jsonb_array_length(proposal->'membership_issues')>0) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_proposal_not_applicable'; END IF;
  IF revision->'mapping'<>'null'::jsonb AND NOT EXISTS(SELECT FROM jsonb_array_elements(proposal->'choices') choice,
   jsonb_array_elements(proposal_catalog->'entries') entry WHERE choice->'candidate_key'=entry->'candidate_key' AND entry->'target'=revision->'mapping') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_proposal_mapping_mismatch'; END IF;
 ELSIF revision->>'method'='ai' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_proposal_required'; END IF;
 END IF;

 IF EXISTS(SELECT FROM jsonb_array_elements(revision->'members') x GROUP BY x->>'item_id',x->>'basis_kind',x->>'basis_id' HAVING count(*)>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='duplicate_group_member'; END IF;
 FOR m IN SELECT * FROM jsonb_array_elements(revision->'members') LOOP
  IF archiving THEN CONTINUE; END IF;
  v:=preparation.group_member(wid,m);
  IF revision->>'state'='accepted' AND m->>'basis_kind'='interpreted_classification' AND EXISTS(
   SELECT FROM jsonb_array_elements(v.payload->'interpreted_classifications') x WHERE x->>'interpretation_id'=m->>'basis_id' AND
    (x#>'{context,territory_id}' IS DISTINCT FROM revision#>'{context,territory_id}' OR x#>'{context,axis_id}' IS DISTINCT FROM revision#>'{context,axis_id}')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='mixed_group_context'; END IF;
  IF revision->>'state'='accepted' AND NOT EXISTS(SELECT FROM preparation.items i WHERE i.id=v.item_id AND i.current_version_id=v.id AND i.trashed_at IS NULL) THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='group_member_head_conflict'; END IF;
 END LOOP;
 IF NOT archiving AND revision->'mapping'<>'null'::jsonb THEN PERFORM preparation.validate_group_context(revision->'context',revision->'mapping');
 ELSIF revision->>'state'='accepted' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='accepted_group_mapping_required'; END IF;
 IF revision->>'state'='accepted' AND EXISTS(SELECT FROM preparation.private_groups other JOIN preparation.group_revisions h ON h.version=other.current_version,
  jsonb_array_elements(h.body->'members') a,jsonb_array_elements(revision->'members') b WHERE other.workspace_id=wid AND other.group_id<>gid AND h.body->>'state'='accepted'
  AND h.body#>'{context,territory_id}'=revision#>'{context,territory_id}' AND h.body#>'{context,axis_id}'=revision#>'{context,axis_id}'
  AND a->>'item_id'=b->>'item_id' AND a->>'basis_kind'=b->>'basis_kind' AND a->>'basis_id'=b->>'basis_id' AND h.body->'mapping'<>revision->'mapping') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='competing_group_mapping'; END IF;
 FOR parent IN SELECT value::uuid FROM jsonb_array_elements_text(revision->'parent_versions') LOOP
  SELECT p.* INTO pg FROM preparation.private_groups p JOIN preparation.group_revisions r ON r.group_id=p.group_id WHERE r.version=parent AND p.workspace_id=wid;
  IF pg.group_id IS NULL OR pg.current_version<>parent THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='group_parent_head_conflict'; END IF;
  IF NOT EXISTS(SELECT FROM preparation.group_revisions pr WHERE pr.version=parent AND pr.body->'context'=revision->'context') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='mixed_group_context'; END IF;
  IF pg.group_id<>gid AND EXISTS(SELECT FROM jsonb_array_elements(revision->'members') child WHERE NOT EXISTS(
   SELECT FROM preparation.group_revisions pr,jsonb_array_elements(pr.body->'members') pm WHERE pr.version IN (SELECT value::uuid FROM jsonb_array_elements_text(revision->'parent_versions'))
    AND pm->>'item_id'=child->>'item_id' AND pm->>'basis_kind'=child->>'basis_kind' AND pm->>'basis_id'=child->>'basis_id')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_lineage_membership_mismatch'; END IF;
  IF jsonb_array_length(revision->'parent_versions')>1 AND EXISTS(SELECT FROM preparation.group_revisions pr,jsonb_array_elements(pr.body->'members') pm WHERE pr.version=parent AND NOT EXISTS(
   SELECT FROM jsonb_array_elements(revision->'members') child WHERE pm->>'item_id'=child->>'item_id' AND pm->>'basis_kind'=child->>'basis_kind' AND pm->>'basis_id'=child->>'basis_id')) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_lineage_membership_mismatch'; END IF;

 END LOOP;
 IF g.group_id IS NULL THEN INSERT INTO preparation.private_groups VALUES(gid,wid,NULL); END IF;
 INSERT INTO preparation.group_revisions VALUES(ver,gid,wid,revision,preparation.actor(),clock_timestamp());
 UPDATE preparation.private_groups SET current_version=ver WHERE group_id=gid;
 -- A combine archives its checked parents. Split lineage keeps the source visible
 -- until the editor explicitly archives it, so unselected members are never lost.
 IF jsonb_array_length(revision->'parent_versions')>1 THEN
  FOR parent IN SELECT value::uuid FROM jsonb_array_elements_text(revision->'parent_versions') LOOP
   SELECT p.* INTO pg FROM preparation.private_groups p WHERE p.current_version=parent;
   IF pg.group_id=gid THEN CONTINUE; END IF;
   SELECT gen_random_uuid() INTO parent;
   INSERT INTO preparation.group_revisions SELECT parent,pg.group_id,wid,r.body||jsonb_build_object('version',parent,'parent_versions',jsonb_build_array(pg.current_version),'state','archived'),preparation.actor(),clock_timestamp() FROM preparation.group_revisions r WHERE r.version=pg.current_version;
   UPDATE preparation.private_groups SET current_version=parent WHERE group_id=pg.group_id;
  END LOOP;
 END IF;
 RETURN preparation.receipt(wid,'save_group',body,key,preparation.read_group(wid,gid,ver,0,100));
END $$;

CREATE FUNCTION preparation.group_mapped_payload(payload jsonb,member jsonb,context jsonb,mapping jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE p jsonb:=payload; f jsonb; r jsonb; changed jsonb:='[]'; idx integer; pointer text; association jsonb;
BEGIN
 IF p#>>ARRAY['field_origins','/service/classifications','state'] IN ('manual','cleared') THEN
  RETURN jsonb_build_object('status','skipped','reason','manual_or_cleared'); END IF;
 IF member->>'basis_kind'='source_fact' THEN
  SELECT x,n::integer-1 INTO f,idx FROM jsonb_array_elements(COALESCE(p->'source_facts','[]')) WITH ORDINALITY a(x,n) WHERE x->>'fact_id'=member->>'basis_id';
  IF f IS NULL THEN RETURN jsonb_build_object('status','conflict','reason','unsupported_member'); END IF;
  pointer:='/source_facts/'||idx||'/value';
  IF NOT f ? 'value' OR p#>>ARRAY['field_origins',pointer,'state']='cleared' OR
   (p#>>ARRAY['field_origins',pointer,'state']='manual' AND f->'value' IS DISTINCT FROM f->'source_value') THEN
   RETURN jsonb_build_object('status','skipped','reason','manual_or_cleared'); END IF;
  SELECT x INTO r FROM jsonb_array_elements(p->'resolutions') x WHERE x->>'fact_id'=member->>'basis_id';
  IF r->>'state'='confirmed' THEN
   RETURN jsonb_build_object('status','skipped','reason',CASE WHEN r#>'{selected,target}'=mapping THEN 'already_selected' ELSE 'manual_or_cleared' END); END IF;
  IF r->>'state'='ignored' THEN RETURN jsonb_build_object('status','skipped','reason','manual_or_cleared'); END IF;
  IF r->>'state'='proposed' AND r->'context'<>(context-'catalog_digest'-'as_of') THEN RETURN jsonb_build_object('status','conflict','reason','invalid_context'); END IF;
  SELECT COALESCE(jsonb_agg(x),'[]') INTO changed FROM jsonb_array_elements(p->'resolutions') x WHERE x->>'fact_id'<>member->>'basis_id';
  changed:=changed||jsonb_build_array(jsonb_build_object('fact_id',member->'basis_id','state','confirmed','context',context-'catalog_digest'-'as_of',
   'candidates',COALESCE(r->'candidates','[]'),'selected',jsonb_build_object('target',mapping)));
  p:=jsonb_set(p,'{resolutions}',changed);
 ELSE
  SELECT x INTO r FROM jsonb_array_elements(COALESCE(p->'interpreted_classifications','[]')) x WHERE x->>'interpretation_id'=member->>'basis_id';
  IF r IS NULL THEN RETURN jsonb_build_object('status','conflict','reason','unsupported_member'); END IF;
  IF r->>'state'='confirmed' THEN RETURN jsonb_build_object('status','skipped','reason',CASE WHEN r#>'{selected,target}'=mapping THEN 'already_selected' ELSE 'manual_or_cleared' END); END IF;
  IF r->>'state' IN ('stale','rejected') THEN RETURN jsonb_build_object('status','skipped','reason','manual_or_cleared'); END IF;
  IF r#>'{context,territory_id}' IS DISTINCT FROM context->'territory_id' OR r#>'{context,axis_id}' IS DISTINCT FROM context->'axis_id' THEN
   RETURN jsonb_build_object('status','conflict','reason','invalid_context'); END IF;
  SELECT COALESCE(jsonb_agg(CASE WHEN x->>'interpretation_id'=member->>'basis_id' THEN x||jsonb_build_object('state','confirmed','method','manual','selected',jsonb_build_object('target',mapping,'actor_id',preparation.actor(),'confirmed_at',clock_timestamp())) ELSE x END),'[]') INTO changed
   FROM jsonb_array_elements(p->'interpreted_classifications') x;
  p:=jsonb_set(p,'{interpreted_classifications}',changed);
 END IF;
 association:=jsonb_build_object('adoption_id',mapping->'adoption_id','term_id',mapping->'term_id');
 IF NOT COALESCE(p#>'{service,classifications}','[]') @> jsonb_build_array(association) THEN
  p:=jsonb_set(p,'{service}',(p->'service')||jsonb_build_object('classifications',COALESCE(p#>'{service,classifications}','[]')||jsonb_build_array(association))); END IF;
 RETURN jsonb_build_object('status','applied','reason',NULL,'payload',jsonb_set(p,'{outcome}','"review"'));
END $$;

CREATE FUNCTION preparation.read_group_operation(wid uuid,operation uuid,start_at integer DEFAULT 0,page_size integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a preparation.group_applications; rows jsonb; total integer; summary jsonb;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR start_at IS NULL OR page_size NOT BETWEEN 1 AND 100 OR start_at NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_page'; END IF;
 SELECT * INTO a FROM preparation.group_applications WHERE operation_id=operation AND workspace_id=wid AND actor_id=preparation.actor();
 IF a.operation_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_operation_not_found'; END IF;
 SELECT count(*),jsonb_build_object('pending',count(*) FILTER(WHERE status='pending'),'applied',count(*) FILTER(WHERE status='applied'),
  'skipped',count(*) FILTER(WHERE status='skipped'),'conflict',count(*) FILTER(WHERE status='conflict')) INTO total,summary FROM preparation.group_member_receipts WHERE operation_id=operation;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('item_id',r.item_id,'status',r.status,'reason',r.reason,'before_version',r.before_version,'after_version',r.after_version) ORDER BY r.item_id),'[]') INTO rows
  FROM (SELECT * FROM preparation.group_member_receipts WHERE operation_id=operation ORDER BY item_id LIMIT page_size OFFSET start_at) r;
 RETURN jsonb_build_object('operation_id',operation,'state',CASE WHEN (summary->>'pending')::integer>0 THEN 'running' ELSE 'complete' END,'items',rows,
  'total_items',total,'next_offset',CASE WHEN start_at+page_size<total THEN start_at+page_size END,'summary',summary);
END $$;
CREATE FUNCTION preparation.process_group_operation(operation uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a preparation.group_applications; r preparation.group_member_receipts; original preparation.group_member_receipts;
 i preparation.items; v preparation.item_versions; prior preparation.item_versions; p jsonb; m jsonb; mapped jsonb; result jsonb;
 terminal_status text; terminal_reason text; failure_message text; after_id uuid; item_op uuid; before_id uuid;
BEGIN
 SELECT * INTO STRICT a FROM preparation.group_applications WHERE operation_id=operation FOR UPDATE;
 FOR r IN SELECT * FROM preparation.group_member_receipts WHERE operation_id=operation AND group_member_receipts.status='pending' ORDER BY item_id LIMIT 50 FOR UPDATE LOOP
  terminal_status:='applied'; terminal_reason:=NULL; after_id:=NULL; item_op:=NULL; before_id:=NULL;
  -- Only expected item/data failures become receipts. Infrastructure exceptions
  -- abort this bounded transaction, leaving all uncommitted work pending.
  BEGIN
   SELECT * INTO i FROM preparation.items WHERE id=r.item_id AND workspace_id=a.workspace_id FOR UPDATE;
   before_id:=i.current_version_id;
   IF i.id IS NULL OR i.trashed_at IS NOT NULL THEN terminal_status:='conflict'; terminal_reason:='ineligible_item';
   ELSIF i.current_version_id<>r.expected_version THEN terminal_status:='conflict'; terminal_reason:='stale_item';
   ELSE
    IF a.kind='apply' THEN PERFORM preparation.validate_group_context(a.frozen_context,a.frozen_mapping); END IF;
    SELECT * INTO STRICT v FROM preparation.item_versions WHERE id=i.current_version_id;
    IF a.kind='apply' THEN
     p:=v.payload;
     FOR m IN SELECT * FROM jsonb_array_elements(r.members) LOOP
      mapped:=preparation.group_mapped_payload(p,m,a.frozen_context,a.frozen_mapping);
      IF mapped->>'status'<>'applied' THEN terminal_status:=mapped->>'status'; terminal_reason:=mapped->>'reason'; EXIT; END IF;
      p:=mapped->'payload';
     END LOOP;
     IF terminal_status='applied' THEN
      result:=preparation.save_items(a.workspace_id,jsonb_build_array(jsonb_build_object('item_id',i.id,'expected_version',v.id,'payload',p)),gen_random_uuid());
      after_id:=(result#>>'{items,0,after}')::uuid; item_op:=(result->>'operation_id')::uuid;
     END IF;
    ELSE
     SELECT * INTO STRICT original FROM preparation.group_member_receipts WHERE operation_id=a.original_operation AND item_id=i.id;
     SELECT * INTO STRICT prior FROM preparation.item_versions WHERE id=original.before_version AND item_id=i.id;
     p:=jsonb_set(prior.payload,'{outcome}','"review"');
     INSERT INTO preparation.operations(workspace_id,actor_id,kind,parent_operation_id) VALUES(a.workspace_id,preparation.actor(),'undo',original.item_operation) RETURNING id INTO item_op;
     INSERT INTO preparation.item_versions(item_id,version_number,parent_id,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
      VALUES(i.id,v.version_number+1,v.id,prior.input_id,p,p->'evidence',p->'field_origins','review',preparation.actor(),item_op) RETURNING id INTO after_id;
     UPDATE preparation.items SET current_version_id=after_id WHERE id=i.id;
     UPDATE preparation.operations SET changed_item_versions=jsonb_build_array(jsonb_build_object('item_id',i.id,'before',v.id,'after',after_id)) WHERE id=item_op;
    END IF;
   END IF;
  EXCEPTION WHEN serialization_failure THEN
   GET STACKED DIAGNOSTICS failure_message=MESSAGE_TEXT;
   IF failure_message NOT IN ('taxonomy_context_stale','item_version_conflict') THEN RAISE; END IF;
   terminal_status:='conflict'; terminal_reason:=CASE WHEN failure_message='item_version_conflict' THEN 'stale_item' ELSE 'invalid_context' END; after_id:=NULL; item_op:=NULL;
   WHEN invalid_parameter_value OR check_violation THEN terminal_status:='conflict'; terminal_reason:='invalid_card'; after_id:=NULL; item_op:=NULL;
  END;
  UPDATE preparation.group_member_receipts SET status=terminal_status,reason=terminal_reason,before_version=before_id,after_version=after_id,item_operation=item_op
   WHERE operation_id=operation AND item_id=r.item_id;
 END LOOP;
END $$;

CREATE FUNCTION preparation.apply_group(wid uuid,request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); g preparation.private_groups; rev preparation.group_revisions;
 a preparation.group_applications; m jsonb; v preparation.item_versions; key uuid:=(request->>'request_key')::uuid; op uuid:=gen_random_uuid();
BEGIN
 PERFORM preparation.closed(request,ARRAY['group_id','expected_group_version','selection','request_key'],ARRAY['group_id','expected_group_version','selection','request_key']);
 IF key IS NULL OR jsonb_typeof(request->'selection') IS DISTINCT FROM 'array' OR jsonb_array_length(request->'selection') NOT BETWEEN 1 AND 100 OR
  EXISTS(SELECT FROM jsonb_array_elements(request->'selection') x GROUP BY x HAVING count(*)>1) OR
  EXISTS(SELECT FROM jsonb_array_elements(request->'selection') x GROUP BY x->>'item_id' HAVING count(DISTINCT x->>'expected_version')>1) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_selection'; END IF;
 SELECT * INTO a FROM preparation.group_applications WHERE workspace_id=wid AND actor_id=preparation.actor() AND request_key=key;
 IF a.operation_id IS NOT NULL THEN
  IF a.kind<>'apply' OR a.request_digest<>preparation.digest(request) THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='request_key_conflict'; END IF;
  PERFORM preparation.process_group_operation(a.operation_id); RETURN preparation.read_group_operation(wid,a.operation_id);
 END IF;
 SELECT * INTO g FROM preparation.private_groups WHERE group_id=(request->>'group_id')::uuid AND workspace_id=wid;
 IF g.group_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_not_found'; END IF;
 IF g.current_version IS DISTINCT FROM (request->>'expected_group_version')::uuid THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='group_head_conflict'; END IF;
 SELECT * INTO STRICT rev FROM preparation.group_revisions WHERE version=g.current_version;
 IF rev.body->>'state'<>'accepted' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='group_not_accepted'; END IF;
 PERFORM preparation.validate_group_context(rev.body->'context',rev.body->'mapping');
 FOR m IN SELECT * FROM jsonb_array_elements(request->'selection') LOOP
  v:=preparation.group_member(wid,m);
  IF NOT EXISTS(SELECT FROM jsonb_array_elements(rev.body->'members') x WHERE x->>'item_id'=m->>'item_id' AND x->>'basis_kind'=m->>'basis_kind' AND x->>'basis_id'=m->>'basis_id') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='member_not_in_group'; END IF;
 END LOOP;
 INSERT INTO preparation.group_applications VALUES(op,wid,preparation.actor(),rev.version,'apply',NULL,key,preparation.digest(request),rev.body->'context',rev.body->'mapping',request->'selection',clock_timestamp());
 INSERT INTO preparation.group_member_receipts(operation_id,item_id,workspace_id,members,expected_version)
  SELECT op,(x->>'item_id')::uuid,wid,jsonb_agg(x),(min(x->>'expected_version'))::uuid FROM jsonb_array_elements(request->'selection') x GROUP BY x->>'item_id';
 PERFORM preparation.process_group_operation(op);
 RETURN preparation.read_group_operation(wid,op);
END $$;
CREATE FUNCTION preparation.undo_group(wid uuid,original_id uuid,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE w preparation.workspaces:=preparation.authorize(wid,true); original preparation.group_applications; a preparation.group_applications; op uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO original FROM preparation.group_applications WHERE operation_id=original_id AND workspace_id=wid AND actor_id=preparation.actor() AND kind='apply';
 IF original.operation_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_operation_not_found'; END IF;
 IF key IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='request_key_required'; END IF;
 SELECT * INTO a FROM preparation.group_applications WHERE workspace_id=wid AND actor_id=preparation.actor() AND request_key=key;
 IF a.operation_id IS NOT NULL THEN
  IF a.kind<>'undo' OR a.original_operation<>original_id THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='request_key_conflict'; END IF;
  PERFORM preparation.process_group_operation(a.operation_id); RETURN preparation.read_group_operation(wid,a.operation_id);
 END IF;
 IF EXISTS(SELECT FROM preparation.group_member_receipts WHERE operation_id=original_id AND status='pending') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='group_application_pending'; END IF;
 INSERT INTO preparation.group_applications VALUES(op,wid,preparation.actor(),original.group_version,'undo',original_id,key,preparation.digest(jsonb_build_object('undo',original_id)),original.frozen_context,original.frozen_mapping,original.selection,clock_timestamp());
 INSERT INTO preparation.group_member_receipts(operation_id,item_id,workspace_id,members,expected_version)
  SELECT op,item_id,wid,members,after_version FROM preparation.group_member_receipts WHERE operation_id=original_id AND status='applied';
 PERFORM preparation.process_group_operation(op);
 RETURN preparation.read_group_operation(wid,op);
END $$;

CREATE FUNCTION preparation.read_group(wid uuid,gid uuid,revision uuid DEFAULT NULL,start_at integer DEFAULT 0,page_size integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; members jsonb; total integer;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR start_at IS NULL OR page_size NOT BETWEEN 1 AND 100 OR start_at NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_page'; END IF;
 SELECT r.body INTO result FROM preparation.private_groups g JOIN preparation.group_revisions r ON r.group_id=g.group_id AND r.version=COALESCE(revision,g.current_version)
 WHERE g.group_id=gid AND g.workspace_id=wid;
 IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='group_not_found'; END IF;
 total:=jsonb_array_length(result->'members');
 SELECT COALESCE(jsonb_agg(x ORDER BY n),'[]') INTO members FROM jsonb_array_elements(result->'members') WITH ORDINALITY a(x,n) WHERE n>start_at AND n<=start_at+page_size;
 RETURN jsonb_build_object('group',result-'members','members',members,'total_members',total,'next_offset',CASE WHEN start_at+page_size<total THEN start_at+page_size END);
END $$;
CREATE FUNCTION preparation.list_groups(wid uuid,start_at integer DEFAULT 0,page_size integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; total integer;
BEGIN
 PERFORM preparation.authorize(wid);
 IF page_size IS NULL OR start_at IS NULL OR page_size NOT BETWEEN 1 AND 100 OR start_at NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_group_page'; END IF;
 SELECT COALESCE(jsonb_agg((x.body-'members'-'parent_versions')||jsonb_build_object('member_count',jsonb_array_length(x.body->'members')) ORDER BY x.group_id),'[]') INTO result FROM (SELECT g.group_id,r.body FROM preparation.private_groups g JOIN preparation.group_revisions r ON r.version=g.current_version
 WHERE g.workspace_id=wid ORDER BY g.group_id LIMIT page_size OFFSET start_at) x;
 SELECT count(*) INTO total FROM preparation.private_groups WHERE workspace_id=wid;
 RETURN jsonb_build_object('groups',result,'total',total,'next_offset',CASE WHEN start_at+page_size<total THEN start_at+page_size END);
END $$;
ALTER FUNCTION preparation.purge_job_payloads(uuid) RENAME TO purge_job_payloads_before_groups;
CREATE FUNCTION preparation.purge_job_payloads(wid uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NOT preparation.retention_login() OR NOT EXISTS(SELECT FROM preparation.workspaces w WHERE w.id=wid AND w.state IN ('trash','purged') AND w.trashed_at<=clock_timestamp()-interval '30 days') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='expired_retention_workspace_required'; END IF;
 DELETE FROM preparation.group_member_receipts WHERE workspace_id=wid;
 DELETE FROM preparation.group_applications WHERE workspace_id=wid;
 UPDATE preparation.private_groups SET current_version=NULL WHERE workspace_id=wid;
 DELETE FROM preparation.group_revisions WHERE workspace_id=wid;
 DELETE FROM preparation.private_groups WHERE workspace_id=wid;
 PERFORM preparation.purge_job_payloads_before_groups(wid);
END $$;
REVOKE ALL ON preparation.private_groups,preparation.group_revisions,preparation.group_applications,preparation.group_member_receipts FROM PUBLIC,egi_editorial,egi_preparation_worker,egi_retention;
REVOKE ALL ON FUNCTION preparation.group_catalog_context(uuid,uuid),preparation.get_group_context(uuid,uuid,uuid),preparation.group_receipt_guard(),preparation.validate_group_context(jsonb,jsonb),preparation.group_member(uuid,jsonb),
 preparation.save_group(uuid,uuid,jsonb,uuid),preparation.group_mapped_payload(jsonb,jsonb,jsonb,jsonb),preparation.read_group_operation(uuid,uuid,integer,integer),
 preparation.process_group_operation(uuid),preparation.apply_group(uuid,jsonb),preparation.undo_group(uuid,uuid,uuid),preparation.read_group(uuid,uuid,uuid,integer,integer),
 preparation.list_groups(uuid,integer,integer),preparation.purge_job_payloads(uuid),preparation.purge_job_payloads_before_groups(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparation.get_group_context(uuid,uuid,uuid),preparation.save_group(uuid,uuid,jsonb,uuid),preparation.read_group_operation(uuid,uuid,integer,integer),preparation.apply_group(uuid,jsonb),
 preparation.undo_group(uuid,uuid,uuid),preparation.read_group(uuid,uuid,uuid,integer,integer),preparation.list_groups(uuid,integer,integer) TO egi_editorial;
COMMIT;
