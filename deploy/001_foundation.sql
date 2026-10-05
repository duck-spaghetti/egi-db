-- Deploy egi_database:001_foundation
BEGIN;

-- ============================================================================
-- Foundation
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA data;
CREATE SCHEMA governance;
CREATE SCHEMA audit;
CREATE SCHEMA sources;
CREATE SCHEMA geo;
CREATE SCHEMA taxonomy;
CREATE SCHEMA i18n;
CREATE SCHEMA api;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE TABLE governance.actors (
 actor_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 database_role name UNIQUE NOT NULL,
 display_name text NOT NULL,
 enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE data.entities (
 entity_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 entity_kind text NOT NULL CHECK(entity_kind IN ('organization','location','service','territory','taxonomy_vocabulary','taxonomy_term','calendar_event')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(entity_id,entity_kind)
);
CREATE TABLE data.organizations (
 entity_id uuid PRIMARY KEY,
 entity_kind text NOT NULL DEFAULT 'organization' CHECK(entity_kind='organization'),
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE data.locations (
 entity_id uuid PRIMARY KEY,
 entity_kind text NOT NULL DEFAULT 'location' CHECK(entity_kind='location'),
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE data.services (
 entity_id uuid PRIMARY KEY,
 entity_kind text NOT NULL DEFAULT 'service' CHECK(entity_kind='service'),
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE data.components (
 component_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 owner_entity_id uuid NOT NULL REFERENCES data.entities,
 component_kind text NOT NULL CHECK(component_kind IN ('contact','contact_link','address','condition','place','organization_role','coverage','schedule','interval')),
 UNIQUE(component_id,owner_entity_id,component_kind),
 UNIQUE(component_id,owner_entity_id)
);
CREATE TABLE governance.entity_revisions (
 revision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 entity_id uuid NOT NULL,
 entity_kind text NOT NULL,
 revision_number bigint NOT NULL CHECK(revision_number>0),
 parent_revision_id uuid,
 restored_from_revision_id uuid,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 reason text NOT NULL CHECK(btrim(reason)<>''),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 sealed_at timestamptz,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind),
 UNIQUE(entity_id,revision_number),
 UNIQUE(revision_id,entity_id),
 UNIQUE(revision_id,entity_id,entity_kind),
 FOREIGN KEY(parent_revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(restored_from_revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE TABLE governance.working_heads (
 entity_id uuid PRIMARY KEY REFERENCES data.entities,
 revision_id uuid NOT NULL,
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE TABLE i18n.content_units (
 content_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 owner_entity_id uuid NOT NULL REFERENCES data.entities,
 introduced_revision_id uuid NOT NULL,
 field_code text NOT NULL CHECK(btrim(field_code)<>''),
 component_id uuid,
 original_language text,
 original_text text NOT NULL,
 UNIQUE(content_id,owner_entity_id),
 FOREIGN KEY(introduced_revision_id,owner_entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,owner_entity_id) REFERENCES data.components(component_id,owner_entity_id)
);
CREATE TABLE i18n.revision_content_links (
 revision_id uuid NOT NULL,
 entity_id uuid NOT NULL,
 field_code text NOT NULL,
 component_scope uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
 content_id uuid NOT NULL,
 PRIMARY KEY(revision_id,field_code,component_scope),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id)
);
CREATE TABLE audit.events (
 event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 action text NOT NULL,
 entity_id uuid REFERENCES data.entities,
 revision_id uuid,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 details jsonb NOT NULL DEFAULT '{}',
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id)
);
CREATE FUNCTION governance.reject_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='immutable_record'; END $$;
CREATE FUNCTION governance.protect_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='DELETE' OR OLD.sealed_at IS NOT NULL THEN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='immutable_revision';
 END IF;
 IF (to_jsonb(NEW)-'sealed_at') IS DISTINCT FROM (to_jsonb(OLD)-'sealed_at') OR NEW.sealed_at IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='only_sealing_allowed';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER protect_revision BEFORE UPDATE OR DELETE ON governance.entity_revisions FOR EACH ROW EXECUTE FUNCTION governance.protect_revision();
CREATE FUNCTION governance.check_open_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=NEW.revision_id AND sealed_at IS NOT NULL) THEN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='sealed_revision';
 END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION i18n.check_content_binding() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE unit i18n.content_units;
BEGIN
 SELECT * INTO STRICT unit FROM i18n.content_units WHERE content_id=NEW.content_id;
 IF unit.owner_entity_id<>NEW.entity_id OR unit.field_code<>NEW.field_code OR
    COALESCE(unit.component_id,'00000000-0000-0000-0000-000000000000'::uuid)<>NEW.component_scope THEN
  RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='content_binding_mismatch';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER check_content_binding BEFORE INSERT ON i18n.revision_content_links FOR EACH ROW EXECUTE FUNCTION i18n.check_content_binding();
CREATE TRIGGER open_content_link BEFORE INSERT ON i18n.revision_content_links FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['data.entities','data.organizations','data.locations','data.services','data.components','i18n.content_units','i18n.revision_content_links','audit.events'] LOOP
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
CREATE FUNCTION governance.current_actor() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid;
BEGIN
 SELECT actor_id INTO result FROM governance.actors WHERE database_role=session_user AND enabled;
 IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='unregistered_actor'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA data,governance,audit,sources,geo,i18n,taxonomy,api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance,i18n FROM PUBLIC;

-- ============================================================================
-- Evidence
-- ============================================================================
CREATE TABLE sources.registry (
 source_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text UNIQUE NOT NULL,
 name text NOT NULL, publisher text, homepage text, source_kind text NOT NULL,
 license text, attribution text
);
CREATE TABLE sources.datasets (
 dataset_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_id uuid NOT NULL REFERENCES sources.registry,
 external_key text, name text NOT NULL, resource_url text,
 UNIQUE(source_id,external_key)
);
CREATE TABLE sources.captures (
 capture_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), dataset_id uuid NOT NULL REFERENCES sources.datasets,
 retrieved_at timestamptz NOT NULL, published_at timestamptz,
 artifact_uri text NOT NULL, content_hash text NOT NULL, media_type text NOT NULL,
 retrieval_status text NOT NULL, source_metadata_snapshot jsonb NOT NULL,
 UNIQUE(capture_id,dataset_id)
);
CREATE TABLE sources.records (
 record_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), dataset_id uuid NOT NULL REFERENCES sources.datasets,
 external_key text, generated_locator text, identity_method text NOT NULL,
 CHECK((external_key IS NOT NULL)<>(generated_locator IS NOT NULL)),
 UNIQUE(dataset_id,external_key), UNIQUE(dataset_id,generated_locator), UNIQUE(record_id,dataset_id)
);
CREATE TABLE sources.record_versions (
 record_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), record_id uuid NOT NULL,
 dataset_id uuid NOT NULL, content_hash text NOT NULL, raw_payload jsonb, artifact_locator text,
 CHECK(raw_payload IS NOT NULL OR artifact_locator IS NOT NULL),
 FOREIGN KEY(record_id,dataset_id) REFERENCES sources.records(record_id,dataset_id),
 UNIQUE(record_id,content_hash), UNIQUE(record_version_id,dataset_id)
);
CREATE TABLE sources.capture_records (
 capture_id uuid NOT NULL, record_version_id uuid NOT NULL, dataset_id uuid NOT NULL,
 observation_locator text NOT NULL, PRIMARY KEY(capture_id,record_version_id),
 FOREIGN KEY(capture_id,dataset_id) REFERENCES sources.captures(capture_id,dataset_id),
 FOREIGN KEY(record_version_id,dataset_id) REFERENCES sources.record_versions(record_version_id,dataset_id)
);
CREATE TABLE sources.processing_runs (
 run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), run_kind text NOT NULL CHECK(run_kind IN ('normalize','match','geocode')),
 parent_run_id uuid REFERENCES sources.processing_runs, capture_id uuid REFERENCES sources.captures,
 processor_version text NOT NULL, config_hash text NOT NULL,
 started_at timestamptz NOT NULL DEFAULT clock_timestamp(), finished_at timestamptz,
 status text NOT NULL CHECK(status IN ('running','succeeded','failed')), CHECK(finished_at IS NULL OR finished_at>=started_at)
);
CREATE TABLE sources.normalized_subjects (
 subject_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), record_version_id uuid NOT NULL REFERENCES sources.record_versions,
 run_id uuid NOT NULL REFERENCES sources.processing_runs, subject_kind text NOT NULL,
 subject_locator text NOT NULL, normalized_payload jsonb NOT NULL,
 UNIQUE(run_id,record_version_id,subject_locator), UNIQUE(subject_id,subject_kind)
);
CREATE FUNCTION sources.check_interpretation_capture() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE capture uuid;
BEGIN
 SELECT capture_id INTO capture FROM sources.processing_runs WHERE run_id=NEW.run_id;
 IF capture IS NOT NULL AND NOT EXISTS(SELECT FROM sources.capture_records WHERE capture_id=capture AND record_version_id=NEW.record_version_id) THEN
  RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='interpretation_capture_mismatch';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER interpretation_capture BEFORE INSERT ON sources.normalized_subjects FOR EACH ROW EXECUTE FUNCTION sources.check_interpretation_capture();
CREATE TABLE sources.assertions (
 assertion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), subject_id uuid NOT NULL REFERENCES sources.normalized_subjects,
 attribute_code text NOT NULL, raw_value jsonb, normalized_value jsonb NOT NULL,
 language_code text, scope jsonb, valid_from date, valid_until date,
 certainty text NOT NULL CHECK(certainty IN ('stated','uncertain','unknown','explicitly_absent')),
 method text NOT NULL, CHECK(valid_until IS NULL OR valid_from IS NULL OR valid_until>=valid_from)
);
CREATE TABLE governance.match_candidates (
 candidate_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), run_id uuid NOT NULL REFERENCES sources.processing_runs,
 subject_id uuid NOT NULL REFERENCES sources.normalized_subjects, entity_id uuid NOT NULL REFERENCES data.entities,
 score double precision, features jsonb NOT NULL, status text NOT NULL CHECK(status IN ('proposed','accepted','rejected'))
);
CREATE TABLE governance.resolution_decisions (
 decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), operation text NOT NULL CHECK(operation IN ('link','unlink','merge','split')),
 actor_id uuid NOT NULL REFERENCES governance.actors, run_id uuid REFERENCES sources.processing_runs,
 reason text NOT NULL CHECK(btrim(reason)<>''), decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 previous_decision_id uuid REFERENCES governance.resolution_decisions
);
CREATE TABLE governance.resolution_members (
 decision_id uuid NOT NULL REFERENCES governance.resolution_decisions, subject_id uuid NOT NULL,
 entity_id uuid NOT NULL, entity_kind text NOT NULL, member_role text NOT NULL,
 PRIMARY KEY(decision_id,subject_id,entity_id,member_role),
 FOREIGN KEY(subject_id,entity_kind) REFERENCES sources.normalized_subjects(subject_id,subject_kind),
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind),
 UNIQUE(decision_id,subject_id,entity_id)
);
CREATE TABLE governance.subject_bindings (
 subject_id uuid NOT NULL, entity_id uuid NOT NULL, decision_id uuid NOT NULL,
 binding_state text NOT NULL CHECK(binding_state IN ('linked','unlinked')),
 PRIMARY KEY(subject_id,entity_id),
 FOREIGN KEY(decision_id,subject_id,entity_id) REFERENCES governance.resolution_members(decision_id,subject_id,entity_id)
);
CREATE TABLE governance.identity_aliases (
 alias_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), old_entity_id uuid NOT NULL REFERENCES data.entities,
 current_entity_id uuid REFERENCES data.entities, decision_id uuid NOT NULL REFERENCES governance.resolution_decisions,
 alias_kind text NOT NULL CHECK(alias_kind IN ('redirect','tombstone')), CHECK(old_entity_id IS DISTINCT FROM current_entity_id)
);
CREATE TABLE governance.value_decisions (
 value_decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), revision_id uuid NOT NULL, entity_id uuid NOT NULL,
 field_code text NOT NULL, component_id uuid,
 selection_kind text NOT NULL CHECK(selection_kind IN ('select','compose','unresolved')),
 policy_version text, actor_id uuid NOT NULL REFERENCES governance.actors,
 reason text NOT NULL CHECK(btrim(reason)<>''), decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id) REFERENCES data.components(component_id,owner_entity_id),
 UNIQUE(value_decision_id,revision_id), UNIQUE(value_decision_id,revision_id,entity_id),
 CHECK(selection_kind<>'unresolved' OR policy_version IS NULL)
);
CREATE TABLE governance.value_evidence (
 value_decision_id uuid NOT NULL REFERENCES governance.value_decisions,
 assertion_id uuid NOT NULL REFERENCES sources.assertions,
 evidence_role text NOT NULL CHECK(evidence_role IN ('supporting','contradicting','context')),
 PRIMARY KEY(value_decision_id,assertion_id,evidence_role)
);
CREATE FUNCTION governance.check_evidence_open() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE revision uuid;
BEGIN
 SELECT revision_id INTO STRICT revision FROM governance.value_decisions WHERE value_decision_id=NEW.value_decision_id;
 IF EXISTS(SELECT FROM governance.entity_revisions WHERE revision_id=revision AND sealed_at IS NOT NULL) THEN
  RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='sealed_revision_evidence';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER open_decision BEFORE INSERT ON governance.value_decisions FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision();
CREATE TRIGGER open_evidence BEFORE INSERT ON governance.value_evidence FOR EACH ROW EXECUTE FUNCTION governance.check_evidence_open();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['sources.registry','sources.datasets','sources.captures','sources.records','sources.record_versions','sources.capture_records','sources.processing_runs','sources.normalized_subjects','sources.assertions','governance.resolution_decisions','governance.resolution_members','governance.identity_aliases','governance.value_decisions','governance.value_evidence'] LOOP
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA sources,governance FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA sources,governance FROM PUBLIC;

COMMIT;
