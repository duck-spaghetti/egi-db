-- Deploy egi_database:015_preparation_history
-- requires: 014_preparations
-- EGI-101: compensating history, bounded trash recovery and retention-only purge.
BEGIN;
ALTER TABLE preparation.workspaces DROP CONSTRAINT workspaces_check,
 ADD CONSTRAINT workspaces_trash_clock CHECK((state IN ('trash','purged'))=(trashed_at IS NOT NULL));

CREATE FUNCTION preparation.retention_login() RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles u ON u.oid=m.member
  WHERE g.rolname='egi_retention' AND u.rolname=session_user)
$$;

-- Only the retention login, through its bounded function, may delete expired
-- private immutable rows. No trigger disabling and no application DELETE grant.
CREATE OR REPLACE FUNCTION preparation.immutable_row() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE wid uuid; expired boolean; removable boolean;
BEGIN
 IF TG_OP='DELETE' AND preparation.retention_login() THEN
  IF TG_TABLE_NAME='inputs' THEN
   wid:=OLD.workspace_id;
   SELECT (w.state IN ('trash','purged') AND w.trashed_at<=clock_timestamp()-interval '30 days') OR
     (w.state='active' AND w.current_input_id IS DISTINCT FROM OLD.id) INTO expired
    FROM preparation.workspaces w WHERE w.id=wid;
   removable:=NOT EXISTS(SELECT FROM preparation.items WHERE origin_input_id=OLD.id) AND
    NOT EXISTS(SELECT FROM preparation.item_versions WHERE input_id=OLD.id) AND
    NOT EXISTS(SELECT FROM preparation.workspaces WHERE current_input_id=OLD.id);
  ELSE
   SELECT workspace_id,trashed_at<=clock_timestamp()-interval '30 days' AND current_version_id IS NULL
    INTO wid,removable FROM preparation.items WHERE id=OLD.item_id;
   SELECT (w.state IN ('trash','purged') AND w.trashed_at<=clock_timestamp()-interval '30 days') OR removable
    INTO expired FROM preparation.workspaces w WHERE w.id=wid;
   removable:=NOT EXISTS(SELECT FROM preparation.items WHERE current_version_id=OLD.id);
  END IF;
  IF expired AND removable THEN RETURN OLD; END IF;
 END IF;
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_immutable';
END $$;

CREATE FUNCTION preparation.read_history(id uuid,item uuid,after bigint DEFAULT 0,lim integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id); versions jsonb; ops jsonb; last_number bigint;
BEGIN
 IF after IS NULL OR after<0 OR lim IS NULL OR lim NOT BETWEEN 1 AND 100 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_history_page'; END IF;
 IF NOT EXISTS(SELECT FROM preparation.items WHERE items.id=item AND workspace_id=id) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='item_not_found'; END IF;
 SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY version_number),'[]'),max(version_number) INTO versions,last_number
 FROM (SELECT * FROM preparation.item_versions WHERE item_id=item AND version_number>after ORDER BY version_number LIMIT lim) v;
 SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.created_at,o.id),'[]') INTO ops FROM preparation.operations o
 WHERE o.workspace_id=id AND o.id IN (SELECT (v->>'operation_id')::uuid FROM jsonb_array_elements(versions) v);
 RETURN jsonb_build_object('versions',versions,'operations',ops,'after',COALESCE(last_number,after),'has_more',
  EXISTS(SELECT FROM preparation.item_versions WHERE item_id=item AND version_number>COALESCE(last_number,after)));
END $$;

CREATE FUNCTION preparation.undo_operation(id uuid,operation uuid,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); original preparation.operations; op uuid;
 c jsonb; i preparation.items; head preparation.item_versions; prior preparation.item_versions; payload jsonb;
 ver uuid; changes jsonb:='[]'; r jsonb; body jsonb:=jsonb_build_object('operation',operation);
BEGIN
 r:=preparation.replay(id,'undo_operation',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT * INTO original FROM preparation.operations WHERE operations.id=operation AND workspace_id=id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='operation_not_found'; END IF;
 -- Check every affected head before appending any compensation.
 FOR c IN SELECT * FROM jsonb_array_elements(original.changed_item_versions) LOOP
  SELECT * INTO i FROM preparation.items WHERE items.id=(c->>'item_id')::uuid AND workspace_id=id;
  IF i.id IS NULL OR i.current_version_id IS DISTINCT FROM (c->>'after')::uuid THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='undo_head_conflict'; END IF;
  IF i.trashed_at<=clock_timestamp()-interval '30 days' THEN
   RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='item_restore_expired'; END IF;
 END LOOP;
 INSERT INTO preparation.operations(workspace_id,actor_id,kind,parent_operation_id)
  VALUES(id,preparation.actor(),'undo',operation) RETURNING operations.id INTO op;
 FOR c IN SELECT * FROM jsonb_array_elements(original.changed_item_versions) LOOP
  SELECT * INTO head FROM preparation.item_versions WHERE item_versions.id=(c->>'after')::uuid;
  IF c->>'before' IS NULL THEN
   payload:=jsonb_set(head.payload,'{outcome}','"trash"'); prior:=head;
  ELSE
   SELECT * INTO prior FROM preparation.item_versions WHERE item_versions.id=(c->>'before')::uuid AND item_id=head.item_id;
   IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='undo_history_unavailable'; END IF;
   payload:=prior.payload;
  END IF;
  INSERT INTO preparation.item_versions(item_id,version_number,parent_id,input_id,payload,evidence,field_origins,outcome,actor_id,operation_id)
   VALUES(head.item_id,head.version_number+1,head.id,prior.input_id,payload,payload->'evidence',payload->'field_origins',
    payload->>'outcome',preparation.actor(),op) RETURNING item_versions.id INTO ver;
  UPDATE preparation.items SET current_version_id=ver,trashed_at=CASE WHEN payload->>'outcome'='trash'
   THEN COALESCE(trashed_at,clock_timestamp()) ELSE NULL END WHERE items.id=head.item_id;
  changes:=changes||jsonb_build_array(jsonb_build_object('item_id',head.item_id,'before',head.id,'after',ver));
 END LOOP;
 UPDATE preparation.operations SET changed_item_versions=changes WHERE operations.id=op;
 r:=jsonb_build_object('operation_id',op,'items',changes);
 RETURN preparation.receipt(id,'undo_operation',body,key,r);
END $$;

-- Preserve the first migration's save implementation behind a lifecycle guard.
ALTER FUNCTION preparation.save_items(uuid,jsonb,uuid) RENAME TO save_items_initial;
REVOKE EXECUTE ON FUNCTION preparation.save_items_initial(uuid,jsonb,uuid) FROM egi_editorial;
CREATE FUNCTION preparation.save_items(id uuid,changes jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces:=preparation.authorize(id,true); r jsonb;
BEGIN
 r:=preparation.replay(id,'save_items',changes,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF jsonb_typeof(changes) IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_item_changes'; END IF;
 IF EXISTS(SELECT FROM preparation.items i JOIN jsonb_array_elements(changes) c ON i.id=(c->>'item_id')::uuid
  WHERE i.workspace_id=id AND i.trashed_at<=clock_timestamp()-interval '30 days') THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='item_restore_expired'; END IF;
 RETURN preparation.save_items_initial(id,changes,key);
END $$;

CREATE FUNCTION preparation.trash_workspace(id uuid,expected bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces; r jsonb; body jsonb:=jsonb_build_object('expected',expected);
BEGIN
 w:=preparation.authorize(id,false,true);
 SELECT * INTO w FROM preparation.workspaces WHERE workspaces.id=trash_workspace.id FOR UPDATE;
 PERFORM preparation.authorize(id,false,true);
 r:=preparation.replay(id,'trash_workspace',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF w.state<>'active' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_inactive'; END IF;
 IF w.metadata_revision IS DISTINCT FROM expected THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='metadata_conflict'; END IF;
 UPDATE preparation.workspaces SET state='trash',trashed_at=clock_timestamp(),metadata_revision=metadata_revision+1 WHERE workspaces.id=trash_workspace.id;
 r:=jsonb_build_object('workspace_id',id,'metadata_revision',expected+1,'state','trash');
 RETURN preparation.receipt(id,'trash_workspace',body,key,r);
END $$;
CREATE FUNCTION preparation.restore_workspace(id uuid,expected bigint,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
#variable_conflict use_variable
DECLARE w preparation.workspaces; r jsonb; body jsonb:=jsonb_build_object('expected',expected);
BEGIN
 w:=preparation.authorize(id,false,true);
 SELECT * INTO w FROM preparation.workspaces WHERE workspaces.id=restore_workspace.id FOR UPDATE;
 PERFORM preparation.authorize(id,false,true);
 r:=preparation.replay(id,'restore_workspace',body,key); IF r IS NOT NULL THEN RETURN r; END IF;
 IF w.metadata_revision IS DISTINCT FROM expected THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='metadata_conflict'; END IF;
 IF w.state<>'trash' OR w.trashed_at<=clock_timestamp()-interval '30 days' THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='preparation_restore_expired'; END IF;
 UPDATE preparation.workspaces SET state='active',trashed_at=NULL,metadata_revision=metadata_revision+1 WHERE workspaces.id=restore_workspace.id;
 r:=jsonb_build_object('workspace_id',id,'metadata_revision',expected+1,'state','active');
 RETURN preparation.receipt(id,'restore_workspace',body,key,r);
END $$;

-- Job storage arrives in EGI-103. Its purge hook will cancel jobs and remove raw
-- derivatives before this function deletes inputs; billing tombstones remain.
CREATE FUNCTION preparation.purge_job_payloads(wid uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN RETURN; END $$;
CREATE FUNCTION preparation.purge_trash() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE w preparation.workspaces; item uuid; workspaces_count bigint:=0; items_count bigint:=0; inputs_count bigint:=0; n bigint;
BEGIN
 IF NOT preparation.retention_login() THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='retention_login_required'; END IF;
 -- Lock in the same workspace-first order as interactive writes. An active
 -- preparation persists indefinitely; only explicitly expired trash is removed.
 FOR w IN SELECT * FROM preparation.workspaces WHERE state<>'purged' AND
  ((state='trash' AND trashed_at<=clock_timestamp()-interval '30 days') OR EXISTS(
   SELECT FROM preparation.items i WHERE i.workspace_id=workspaces.id AND i.trashed_at<=clock_timestamp()-interval '30 days'))
  ORDER BY id FOR UPDATE SKIP LOCKED LOOP
  IF w.state='trash' AND w.trashed_at<=clock_timestamp()-interval '30 days' THEN
   UPDATE preparation.workspaces SET state='purged',current_input_id=NULL,title='Deleted',metadata_revision=metadata_revision+1 WHERE id=w.id;
   PERFORM preparation.purge_job_payloads(w.id);
   UPDATE preparation.items SET current_version_id=NULL WHERE workspace_id=w.id;
   DELETE FROM preparation.item_versions WHERE item_id IN (SELECT id FROM preparation.items WHERE workspace_id=w.id);
   DELETE FROM preparation.items WHERE workspace_id=w.id; GET DIAGNOSTICS n=ROW_COUNT; items_count:=items_count+n;
   DELETE FROM preparation.operations WHERE workspace_id=w.id;
   DELETE FROM preparation.inputs WHERE workspace_id=w.id; GET DIAGNOSTICS n=ROW_COUNT; inputs_count:=inputs_count+n;
   DELETE FROM preparation.grants WHERE workspace_id=w.id;
   UPDATE preparation.requests SET result_ids='{}' WHERE workspace_id=w.id;
   workspaces_count:=workspaces_count+1;
  ELSE
   FOR item IN SELECT id FROM preparation.items WHERE workspace_id=w.id AND trashed_at<=clock_timestamp()-interval '30 days' LOOP
    UPDATE preparation.items SET current_version_id=NULL WHERE id=item;
    DELETE FROM preparation.item_versions WHERE item_id=item;
    DELETE FROM preparation.items WHERE id=item; items_count:=items_count+1;
   END LOOP;
   -- Old inputs shared by surviving cards remain. Current unsent text remains.
   DELETE FROM preparation.inputs p WHERE w.state='active' AND p.workspace_id=w.id AND p.id IS DISTINCT FROM w.current_input_id
    AND NOT EXISTS(SELECT FROM preparation.items i WHERE i.origin_input_id=p.id)
    AND NOT EXISTS(SELECT FROM preparation.item_versions v WHERE v.input_id=p.id);
   GET DIAGNOSTICS n=ROW_COUNT; inputs_count:=inputs_count+n;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('workspaces',workspaces_count,'items',items_count,'inputs',inputs_count);
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA preparation FROM PUBLIC;
GRANT USAGE ON SCHEMA preparation TO egi_retention;
GRANT EXECUTE ON FUNCTION preparation.read_history(uuid,uuid,bigint,integer),preparation.undo_operation(uuid,uuid,uuid),
 preparation.save_items(uuid,jsonb,uuid),preparation.trash_workspace(uuid,bigint,uuid),preparation.restore_workspace(uuid,bigint,uuid) TO egi_editorial;
GRANT EXECUTE ON FUNCTION preparation.purge_trash() TO egi_retention;
COMMIT;
