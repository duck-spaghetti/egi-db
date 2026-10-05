-- Deploy egi_database:evidence [foundation] to pg
BEGIN;
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
