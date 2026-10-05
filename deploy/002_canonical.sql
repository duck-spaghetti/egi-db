-- Deploy egi_database:002_canonical
BEGIN;

-- ============================================================================
-- Canonical
-- ============================================================================
CREATE TABLE geo.territories (
 entity_id uuid PRIMARY KEY,
 entity_kind text NOT NULL DEFAULT 'territory' CHECK(entity_kind='territory'),
 code text UNIQUE NOT NULL,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE geo.territory_revisions (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL,
 entity_kind text NOT NULL DEFAULT 'territory' CHECK(entity_kind='territory'),
 name_content_id uuid NOT NULL, timezone_name text NOT NULL,
 country_code text, boundary public.geometry(MultiPolygon,4326),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES geo.territories,
 FOREIGN KEY(name_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id)
);
CREATE TABLE data.organization_revisions (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL,
 entity_kind text NOT NULL DEFAULT 'organization' CHECK(entity_kind='organization'),
 name_content_id uuid, description_content_id uuid, organization_type text, website text,
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES data.organizations,
 FOREIGN KEY(name_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(description_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id)
);
CREATE TABLE geo.geocoding_results (
 result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), run_id uuid NOT NULL REFERENCES sources.processing_runs,
 provider text NOT NULL, provider_version text, request_hash text NOT NULL,
 input_address text NOT NULL, context jsonb NOT NULL, latitude double precision, longitude double precision,
 precision text NOT NULL, status text NOT NULL CHECK(status IN ('succeeded','failed','ambiguous','no_match')),
 payload_ref text NOT NULL, retrieved_at timestamptz NOT NULL,
 CHECK((latitude IS NULL)=(longitude IS NULL)), CHECK(latitude BETWEEN -90 AND 90), CHECK(longitude BETWEEN -180 AND 180),
 CHECK(status<>'succeeded' OR latitude IS NOT NULL)
);
CREATE TABLE geo.geocoding_cache (
 cache_key text PRIMARY KEY, provider text NOT NULL, request_hash text NOT NULL, context_hash text NOT NULL,
 result_id uuid NOT NULL REFERENCES geo.geocoding_results, expires_at timestamptz,
 UNIQUE(provider,request_hash,context_hash)
);
CREATE TABLE data.location_revisions (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL,
 entity_kind text NOT NULL DEFAULT 'location' CHECK(entity_kind='location'),
 name_content_id uuid, location_kind text NOT NULL,
 latitude double precision, longitude double precision,
 coordinate_state text NOT NULL CHECK(coordinate_state IN ('known','unknown','uncertain')),
 coordinate_decision_id uuid, selected_geocoding_result_id uuid REFERENCES geo.geocoding_results,
 parent_location_id uuid REFERENCES data.locations,
 point public.geometry(Point,4326) GENERATED ALWAYS AS
  (CASE WHEN longitude IS NOT NULL THEN public.ST_SetSRID(public.ST_MakePoint(longitude,latitude),4326) END) STORED,
 CHECK((latitude IS NULL)=(longitude IS NULL)), CHECK(latitude BETWEEN -90 AND 90), CHECK(longitude BETWEEN -180 AND 180),
 CHECK((coordinate_state='unknown')=(latitude IS NULL)), CHECK(parent_location_id IS DISTINCT FROM entity_id),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES data.locations,
 FOREIGN KEY(name_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(coordinate_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE INDEX location_points ON data.location_revisions USING gist(point);
CREATE TABLE data.service_revisions (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL,
 entity_kind text NOT NULL DEFAULT 'service' CHECK(entity_kind='service'),
 name_content_id uuid, description_content_id uuid,
 delivery_mode text NOT NULL CHECK(delivery_mode IN ('in_person','telephone','online','itinerant')),
 operational_status text NOT NULL DEFAULT 'unknown' CHECK(operational_status IN ('active','inactive','temporarily_closed','defunct','unknown')),
 cost_state text NOT NULL DEFAULT 'unknown' CHECK(cost_state IN ('free','paid','variable','unknown')),
 cost_note_content_id uuid, closure_date date, closure_reason_content_id uuid,
 valid_from date, valid_until date,
 CHECK(valid_until IS NULL OR valid_from IS NULL OR valid_until>=valid_from),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES data.services,
 FOREIGN KEY(name_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(description_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(cost_note_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(closure_reason_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id)
);
CREATE TABLE data.service_places (
 revision_id uuid PRIMARY KEY, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'place' CHECK(component_kind='place'),
 location_id uuid REFERENCES data.locations, territory_id uuid REFERENCES geo.territories,
 area_description_content_id uuid, value_decision_id uuid NOT NULL,
 CHECK((location_id IS NOT NULL)<>(area_description_content_id IS NOT NULL)),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(revision_id) REFERENCES data.service_revisions,
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(area_description_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.service_organizations (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'organization_role' CHECK(component_kind='organization_role'),
 organization_id uuid NOT NULL REFERENCES data.organizations, role_code text NOT NULL CHECK(btrim(role_code)<>''),
 value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.location_organizations (LIKE data.service_organizations INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES);
ALTER TABLE data.location_organizations ADD FOREIGN KEY(revision_id) REFERENCES data.location_revisions;
ALTER TABLE data.location_organizations ADD FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id);
ALTER TABLE data.location_organizations ADD FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind);
ALTER TABLE data.location_organizations ADD FOREIGN KEY(organization_id) REFERENCES data.organizations;
ALTER TABLE data.location_organizations ADD FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id);
CREATE TABLE data.contact_entries (
 revision_id uuid NOT NULL, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'contact' CHECK(component_kind='contact'),
 channel_type text NOT NULL CHECK(channel_type IN ('phone','email','web','whatsapp','other')),
 value text NOT NULL CHECK(btrim(value)<>''), normalized_value text,
 purpose_code text, label_content_id uuid, sort_order integer NOT NULL DEFAULT 0,
 is_public boolean NOT NULL DEFAULT true, value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(label_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.service_contact_links (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'contact_link' CHECK(component_kind='contact_link'),
 target_entity_id uuid NOT NULL, target_contact_component_id uuid NOT NULL,
 target_component_kind text NOT NULL DEFAULT 'contact' CHECK(target_component_kind='contact'),
 purpose_code text, label_content_id uuid, value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(target_contact_component_id,target_entity_id,target_component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(label_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.access_conditions (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'condition' CHECK(component_kind='condition'),
 condition_kind text NOT NULL CHECK(condition_kind IN ('appointment','referral','document','eligibility','other')),
 requirement_state text NOT NULL CHECK(requirement_state IN ('required','not_required','conditional','unknown')),
 details_content_id uuid, value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,component_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(details_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.addresses (
 revision_id uuid NOT NULL REFERENCES data.location_revisions, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'address' CHECK(component_kind='address'),
 address_kind text NOT NULL, formatted text NOT NULL CHECK(btrim(formatted)<>''),
 line1 text, locality text, postal_code text, administrative_area text, country_code text,
 normalization_state text NOT NULL CHECK(normalization_state IN ('raw','normalized','uncertain')),
 value_decision_id uuid NOT NULL, PRIMARY KEY(revision_id,component_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE data.service_languages (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL,
 language_code text NOT NULL, availability_kind text NOT NULL CHECK(availability_kind IN ('spoken','interpreted')),
 note_content_id uuid, value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,language_code,availability_kind),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(note_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE geo.service_memberships (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL,
 territory_id uuid NOT NULL REFERENCES geo.territories, membership_reason text NOT NULL,
 value_decision_id uuid NOT NULL, PRIMARY KEY(revision_id,territory_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE TABLE geo.service_coverage (
 revision_id uuid NOT NULL REFERENCES data.service_revisions, entity_id uuid NOT NULL, component_id uuid NOT NULL,
 component_kind text NOT NULL DEFAULT 'coverage' CHECK(component_kind='coverage'),
 territory_id uuid REFERENCES geo.territories, geometry public.geometry(MultiPolygon,4326),
 description_content_id uuid, value_decision_id uuid NOT NULL, PRIMARY KEY(revision_id,component_id),
 CHECK(territory_id IS NOT NULL OR geometry IS NOT NULL OR description_content_id IS NOT NULL),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(component_id,entity_id,component_kind) REFERENCES data.components(component_id,owner_entity_id,component_kind),
 FOREIGN KEY(description_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE FUNCTION governance.check_payload_content() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE entry record; field text; component uuid; payload jsonb:=to_jsonb(NEW);
BEGIN
 component:=NULLIF(payload->>'component_id','')::uuid;
 FOR entry IN SELECT key,value FROM jsonb_each_text(payload) WHERE key LIKE '%_content_id' AND value IS NOT NULL LOOP
  field:=replace(entry.key,'_content_id','');
  IF entry.key='label_content_id' THEN field:=CASE WHEN TG_TABLE_NAME='contact_entries' THEN 'contact_label' ELSE 'contact_link_label' END;
  ELSIF entry.key='details_content_id' THEN field:='condition_details';
  ELSIF TG_TABLE_NAME='service_coverage' AND entry.key='description_content_id' THEN field:='coverage_description';
  ELSIF TG_TABLE_NAME='service_languages' AND entry.key='note_content_id' THEN field:='language_'||(payload->>'language_code')||'_'||(payload->>'availability_kind');
  END IF;
  IF NOT EXISTS(SELECT FROM i18n.revision_content_links l WHERE l.revision_id=NEW.revision_id AND l.entity_id=NEW.entity_id AND l.field_code=field AND l.component_scope=COALESCE(component,'00000000-0000-0000-0000-000000000000'::uuid) AND l.content_id=entry.value::uuid) THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='payload_content_binding_mismatch';
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE FUNCTION geo.check_selected_coordinates() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.selected_geocoding_result_id IS NOT NULL AND NOT EXISTS(SELECT FROM geo.geocoding_results r WHERE r.result_id=NEW.selected_geocoding_result_id AND r.latitude IS NOT DISTINCT FROM NEW.latitude AND r.longitude IS NOT DISTINCT FROM NEW.longitude AND r.status IN ('succeeded','ambiguous')) THEN
  RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='selected_coordinates_mismatch';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER selected_coordinates BEFORE INSERT ON data.location_revisions FOR EACH ROW EXECUTE FUNCTION geo.check_selected_coordinates();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['geo.territory_revisions','data.organization_revisions','data.location_revisions','data.service_revisions','data.service_places','data.service_organizations','data.location_organizations','data.contact_entries','data.service_contact_links','data.access_conditions','data.addresses','data.service_languages','geo.service_memberships','geo.service_coverage'] LOOP
  EXECUTE format('CREATE TRIGGER content_binding BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION governance.check_payload_content()',t);
  EXECUTE format('CREATE TRIGGER open_revision BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision()',t);
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['geo.territories','geo.geocoding_results'] LOOP
  EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
END $$;
CREATE FUNCTION governance.publication_diagnostics(target uuid)
RETURNS TABLE(code text,field text) LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT 'missing_name','name' FROM data.service_revisions s LEFT JOIN i18n.content_units c ON c.content_id=s.name_content_id WHERE s.revision_id=target AND COALESCE(btrim(c.original_text),'')=''
 UNION ALL SELECT 'missing_description','description' FROM data.service_revisions s LEFT JOIN i18n.content_units c ON c.content_id=s.description_content_id WHERE s.revision_id=target AND COALESCE(btrim(c.original_text),'')=''
 UNION ALL SELECT 'missing_channel','contacts' FROM data.service_revisions s WHERE s.revision_id=target AND s.delivery_mode IN ('telephone','online') AND NOT EXISTS(SELECT FROM data.contact_entries c WHERE c.revision_id=target AND c.is_public AND ((s.delivery_mode='telephone' AND c.channel_type IN ('phone','whatsapp')) OR (s.delivery_mode='online' AND c.channel_type IN ('web','email'))))
 UNION ALL SELECT 'missing_place','place' FROM data.service_revisions s WHERE s.revision_id=target AND s.delivery_mode IN ('in_person','itinerant') AND NOT EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=target)
 UNION ALL SELECT 'missing_evidence','evidence' WHERE NOT EXISTS(SELECT FROM governance.value_decisions d JOIN governance.value_evidence e USING(value_decision_id) WHERE d.revision_id=target AND e.evidence_role='supporting')
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA data,geo FROM PUBLIC;

COMMIT;
