-- Revert egi_database:006_hardening
-- This reopens the defect that 006 closes: only for a database that is to be discarded.
BEGIN;
DROP INDEX governance.sync_entries_service;
DROP INDEX governance.value_decisions_revision;
DROP INDEX i18n.content_units_owner_field;
REVOKE SELECT ON governance.revision_territories FROM egi_sync;
DROP FUNCTION governance.withdraw_orphan_location(uuid,uuid,text);
CREATE OR REPLACE FUNCTION governance.withdraw_service(service uuid,expected_public uuid,cause text,note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=governance.current_actor(); scopes uuid[]; head governance.published_heads; place record;
BEGIN
 IF cause IS NULL OR cause NOT IN ('not_observed','duplicate','moderation') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unknown_withdrawal_cause'; END IF;
 IF COALESCE(btrim(note),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reason_required'; END IF;
 IF cause<>'moderation' AND NOT pg_has_role(session_user,'egi_sync','MEMBER') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='sync_cause_denied'; END IF;
 PERFORM governance.lock_expected(service,NULL,expected_public,false);
 IF NOT EXISTS(SELECT FROM data.services WHERE entity_id=service) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='withdrawal_requires_service'; END IF;
 SELECT * INTO head FROM governance.published_heads WHERE entity_id=service;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='service_not_published'; END IF;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(service,head.revision_id) t;
 PERFORM governance.require_capability('publish',scopes);

 DELETE FROM governance.published_heads WHERE entity_id=service;
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(service,head.publication_id,'service','withdrawal:'||cause);
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details)
 VALUES(actor,'withdraw',service,head.revision_id,jsonb_build_object('cause',cause,'reason',note));

 -- api.public_locations lists every published location: do not leave this address behind.
 FOR place IN
  SELECT l.entity_id,l.revision_id,l.publication_id FROM data.service_places p JOIN governance.published_heads l ON l.entity_id=p.location_id
  WHERE p.revision_id=head.revision_id AND NOT EXISTS(
   SELECT FROM governance.published_heads h WHERE
    EXISTS(SELECT FROM data.service_places o WHERE o.revision_id=h.revision_id AND o.location_id=l.entity_id)
    OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=l.entity_id)
    OR EXISTS(SELECT FROM data.location_revisions child WHERE child.revision_id=h.revision_id AND child.parent_location_id=l.entity_id))
 LOOP
  DELETE FROM governance.published_heads WHERE entity_id=place.entity_id;
  INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(place.entity_id,place.publication_id,'location','withdrawal:'||cause);
  INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details)
  VALUES(actor,'withdraw',place.entity_id,place.revision_id,jsonb_build_object('cause',cause,'with_service',service,'reason',note));
 END LOOP;
END $$;



-- ============================================================================
-- Session temporary objects
-- ============================================================================
DO $$ DECLARE f regprocedure; BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f' LOOP
  EXECUTE format('ALTER FUNCTION %s SET search_path=pg_catalog',f);
 END LOOP;
 EXECUTE format('GRANT TEMPORARY ON DATABASE %I TO PUBLIC',current_database());
END $$;

COMMIT;
