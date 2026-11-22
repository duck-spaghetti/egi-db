-- Deploy egi_database:005_sync
-- requires: 004_directory
BEGIN;

-- ============================================================================
-- Versions per source
-- ============================================================================
CREATE TABLE governance.sync_versions (
 version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 version_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
 dataset_id uuid NOT NULL REFERENCES sources.datasets,
 previous_version_id uuid,
 restores_version_id uuid,
 package_digest text NOT NULL CHECK(package_digest ~ '^[0-9a-f]{64}$'),
 published boolean NOT NULL,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(version_id,dataset_id),
 UNIQUE NULLS NOT DISTINCT(dataset_id,previous_version_id),
 FOREIGN KEY(previous_version_id,dataset_id) REFERENCES governance.sync_versions(version_id,dataset_id),
 FOREIGN KEY(restores_version_id,dataset_id) REFERENCES governance.sync_versions(version_id,dataset_id)
);
-- One row per service the source has ever shown: the latest version alone resolves identity.
-- source_body is what the source said, before any merge with a moderator's edit.
CREATE TABLE governance.sync_entries (
 version_id uuid NOT NULL REFERENCES governance.sync_versions,
 entry_number integer NOT NULL,
 service_id uuid REFERENCES data.services,
 state text NOT NULL CHECK(state IN ('loaded','held','waiting','not_observed')),
 identity jsonb NOT NULL,
 comparable jsonb NOT NULL,
 source_body jsonb,
 PRIMARY KEY(version_id,entry_number),
 UNIQUE(version_id,service_id),
 CHECK(state<>'loaded' OR (service_id IS NOT NULL AND source_body IS NOT NULL))
);
-- The latest decision on a pair prevails. Keys, not entities: a waiting service has no entity yet.
CREATE TABLE governance.source_service_links (
 link_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 link_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
 a_dataset_id uuid NOT NULL REFERENCES sources.datasets,
 a_key text NOT NULL CHECK(btrim(a_key)<>''),
 b_dataset_id uuid NOT NULL REFERENCES sources.datasets,
 b_key text NOT NULL CHECK(btrim(b_key)<>''),
 relation text NOT NULL CHECK(relation IN ('same','distinct')),
 principal text CHECK(principal IN ('a','b')),
 actor_id uuid NOT NULL REFERENCES governance.actors,
 reason text NOT NULL CHECK(btrim(reason)<>''),
 decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(a_dataset_id<b_dataset_id),
 CHECK((relation='same')=(principal IS NOT NULL))
);

-- ============================================================================
-- Operations
-- ============================================================================
CREATE FUNCTION governance.record_sync_version(dataset uuid,digest text,publish boolean,expected_latest uuid,restores uuid,entries jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=governance.current_actor(); latest uuid; result uuid;
BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',ARRAY[]::uuid[]);
 IF publish THEN PERFORM governance.require_capability('publish',ARRAY[]::uuid[]); END IF;
 SELECT v.version_id INTO latest FROM governance.sync_versions v WHERE v.dataset_id=dataset ORDER BY v.version_sequence DESC LIMIT 1;
 IF latest IS DISTINCT FROM expected_latest THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='stale_version'; END IF;
 INSERT INTO governance.sync_versions(dataset_id,previous_version_id,restores_version_id,package_digest,published,actor_id)
 VALUES(dataset,latest,restores,digest,publish,actor) RETURNING version_id INTO result;
 INSERT INTO governance.sync_entries(version_id,entry_number,service_id,state,identity,comparable,source_body)
 SELECT result,e.n,(e.item->>'service_id')::uuid,e.item->>'state',e.item->'identity',e.item->'comparable',NULLIF(e.item->'source_body','null'::jsonb)
 FROM jsonb_array_elements(entries) WITH ORDINALITY AS e(item,n);
 INSERT INTO audit.events(actor_id,action,details)
 VALUES(actor,'sync_version',jsonb_build_object('version_id',result,'dataset_id',dataset,'published',publish));
 RETURN result;
END $$;

-- Withdrawal is neither closure nor deletion: history stays, every public read follows the heads.
CREATE FUNCTION governance.withdraw_service(service uuid,expected_public uuid,cause text,note text)
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

CREATE FUNCTION governance.link_source_services(a_dataset uuid,a_service_key text,b_dataset uuid,b_service_key text,kind text,principal_side text,note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=governance.current_actor(); result uuid;
BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('approve',ARRAY[]::uuid[]);
 INSERT INTO governance.source_service_links(a_dataset_id,a_key,b_dataset_id,b_key,relation,principal,actor_id,reason)
 VALUES(a_dataset,a_service_key,b_dataset,b_service_key,kind,principal_side,actor,note) RETURNING link_id INTO result;
 INSERT INTO audit.events(actor_id,action,details) VALUES(actor,'link_source_services',jsonb_build_object('link_id',result));
 RETURN result;
END $$;

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['sync_versions','sync_entries','source_service_links'] LOOP
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON governance.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;

-- ============================================================================
-- Privileges
-- ============================================================================
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_sync') THEN CREATE ROLE egi_sync NOLOGIN; END IF;
END $$;
GRANT egi_writer TO egi_sync;
REVOKE ALL ON governance.sync_versions,governance.sync_entries,governance.source_service_links FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.withdraw_service(uuid,uuid,text,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION
 governance.record_sync_version(uuid,text,boolean,uuid,uuid,jsonb),
 governance.link_source_services(uuid,text,uuid,text,text,text,text),
 governance.lock_operation()
TO egi_sync;
-- Sync reads current state and appends evidence. Registration stays with the bootstrap.
GRANT USAGE ON SCHEMA data,sources,i18n,geo,audit,taxonomy TO egi_sync;
GRANT SELECT ON ALL TABLES IN SCHEMA data,sources,i18n,geo,taxonomy TO egi_sync;
GRANT SELECT ON
 governance.sync_versions,governance.sync_entries,governance.source_service_links,
 governance.entity_revisions,governance.working_heads,governance.published_heads,
 governance.submissions,governance.review_decisions,governance.publications,
 governance.value_decisions,governance.value_evidence,governance.actors,audit.events
TO egi_sync;
GRANT INSERT ON
 sources.captures,sources.records,sources.record_versions,sources.capture_records,
 sources.processing_runs,sources.normalized_subjects,sources.assertions
TO egi_sync;

COMMIT;
