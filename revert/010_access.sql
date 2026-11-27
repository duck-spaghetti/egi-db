-- Revert egi_database:010_access
-- People and their history cannot be silently discarded.
BEGIN;
SELECT governance.lock_operation();
DO $$ BEGIN
 IF EXISTS(SELECT FROM access.accounts) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='access_accounts_exist';
 END IF;
END $$;
CREATE OR REPLACE FUNCTION governance.publish_contact_protection_resolution(
 target uuid,approved_decision uuid,expected_public uuid,protection_ids uuid[],scope_service uuid,note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner uuid; protection governance.contact_protections; id uuid; result uuid; scopes uuid[]; affected uuid;
BEGIN
 IF NOT pg_has_role(session_user,'egi_privacy_moderator','MEMBER') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='privacy_resolution_denied';
 END IF;
 IF COALESCE(btrim(note),'')='' OR COALESCE(cardinality(protection_ids),0)=0
  OR EXISTS(SELECT FROM unnest(protection_ids) AS x(id) WHERE x.id IS NULL)
  OR cardinality(protection_ids)<>(SELECT count(DISTINCT x.id) FROM unnest(protection_ids) AS x(id)) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='privacy_resolution_reason_and_targets_required';
 END IF;
 SELECT entity_id INTO STRICT owner FROM governance.entity_revisions WHERE revision_id=target AND entity_kind='service';
 PERFORM governance.lock_expected(owner,target,expected_public);
 PERFORM governance.propagate_contact_protection_scopes();
 FOREACH id IN ARRAY protection_ids LOOP
  SELECT * INTO STRICT protection FROM governance.contact_protections WHERE protection_id=id;
  IF EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.protection_id=id AND r.scope_id IS NULL) THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='privacy_resolution_stale';
  END IF;
  IF scope_service IS NULL THEN
   IF owner<>protection.origin_service_id THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='privacy_resolution_wrong_service';
   END IF;
   IF EXISTS(SELECT FROM data.contact_entries c LEFT JOIN i18n.content_units label ON label.content_id=c.label_content_id
      WHERE c.revision_id=target AND NOT c.is_public AND c.channel_type IN('phone','whatsapp','other')
       AND ((protection.kind='phone_hold' AND c.component_id=protection.origin_component_id
          AND governance.protection_phone_uncertain(c.channel_type,c.value,label.original_text))
        OR (protection.kind='number' AND (
          governance.protection_phone_uncertain(c.channel_type,c.value,label.original_text)
          OR protection.number_key=ANY(governance.protection_contact_keys(c.channel_type,c.value,label.original_text)))))) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='privacy_resolution_still_restricted';
   END IF;
  ELSE
   IF owner<>scope_service OR scope_service=protection.origin_service_id
    OR NOT EXISTS(SELECT FROM governance.contact_protection_scopes s WHERE s.protection_id=id AND s.service_id=scope_service
      AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id))
    OR EXISTS(SELECT FROM governance.contact_protection_scopes s
      CROSS JOIN LATERAL governance.protection_service_group(s.service_id) AS m(service_id)
      WHERE s.protection_id=id AND s.service_id<>scope_service AND m.service_id=scope_service
       AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id)) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='privacy_scope_not_separated';
   END IF;
  END IF;
  FOR affected IN
   SELECT protection.origin_service_id
   UNION SELECT s.service_id FROM governance.contact_protection_scopes s
    WHERE s.protection_id=id AND (scope_service IS NULL OR s.service_id=scope_service)
     AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id)
  LOOP
   SELECT array_agg(t) INTO scopes FROM governance.affected_territories(affected,
    (SELECT revision_id FROM governance.published_heads WHERE entity_id=affected)) t;
   PERFORM governance.require_capability('publish',scopes);
  END LOOP;
 END LOOP;
 result:=governance.publish_revision(target,approved_decision,expected_public);
 FOREACH id IN ARRAY protection_ids LOOP
  IF scope_service IS NULL THEN
   INSERT INTO governance.contact_protection_resolutions(protection_id,resolution_service_id,
    resolution_revision_id,publication_id,actor_id,reason)
   VALUES(id,owner,target,result,governance.current_actor(),note);
  ELSE
   INSERT INTO governance.contact_protection_resolutions(protection_id,scope_id,scope_service_id,
    resolution_service_id,resolution_revision_id,publication_id,actor_id,reason)
   SELECT id,s.scope_id,scope_service,owner,target,result,governance.current_actor(),note
    FROM governance.contact_protection_scopes s WHERE s.protection_id=id AND s.service_id=scope_service
     AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id);
  END IF;
  FOR affected IN SELECT DISTINCT service_id FROM governance.contact_protection_scopes WHERE protection_id=id LOOP
   INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
    VALUES(affected,result,'service','contact_protection_resolution');
  END LOOP;
 END LOOP;
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details)
  VALUES(governance.current_actor(),'contact_protection_resolution',owner,target,
   jsonb_build_object('protection_ids',protection_ids,'scope_service_id',scope_service,'reason',note));
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION governance.current_actor() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result uuid;
BEGIN
 SELECT actor_id INTO result FROM governance.actors WHERE database_role=session_user AND enabled;
 IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='unregistered_actor'; END IF;
 RETURN result;
END $$;
REVOKE SELECT ON
 governance.entity_revisions,governance.working_heads,governance.published_heads,
 governance.submissions,governance.review_decisions,governance.publications,governance.value_decisions,
 governance.value_evidence,governance.actors,governance.sync_entries,governance.source_service_links
FROM egi_editorial;
REVOKE ALL ON ALL TABLES IN SCHEMA data,sources,i18n,geo,taxonomy FROM egi_editorial;
REVOKE USAGE ON SCHEMA data,sources,i18n,geo,taxonomy FROM egi_editorial;
REVOKE EXECUTE ON FUNCTION governance.read_contact_protections(uuid),governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text) FROM egi_editorial;
REVOKE egi_writer FROM egi_editorial;
DROP SCHEMA access CASCADE;
ALTER TABLE governance.actor_grants DROP CONSTRAINT actor_grants_capability_check,
 ADD CONSTRAINT actor_grants_capability_check CHECK(capability IN ('propose','approve','publish','verify'));
ALTER TABLE governance.actors ALTER COLUMN database_role SET NOT NULL;
-- Retain the cluster-wide role egi_editorial: other databases may use it.
COMMIT;
