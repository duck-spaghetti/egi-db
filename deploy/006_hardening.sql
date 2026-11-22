-- Deploy egi_database:006_hardening
-- requires: 005_sync
BEGIN;

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
 IF NOT FOUND THEN
  IF cause<>'moderation' THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='service_not_published'; END IF;
  SELECT array_agg(t) INTO scopes FROM governance.affected_territories(service,NULL) t;
  PERFORM governance.require_capability('publish',scopes);
  INSERT INTO audit.events(actor_id,action,entity_id,details)
  VALUES(actor,'withdraw',service,jsonb_build_object('cause',cause,'reason',note));
  RETURN;
 END IF;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(service,head.revision_id) t;
 PERFORM governance.require_capability('publish',scopes);

 -- Losing a shared contact also changes every public consumer's response.
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
 SELECT h.entity_id,h.publication_id,'service','shared_contact_withdrawal'
 FROM governance.published_heads h WHERE EXISTS(
  SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=service);
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
  SELECT array_agg(t) INTO scopes FROM governance.affected_territories(place.entity_id,place.revision_id) t;
  PERFORM governance.require_capability('publish',scopes);
  DELETE FROM governance.published_heads WHERE entity_id=place.entity_id;
  INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(place.entity_id,place.publication_id,'location','withdrawal:'||cause);
  INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details)
  VALUES(actor,'withdraw',place.entity_id,place.revision_id,jsonb_build_object('cause',cause,'with_service',service,'reason',note));
 END LOOP;
END $$;

-- A location can become orphaned after a service moves, without any service withdrawal.
CREATE FUNCTION governance.withdraw_orphan_location(location uuid,expected_public uuid,note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=governance.current_actor(); head governance.published_heads; scopes uuid[];
BEGIN
 IF COALESCE(btrim(note),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reason_required'; END IF;
 PERFORM governance.lock_expected(location,NULL,expected_public,false);
 IF NOT EXISTS(SELECT FROM data.locations WHERE entity_id=location) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='withdrawal_requires_location'; END IF;
 SELECT * INTO head FROM governance.published_heads WHERE entity_id=location;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='location_not_published'; END IF;
 IF EXISTS(SELECT FROM governance.published_heads h WHERE
  EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=location)
  OR EXISTS(SELECT FROM data.service_contact_links c WHERE c.revision_id=h.revision_id AND c.target_entity_id=location)
  OR EXISTS(SELECT FROM data.location_revisions child WHERE child.revision_id=h.revision_id AND child.parent_location_id=location)) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='location_still_used'; END IF;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(location,head.revision_id) t;
 PERFORM governance.require_capability('publish',scopes);
 DELETE FROM governance.published_heads WHERE entity_id=location;
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
 VALUES(location,head.publication_id,'location','withdrawal:orphan');
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details)
 VALUES(actor,'withdraw',location,head.revision_id,jsonb_build_object('cause','orphan','reason',note));
END $$;
REVOKE ALL ON FUNCTION governance.withdraw_orphan_location(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.withdraw_orphan_location(uuid,uuid,text) TO egi_writer;
GRANT SELECT ON governance.revision_territories TO egi_sync;
-- Repeated aggregate reads and binding originals must not scan the entire revision history.
CREATE INDEX content_units_owner_field ON i18n.content_units(owner_entity_id,field_code);
CREATE INDEX value_decisions_revision ON governance.value_decisions(revision_id);
CREATE INDEX sync_entries_service ON governance.sync_entries(service_id) WHERE service_id IS NOT NULL;

-- ============================================================================
-- Session temporary objects never shadow what EGI's functions name
-- ============================================================================
DO $$ DECLARE f regprocedure; BEGIN
 -- A: nobody receives TEMPORARY by default. A property of each database: a clone
 -- or a restore without database privileges does not carry it.
 EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC',current_database());
 IF EXISTS(SELECT FROM pg_database d CROSS JOIN LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a
  WHERE d.datname=current_database() AND a.grantee=0 AND a.privilege_type='TEMPORARY') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='temporary_not_revoked';
 END IF;
 -- B: every function, callees included. Left unnamed, pg_temp is searched first for types and relations.
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f' LOOP
  EXECUTE format('ALTER FUNCTION %s SET search_path=pg_catalog,pg_temp',f);
 END LOOP;
END $$;

COMMIT;
