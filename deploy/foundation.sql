-- Deploy egi_database:foundation to pg
BEGIN;
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
COMMIT;
