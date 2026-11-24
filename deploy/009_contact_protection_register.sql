-- Deploy egi_database:009_contact_protection_register
-- requires: 008_contact_aliases
-- EGI-67: no historical inventory or backfill; see the scoped execution record.
BEGIN;

DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_privacy_moderator') THEN
  CREATE ROLE egi_privacy_moderator NOLOGIN;
 END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='egi_privacy_moderator'
           AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
  OR pg_has_role('egi_sync','egi_privacy_moderator','MEMBER')
  OR pg_has_role('egi_writer','egi_privacy_moderator','MEMBER')
  OR pg_has_role('egi_reader','egi_privacy_moderator','MEMBER') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='privacy_role_not_isolated';
 END IF;
END $$;
GRANT USAGE ON SCHEMA governance TO egi_privacy_moderator;

CREATE TABLE governance.contact_protections (
 protection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 origin_service_id uuid NOT NULL REFERENCES data.services,
 origin_revision_id uuid NOT NULL,
 origin_component_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('number','phone_hold')),
 number_key text,
 activation_publication_id uuid NOT NULL REFERENCES governance.publications,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 reason text NOT NULL CHECK(btrim(reason)<>''),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(origin_revision_id,origin_service_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(origin_revision_id,origin_component_id) REFERENCES data.contact_entries(revision_id,component_id),
 CHECK((kind='phone_hold' AND number_key IS NULL) OR
       (kind='number' AND number_key IS NOT NULL AND number_key ~ '^(0[0-9]{5,10}|3[0-9]{8,9}|80[0-9]{4,7}|1[0-9]{2,5})$'))
);
CREATE TABLE governance.contact_protection_scopes (
 scope_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 protection_id uuid NOT NULL REFERENCES governance.contact_protections,
 service_id uuid NOT NULL REFERENCES data.services,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 basis jsonb NOT NULL CHECK(jsonb_typeof(basis)='object'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(protection_id,scope_id,service_id)
);
CREATE TABLE governance.contact_protection_resolutions (
 resolution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 protection_id uuid NOT NULL REFERENCES governance.contact_protections,
 scope_id uuid,
 scope_service_id uuid REFERENCES data.services,
 resolution_service_id uuid NOT NULL REFERENCES data.services,
 resolution_revision_id uuid NOT NULL,
 publication_id uuid NOT NULL,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 reason text NOT NULL CHECK(btrim(reason)<>''),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((scope_id IS NULL)=(scope_service_id IS NULL)),
 FOREIGN KEY(publication_id,resolution_service_id,resolution_revision_id)
  REFERENCES governance.publications(publication_id,entity_id,revision_id),
 FOREIGN KEY(protection_id,scope_id,scope_service_id)
  REFERENCES governance.contact_protection_scopes(protection_id,scope_id,service_id)
);
-- Global releases are final for one protection; reapplication has a new scope ID.
CREATE UNIQUE INDEX contact_protection_global_release ON governance.contact_protection_resolutions(protection_id)
 WHERE scope_id IS NULL;
CREATE UNIQUE INDEX contact_protection_scope_release ON governance.contact_protection_resolutions(scope_id)
 WHERE scope_id IS NOT NULL;
-- Service lookup and active-origin matching are the register's bounded reads.
CREATE INDEX contact_protection_scope_service ON governance.contact_protection_scopes(service_id,protection_id);
CREATE INDEX contact_protection_origin ON governance.contact_protections(origin_service_id,origin_component_id,kind,number_key);
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON governance.contact_protections
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON governance.contact_protection_scopes
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON governance.contact_protection_resolutions
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();

-- These helpers recognize identities for suppression only, never dialable output.
-- Match the standard-library Unicode whitespace contract used by the importer.
CREATE FUNCTION governance.protection_phone_whitespace(value text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT btrim(regexp_replace(translate(COALESCE(value,''),U&'\0009\000A\000B\000C\000D\001C\001D\001E\001F\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000',repeat(' ',29)),' +',' ','g'))
$$;
CREATE FUNCTION governance.protection_phone_text(value text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT regexp_replace(governance.protection_phone_whitespace(value),'^(telefono|tel|whatsapp)[.]?[[:space:]]*:?[[:space:]]*','','i')
$$;
CREATE FUNCTION governance.protection_phone_key(value text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE printed text:=governance.protection_phone_text(value); digits text;
BEGIN
 IF printed LIKE '+39%' THEN printed:=btrim(substr(printed,4));
 ELSIF printed LIKE '0039%' THEN printed:=btrim(substr(printed,5)); END IF;
 IF printed ~ '^0[0-9]{1,3}/[0-9 .()-]+$' THEN printed:=replace(printed,'/',' '); END IF;
 IF printed !~ '^[+]?[0-9][0-9 .()-]*$' THEN RETURN NULL; END IF;
 digits:=regexp_replace(printed,'[^0-9]','','g');
 IF printed LIKE '+%' THEN RETURN NULL; END IF;
 IF length(digits)=12 AND digits LIKE '393%' THEN digits:=substr(digits,3); END IF;
 IF digits ~ '^(0[0-9]{5,10}|3[0-9]{8,9}|80[0-9]{4,7}|1[0-9]{2,5})$' THEN RETURN digits; END IF;
 RETURN NULL;
END $$;
CREATE FUNCTION governance.protection_phone_keys(value text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE printed text:=governance.protection_phone_text(value); single text; part text;
 pieces text[]; result text[]:=ARRAY[]::text[]; shorthand text[]; second_number text;
BEGIN
 single:=governance.protection_phone_key(printed);
 IF single IS NOT NULL THEN RETURN ARRAY[single]; END IF;
 pieces:=regexp_split_to_array(printed,'[[:space:]]*/[[:space:]]*');
 IF cardinality(pieces)>1 THEN
  FOREACH part IN ARRAY pieces LOOP
   single:=governance.protection_phone_key(part);
   IF single IS NULL THEN result:=ARRAY[]::text[]; EXIT; END IF;
   result:=array_append(result,single);
  END LOOP;
  IF cardinality(result)=cardinality(pieces) THEN
   RETURN ARRAY(SELECT DISTINCT key FROM unnest(result) AS a(key) ORDER BY key);
  END IF;
 END IF;
 shorthand:=regexp_match(printed,'^(.+)[[:space:]]*/[[:space:]]*([0-9]{1,3})$');
 IF shorthand IS NOT NULL THEN
  single:=governance.protection_phone_key(btrim(shorthand[1]));
  IF single IS NOT NULL AND length(shorthand[2])<length(single) THEN
   second_number:=left(single,length(single)-length(shorthand[2]))||shorthand[2];
   IF governance.protection_phone_key(second_number)=second_number THEN
    RETURN ARRAY(SELECT DISTINCT key FROM unnest(ARRAY[single,second_number]) AS a(key) ORDER BY key);
   END IF;
  END IF;
 END IF;
 RETURN ARRAY[]::text[];
END $$;
CREATE FUNCTION governance.protection_phone_labelled(value text,label text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT governance.protection_phone_whitespace(label) ~* '(^|[^[:alnum:]_])(telefono|tel[.]?|whatsapp)([^[:alnum:]_]|$)'
  OR governance.protection_phone_whitespace(value) ~* '^[[:space:]]*(telefono|tel|whatsapp)([.]|[[:space:]:]|$)'
$$;
CREATE FUNCTION governance.protection_contact_keys(channel text,value text,label text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN channel='other' AND NOT governance.protection_phone_labelled(value,label)
  AND governance.protection_phone_text(value) ~ '^(0?[1-9]|[12][0-9]|3[01])[[:space:]]*[/.-][[:space:]]*(0?[1-9]|1[0-2])[[:space:]]*[/.-][[:space:]]*[0-9]{4}$'
 THEN ARRAY[]::text[] ELSE governance.protection_phone_keys(value) END
$$;
CREATE FUNCTION governance.protection_phone_uncertain(channel text,value text,label text DEFAULT NULL)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN channel NOT IN ('phone','whatsapp','other') THEN false
  WHEN cardinality(governance.protection_contact_keys(channel,value,label))>0 THEN false
  WHEN channel IN ('phone','whatsapp') THEN true
  ELSE governance.protection_phone_labelled(value,label)
    OR (governance.protection_phone_text(value) !~ '^(0?[1-9]|[12][0-9]|3[01])[[:space:]]*[/.-][[:space:]]*(0?[1-9]|1[0-2])[[:space:]]*[/.-][[:space:]]*[0-9]{4}$'
        AND governance.protection_phone_text(value) ~ '^([+]39|0039)?[[:space:]]*(0|3|80|1)[0-9 ()/.-]{5,}')
 END
$$;
CREATE FUNCTION governance.protection_service_group(service uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 WITH RECURSIVE links AS MATERIALIZED (
  SELECT principal_id,secondary_id FROM governance.resolved_source_links() WHERE relation='same'
 ), members(id) AS (
  SELECT service
  UNION
  SELECT CASE WHEN l.principal_id=m.id THEN l.secondary_id ELSE l.principal_id END
  FROM members m JOIN links l ON l.principal_id=m.id OR l.secondary_id=m.id
 ) SELECT id FROM members
$$;

-- Read-time current-private protection makes the empty-register start safe.
-- Once captured, register decisions (including explicit resolutions) govern it.
CREATE FUNCTION governance.effective_contact_protections(service uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 WITH members AS MATERIALIZED (SELECT governance.protection_service_group(service) AS id),
 active AS MATERIALIZED (
  SELECT DISTINCT p.* FROM governance.contact_protections p
  JOIN governance.contact_protection_scopes s ON s.protection_id=p.protection_id AND s.service_id=service
  WHERE NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r
    WHERE r.protection_id=p.protection_id AND r.scope_service_id IS NULL)
   AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r
    WHERE r.scope_id=s.scope_id)
 ), live AS MATERIALIZED (
  SELECT c.entity_id,c.value,c.channel_type,label.original_text AS label,
   governance.protection_contact_keys(c.channel_type,c.value,label.original_text) AS numbers
  FROM members m JOIN governance.published_heads h ON h.entity_id=m.id
  JOIN data.contact_entries c ON c.revision_id=h.revision_id
  LEFT JOIN i18n.content_units label ON label.content_id=c.label_content_id
  WHERE NOT c.is_public AND c.channel_type IN('phone','whatsapp','other')
   AND NOT EXISTS(SELECT FROM governance.contact_protections p
     WHERE p.origin_service_id=c.entity_id AND p.origin_component_id=c.component_id)
 ), numbers AS (
  SELECT number_key AS key FROM active WHERE kind='number'
  UNION SELECT unnest(numbers) FROM live
 ), holds AS (
  SELECT origin_service_id AS owner FROM active WHERE kind='phone_hold'
  UNION SELECT entity_id FROM live
   WHERE governance.protection_phone_uncertain(channel_type,value,label)
 )
 SELECT jsonb_build_object('numbers',COALESCE((SELECT jsonb_agg(key ORDER BY key) FROM numbers),'[]'),
  'phone_hold',EXISTS(SELECT FROM holds),
  'inherited_phone_hold',EXISTS(SELECT FROM holds WHERE owner<>service),
  'protection_ids',COALESCE((SELECT jsonb_agg(protection_id ORDER BY protection_id) FROM active),'[]'))
$$;
CREATE FUNCTION governance.contact_allowed_by_protection(state jsonb,channel text,value text,label text,secondary boolean)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT NOT EXISTS(SELECT FROM unnest(governance.protection_phone_keys(value)) AS k(key)
                    WHERE state->'numbers' ? k.key)
  AND NOT ((COALESCE((state->>'inherited_phone_hold')::boolean,false)
             OR (secondary AND COALESCE((state->>'phone_hold')::boolean,false)))
       AND (channel IN('phone','whatsapp') OR (channel='other' AND
        (cardinality(governance.protection_contact_keys(channel,value,label))>0 OR
         governance.protection_phone_uncertain(channel,value,label)))))
$$;
CREATE FUNCTION governance.read_contact_protections(service uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE scopes uuid[]; affected uuid;
BEGIN
 IF NOT EXISTS(SELECT FROM data.services WHERE entity_id=service) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unknown_service';
 END IF;
 FOR affected IN
  SELECT service
  UNION SELECT governance.protection_service_group(service)
  UNION SELECT p.origin_service_id FROM governance.contact_protections p
   JOIN governance.contact_protection_scopes s ON s.protection_id=p.protection_id
   WHERE s.service_id=service
    AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r
     WHERE r.protection_id=p.protection_id AND r.scope_id IS NULL)
    AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id)
 LOOP
  SELECT array_agg(t) INTO scopes FROM governance.affected_territories(affected,
   (SELECT revision_id FROM governance.published_heads WHERE entity_id=affected)) t;
  PERFORM governance.require_capability('publish',scopes);
 END LOOP;
 RETURN governance.effective_contact_protections(service);
END $$;


CREATE FUNCTION governance.propagate_contact_protection_scopes() RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE protection record; member uuid; member_ids uuid[]; basis jsonb;
BEGIN
 PERFORM governance.lock_operation();
 FOR protection IN SELECT p.* FROM governance.contact_protections p
  WHERE NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r
   WHERE r.protection_id=p.protection_id AND r.scope_id IS NULL) LOOP
  WITH seeds AS (
   SELECT protection.origin_service_id AS service_id
   UNION SELECT s.service_id FROM governance.contact_protection_scopes s
    WHERE s.protection_id=protection.protection_id
     AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id)
  ) SELECT array_agg(DISTINCT m.id) INTO member_ids FROM seeds CROSS JOIN LATERAL
     governance.protection_service_group(seeds.service_id) AS m(id);
  SELECT jsonb_build_object('kind','same_service','links',COALESCE(jsonb_agg(to_jsonb(l)),'[]')) INTO basis
   FROM governance.resolved_source_links() l WHERE l.relation='same'
    AND l.principal_id=ANY(member_ids) AND l.secondary_id=ANY(member_ids);
  FOREACH member IN ARRAY member_ids LOOP
   IF NOT EXISTS(SELECT FROM governance.contact_protection_scopes s
    WHERE s.protection_id=protection.protection_id AND s.service_id=member
     AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r WHERE r.scope_id=s.scope_id)) THEN
    INSERT INTO governance.contact_protection_scopes(protection_id,service_id,actor_id,basis)
     VALUES(protection.protection_id,member,governance.current_actor(),basis);
    INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason)
     VALUES(member,protection.activation_publication_id,'service','contact_protection_scope');
   END IF;
  END LOOP;
 END LOOP;
END $$;


CREATE FUNCTION governance.capture_private_contact_revision(revision uuid,publication uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE contact record; key text; keys text[]; protection uuid; protection_kind text;
BEGIN
 FOR contact IN SELECT c.*,label.original_text AS label
  FROM data.contact_entries c JOIN data.services s ON s.entity_id=c.entity_id
  LEFT JOIN i18n.content_units label ON label.content_id=c.label_content_id
  WHERE c.revision_id=revision AND NOT c.is_public AND c.channel_type IN('phone','whatsapp','other') LOOP
  keys:=governance.protection_contact_keys(contact.channel_type,contact.value,contact.label);
  IF cardinality(keys)=0 AND governance.protection_phone_uncertain(contact.channel_type,contact.value,contact.label) THEN
   keys:=ARRAY[NULL::text];
  END IF;
  FOREACH key IN ARRAY keys LOOP
   protection_kind:=CASE WHEN key IS NULL THEN 'phone_hold' ELSE 'number' END;
   SELECT p.protection_id INTO protection FROM governance.contact_protections p
    WHERE p.origin_service_id=contact.entity_id AND p.origin_component_id=contact.component_id
     AND p.kind=protection_kind AND p.number_key IS NOT DISTINCT FROM key
     AND NOT EXISTS(SELECT FROM governance.contact_protection_resolutions r
      WHERE r.protection_id=p.protection_id AND r.scope_service_id IS NULL) LIMIT 1;
   IF protection IS NULL THEN
    INSERT INTO governance.contact_protections(origin_service_id,origin_revision_id,origin_component_id,kind,
     number_key,activation_publication_id,actor_id,reason)
    VALUES(contact.entity_id,revision,contact.component_id,protection_kind,key,publication,governance.current_actor(),
     'Preserve a private contact from revision '||revision::text);
   END IF;
  END LOOP;
 END LOOP;
END $$;

-- Retain current context before withdrawal, unlinking or source identity rebinding.
-- This is mutation-time protection, not a historical inventory/backfill at deploy.
CREATE FUNCTION governance.retain_current_contact_protections(service uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE head record;
BEGIN
 PERFORM governance.lock_operation();
 FOR head IN SELECT h.revision_id,h.publication_id
  FROM governance.protection_service_group(service) AS m(id)
  JOIN data.services s ON s.entity_id=m.id
  JOIN governance.published_heads h ON h.entity_id=s.entity_id LOOP
  PERFORM governance.capture_private_contact_revision(head.revision_id,head.publication_id);
 END LOOP;
 PERFORM governance.propagate_contact_protection_scopes();
END $$;
CREATE FUNCTION governance.retain_contact_protection_context() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE service uuid; source uuid; keys text[];
BEGIN
 PERFORM governance.lock_operation();
 IF TG_TABLE_NAME='published_heads' THEN
  PERFORM governance.retain_current_contact_protections(OLD.entity_id);
  RETURN OLD;
 ELSIF TG_TABLE_NAME='source_service_links' THEN
  FOR service IN
   SELECT e.service_id FROM governance.sync_entries e JOIN governance.sync_versions v USING(version_id)
    WHERE v.published AND e.service_id IS NOT NULL AND
     ((v.dataset_id=NEW.a_dataset_id AND e.identity->'keys' ? NEW.a_key)
       OR (v.dataset_id=NEW.b_dataset_id AND e.identity->'keys' ? NEW.b_key))
   GROUP BY e.service_id LOOP
   PERFORM governance.retain_current_contact_protections(service);
  END LOOP;
 ELSIF TG_TABLE_NAME='sync_entries' THEN
  IF NEW.service_id IS NOT NULL THEN PERFORM governance.retain_current_contact_protections(NEW.service_id); END IF;
  SELECT dataset_id INTO source FROM governance.sync_versions WHERE version_id=NEW.version_id;
  SELECT array_agg(key) INTO keys FROM jsonb_array_elements_text(NEW.identity->'keys') AS a(key);
  FOR service IN
   SELECT DISTINCT e.service_id FROM governance.sync_entries e JOIN governance.sync_versions v USING(version_id)
    WHERE v.published AND v.dataset_id=source AND e.version_id<>NEW.version_id
      AND e.service_id IS NOT NULL AND e.identity->'keys' ?| COALESCE(keys,ARRAY[]::text[]) LOOP
   PERFORM governance.retain_current_contact_protections(service);
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER retain_contact_protections BEFORE DELETE ON governance.published_heads
 FOR EACH ROW EXECUTE FUNCTION governance.retain_contact_protection_context();
CREATE TRIGGER retain_contact_protection_links BEFORE INSERT ON governance.source_service_links
 FOR EACH ROW EXECUTE FUNCTION governance.retain_contact_protection_context();
CREATE TRIGGER retain_contact_protection_identity BEFORE INSERT ON governance.sync_entries
 FOR EACH ROW EXECUTE FUNCTION governance.retain_contact_protection_context();

-- Publication already owns the existing global write lock through lock_expected.
-- Capture retains the old public private values before changing heads.
CREATE FUNCTION governance.capture_publication_contact_protections() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE previous uuid;
BEGIN
 PERFORM governance.lock_operation();
 IF EXISTS(SELECT FROM data.services WHERE entity_id=NEW.entity_id) THEN
  SELECT revision_id INTO previous FROM governance.published_heads WHERE entity_id=NEW.entity_id;
  IF previous IS NOT NULL THEN PERFORM governance.capture_private_contact_revision(previous,NEW.publication_id); END IF;
  PERFORM governance.capture_private_contact_revision(NEW.revision_id,NEW.publication_id);
  PERFORM governance.propagate_contact_protection_scopes();
 END IF;
 RETURN NEW;
END $$;
-- AFTER INSERT is still before publish_revision changes published_heads, and the
-- new publication must exist for immutable protection evidence foreign keys.
CREATE TRIGGER capture_contact_protections AFTER INSERT ON governance.publications
 FOR EACH ROW EXECUTE FUNCTION governance.capture_publication_contact_protections();
CREATE FUNCTION governance.refresh_contact_protection_scopes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM governance.propagate_contact_protection_scopes();
 RETURN NULL;
END $$;
CREATE TRIGGER contact_protection_links AFTER INSERT ON governance.source_service_links
 FOR EACH STATEMENT EXECUTE FUNCTION governance.refresh_contact_protection_scopes();
CREATE TRIGGER contact_protection_source_identity AFTER INSERT ON governance.sync_entries
 FOR EACH STATEMENT EXECUTE FUNCTION governance.refresh_contact_protection_scopes();

CREATE FUNCTION governance.publish_contact_protection_resolution(
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



CREATE OR REPLACE FUNCTION api.service_detail(service uuid,preferred text DEFAULT NULL,instant timestamptz DEFAULT statement_timestamp(),review_after interval DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 WITH guard AS MATERIALIZED (SELECT governance.effective_contact_protections(service) AS state)
 SELECT jsonb_build_object('service_id',s.entity_id,'revision_id',s.revision_id,'publication_id',h.publication_id,'snapshot_sequence',(SELECT snapshot_sequence FROM api.public_sequence),
 'name',api.resolve_text(s.name_content_id,preferred),'description',api.resolve_text(s.description_content_id,preferred),'delivery_mode',s.delivery_mode,'operational_status',s.operational_status,'cost',jsonb_build_object('state',s.cost_state,'note',api.resolve_text(s.cost_note_content_id,preferred)),
 'valid_from',s.valid_from,'valid_until',s.valid_until,'closure_date',s.closure_date,'closure_reason',api.resolve_text(s.closure_reason_content_id,preferred),
 'place',(SELECT jsonb_build_object('location_id',p.location_id,'territory_id',p.territory_id,'area_description',api.resolve_text(p.area_description_content_id,preferred),'location_revision_id',l.revision_id,'name',api.resolve_text(l.name_content_id,preferred),'coordinate_state',l.coordinate_state,'latitude',l.latitude,'longitude',l.longitude,'parent_location_id',l.parent_location_id,'addresses',COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',a.address_kind,'formatted',a.formatted,'line1',a.line1,'locality',a.locality,'postal_code',a.postal_code,'administrative_area',a.administrative_area,'country_code',a.country_code) ORDER BY a.component_id) FROM data.addresses a WHERE a.revision_id=l.revision_id),'[]'::jsonb)) FROM data.service_places p LEFT JOIN governance.published_heads lh ON lh.entity_id=p.location_id LEFT JOIN data.location_revisions l ON l.revision_id=lh.revision_id WHERE p.revision_id=s.revision_id),
 'organizations',COALESCE((SELECT jsonb_agg(jsonb_build_object('organization_id',o.organization_id,'role',o.role_code,'revision_id',org.revision_id,'name',api.resolve_text(org.name_content_id,preferred),'description',api.resolve_text(org.description_content_id,preferred),'website',org.website) ORDER BY o.component_id) FROM data.service_organizations o JOIN governance.published_heads oh ON oh.entity_id=o.organization_id JOIN data.organization_revisions org ON org.revision_id=oh.revision_id WHERE o.revision_id=s.revision_id),'[]'::jsonb),
 'contacts',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',ep.component_id,'link_component_id',ep.link_component_id,'subject_entity_id',ep.subject_entity_id,'scope',ep.subject_scope,'channel',ep.channel_type,'value',ep.value,'purpose',ep.purpose_code,'label',api.resolve_text(ep.label_content_id,preferred),'opening',api.opening(ep.subject_entity_id,instant,'contact',ep.component_id),
 'verification',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'component_id',v.component_id,'field',v.field_code,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END)) FROM governance.verifications v JOIN governance.published_heads vh ON vh.revision_id=v.revision_id WHERE vh.entity_id=ep.subject_entity_id AND (v.scope_kind='page' OR v.component_id=ep.component_id OR (v.scope_kind='field' AND v.field_code='contact'))),'[]'::jsonb)) ORDER BY ep.sort_order,ep.component_id,ep.link_component_id)
 FROM (
 SELECT c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,c.label_content_id,c.sort_order,NULL::uuid AS link_component_id FROM data.contact_entries c WHERE c.revision_id=s.revision_id AND c.is_public
 UNION ALL
 SELECT c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(link.label_content_id,c.label_content_id),c.sort_order,link.component_id FROM data.service_contact_links link JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id JOIN data.entities e ON e.entity_id=c.entity_id WHERE link.revision_id=s.revision_id AND c.is_public
 )ep WHERE governance.contact_allowed_by_protection((SELECT state FROM guard),ep.channel_type,ep.value,
 (SELECT original_text FROM i18n.content_units WHERE content_id=ep.label_content_id),false)),'[]'::jsonb),
 'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,'kind',c.condition_kind,'state',c.requirement_state,'details',api.resolve_text(c.details_content_id,preferred)) ORDER BY c.component_id) FROM data.access_conditions c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'service_languages',COALESCE((SELECT jsonb_agg(jsonb_build_object('language',l.language_code,'availability',l.availability_kind,'note',api.resolve_text(l.note_content_id,preferred))) FROM data.service_languages l WHERE l.revision_id=s.revision_id),'[]'::jsonb),
 'territories',COALESCE((SELECT jsonb_agg(m.territory_id ORDER BY m.territory_id) FROM geo.service_memberships m WHERE m.revision_id=s.revision_id),'[]'::jsonb),
 'coverage',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',c.territory_id,'geometry',public.ST_AsGeoJSON(c.geometry)::jsonb,'description',api.resolve_text(c.description_content_id,preferred))) FROM geo.service_coverage c WHERE c.revision_id=s.revision_id),'[]'::jsonb),
 'classifications',COALESCE((SELECT jsonb_agg(jsonb_build_object('territory_id',a.territory_id,'adoption_id',a.adoption_id,'release_id',a.release_id,'term_id',a.term_id,'axis',ax.code,'label',api.resolve_text(l.content_id,preferred))) FROM taxonomy.assignments a JOIN taxonomy.release_terms rt USING(release_id,term_id) JOIN taxonomy.terms t ON t.entity_id=a.term_id JOIN taxonomy.axes ax ON ax.axis_id=t.axis_id JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id AND l.field_code='name' WHERE a.revision_id=s.revision_id),'[]'::jsonb),
 'weekly_hours',COALESCE((SELECT jsonb_agg(to_jsonb(w)-'entity_id'-'revision_id' ORDER BY w.schedule_id,w.iso_weekday,w.opens_at) FROM api.weekly_hours w WHERE w.revision_id=s.revision_id),'[]'::jsonb),'opening',api.opening(s.entity_id,instant),
 'sources',COALESCE((SELECT jsonb_agg(to_jsonb(a)-'entity_id'-'revision_id') FROM api.source_attributions a WHERE a.entity_id=s.entity_id),'[]'::jsonb),
 'verification',jsonb_build_object('checks',COALESCE((SELECT jsonb_agg(jsonb_build_object('scope',v.scope_kind,'field',v.field_code,'component_id',v.component_id,'checked_at',v.checked_at,'outcome',v.outcome,'warning',CASE WHEN review_after IS NULL THEN 'threshold_not_configured' WHEN v.checked_at+review_after<instant THEN 'review_due' ELSE NULL END) ORDER BY v.checked_at) FROM governance.verifications v WHERE v.revision_id=s.revision_id),'[]'::jsonb),'page_state',CASE WHEN EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id AND v.scope_kind='page' AND v.outcome='confirmed') THEN 'verified_with_scope' ELSE 'unverified' END,'warning',CASE WHEN NOT EXISTS(SELECT FROM governance.verifications v WHERE v.revision_id=s.revision_id) THEN 'no_verification' WHEN review_after IS NULL THEN 'threshold_not_configured' ELSE NULL END))
 FROM governance.published_heads h JOIN data.service_revisions s USING(revision_id) WHERE s.entity_id=service
$$;

CREATE OR REPLACE FUNCTION api.linked_service_supplements(principal uuid DEFAULT NULL,preferred text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 WITH active AS (
  SELECT DISTINCT ON(dataset_id) * FROM governance.sync_versions WHERE published
  ORDER BY dataset_id,version_sequence DESC
 ), links AS MATERIALIZED (
  SELECT * FROM governance.resolved_source_links() WHERE relation='same'
 ), eligible AS (
  SELECT DISTINCT l.principal_id,e.service_id,e.source_body->'revisions'->>'service' AS revision,
    r.code,r.name
  FROM links l JOIN governance.published_heads h ON h.entity_id=l.principal_id
  JOIN data.service_revisions public_service ON public_service.revision_id=h.revision_id
  JOIN active v ON true JOIN governance.sync_entries e ON e.version_id=v.version_id AND e.service_id=l.secondary_id
  JOIN governance.working_heads w ON w.entity_id=e.service_id AND w.revision_id=(e.source_body->'revisions'->>'service')::uuid
  JOIN governance.entity_revisions rev ON rev.revision_id=w.revision_id AND rev.sealed_at IS NOT NULL
  JOIN sources.datasets ds ON ds.dataset_id=v.dataset_id JOIN sources.registry r USING(source_id)
  JOIN LATERAL (SELECT outcome FROM governance.review_decisions d WHERE d.target_revision_id=w.revision_id
                ORDER BY decision_sequence DESC LIMIT 1) reviewed ON reviewed.outcome='approved'
  LEFT JOIN LATERAL (SELECT action,details->>'cause' AS cause FROM audit.events a
                    WHERE a.entity_id=e.service_id AND a.action IN('withdraw','publish')
                    ORDER BY event_id DESC LIMIT 1) last_action ON true
  WHERE e.state='loaded' AND (principal IS NULL OR l.principal_id=principal)
    AND public_service.operational_status<>'defunct'
    AND NOT EXISTS(SELECT FROM governance.published_heads own WHERE own.entity_id=e.service_id)
    AND NOT EXISTS(SELECT FROM links chain WHERE chain.secondary_id=l.principal_id)
    AND NOT COALESCE(last_action.action='withdraw' AND last_action.cause='moderation',false)
 ), protected AS MATERIALIZED (
  SELECT eligible.*,governance.effective_contact_protections(principal_id) AS guard FROM eligible
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('principal_id',e.principal_id,'service_id',e.service_id,
  'revision_id',e.revision,'source_code',e.code,'source_name',e.name,
  'contacts',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'channel',c.channel_type,'value',c.value,'purpose',c.purpose_code,
     'label',governance.supplement_text(c.label_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.sort_order,c.component_id)
     FROM data.contact_entries c WHERE c.revision_id=e.revision::uuid AND c.is_public
      AND governance.contact_allowed_by_protection(e.guard,c.channel_type,c.value,
       (SELECT original_text FROM i18n.content_units WHERE content_id=c.label_content_id),true)
      AND NOT EXISTS(SELECT FROM governance.published_heads ph
       JOIN data.contact_entries hidden ON hidden.revision_id=ph.revision_id
       WHERE ph.entity_id=e.principal_id AND NOT hidden.is_public
        AND governance.contact_aliases(hidden.channel_type,hidden.value)
          && governance.contact_aliases(c.channel_type,c.value))),'[]'),
  'conditions',COALESCE((SELECT jsonb_agg(jsonb_build_object('component_id',c.component_id,
     'kind',c.condition_kind,'state',c.requirement_state,
     'details',governance.supplement_text(c.details_content_id,e.revision::uuid,preferred),
     'sources',governance.supplement_provenance(c.value_decision_id)) ORDER BY c.component_id)
     FROM data.access_conditions c WHERE c.revision_id=e.revision::uuid),'[]')) ORDER BY e.principal_id,e.service_id),'[]')
 FROM protected e
$$;

CREATE FUNCTION api.service_contact_visible(service uuid,subject uuid,component uuid,contact_link uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 WITH candidate AS MATERIALIZED (
  SELECT c.channel_type,c.value,label.original_text AS label FROM governance.published_heads h
  JOIN data.contact_entries c ON c.revision_id=h.revision_id
  LEFT JOIN i18n.content_units label ON label.content_id=c.label_content_id
  WHERE h.entity_id=subject AND c.component_id=component AND c.is_public
 ), association AS (
  SELECT c.* FROM candidate c WHERE subject=service AND contact_link IS NULL
  UNION ALL
  SELECT c.channel_type,c.value,COALESCE(label.original_text,c.label) FROM candidate c
   JOIN governance.published_heads h ON h.entity_id=service
   JOIN data.service_contact_links l ON l.revision_id=h.revision_id
   LEFT JOIN i18n.content_units label ON label.content_id=l.label_content_id
   WHERE l.component_id=contact_link AND l.target_entity_id=subject AND l.target_contact_component_id=component
 ) SELECT EXISTS(SELECT FROM association a
  WHERE EXISTS(SELECT FROM governance.published_heads h JOIN data.services ds ON ds.entity_id=h.entity_id
               WHERE h.entity_id=service)
   AND governance.contact_allowed_by_protection(governance.effective_contact_protections(service),
     a.channel_type,a.value,a.label,false))
$$;
REVOKE ALL ON FUNCTION api.service_contact_visible(uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.service_contact_visible(uuid,uuid,uuid,uuid) TO egi_reader;

CREATE OR REPLACE VIEW api.service_contacts WITH(security_barrier=true) AS
 SELECT s.entity_id AS service_id,c.component_id,c.entity_id AS subject_entity_id,'service'::text AS subject_scope,c.channel_type,c.value,c.purpose_code,l.original_text AS label,c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.contact_entries c ON c.revision_id=s.revision_id LEFT JOIN i18n.content_units l ON l.content_id=c.label_content_id WHERE c.is_public AND api.service_contact_visible(s.entity_id,c.entity_id,c.component_id,NULL::uuid)
 UNION ALL SELECT s.entity_id,c.component_id,c.entity_id,e.entity_kind,c.channel_type,c.value,COALESCE(link.purpose_code,c.purpose_code),COALESCE(ll.original_text,cl.original_text),c.sort_order
 FROM governance.published_heads h JOIN data.service_revisions s ON s.revision_id=h.revision_id JOIN data.service_contact_links link ON link.revision_id=s.revision_id
 JOIN governance.published_heads target ON target.entity_id=link.target_entity_id JOIN data.contact_entries c ON c.revision_id=target.revision_id AND c.component_id=link.target_contact_component_id
 JOIN data.entities e ON e.entity_id=c.entity_id LEFT JOIN i18n.content_units ll ON ll.content_id=link.label_content_id LEFT JOIN i18n.content_units cl ON cl.content_id=c.label_content_id WHERE c.is_public AND api.service_contact_visible(s.entity_id,c.entity_id,c.component_id,link.component_id);

CREATE OR REPLACE FUNCTION governance.public_content(content uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM i18n.content_units c JOIN i18n.revision_content_links l USING(content_id) JOIN governance.published_heads h USING(revision_id) WHERE c.content_id=content AND NOT EXISTS(SELECT FROM data.contact_entries p WHERE p.revision_id=h.revision_id AND p.component_id=c.component_id AND (NOT p.is_public OR (p.entity_id IN(SELECT entity_id FROM data.services)
 AND NOT governance.contact_allowed_by_protection(governance.effective_contact_protections(p.entity_id),
 p.channel_type,p.value,(SELECT original_text FROM i18n.content_units WHERE content_id=p.label_content_id),false))))
 AND NOT EXISTS(SELECT FROM data.service_contact_links link
  WHERE link.revision_id=h.revision_id AND link.component_id=c.component_id
   AND NOT api.service_contact_visible(link.entity_id,link.target_entity_id,
     link.target_contact_component_id,link.component_id)))
 OR EXISTS(SELECT FROM taxonomy.release_terms rt JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id JOIN taxonomy.territory_adoptions a USING(release_id) WHERE l.content_id=content)
$$;

REVOKE ALL ON governance.contact_protections,governance.contact_protection_scopes,
 governance.contact_protection_resolutions FROM PUBLIC,egi_reader,egi_writer,egi_sync;
DO $$ DECLARE operation regprocedure; BEGIN
 FOR operation IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='governance' AND p.proname IN('protection_phone_whitespace','protection_phone_text','protection_phone_key','protection_phone_keys','protection_phone_uncertain','protection_phone_labelled','protection_contact_keys','protection_service_group','effective_contact_protections','contact_allowed_by_protection','read_contact_protections','retain_current_contact_protections','retain_contact_protection_context','propagate_contact_protection_scopes','capture_private_contact_revision','capture_publication_contact_protections','refresh_contact_protection_scopes','publish_contact_protection_resolution') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',operation);
 END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION governance.read_contact_protections(uuid) TO egi_sync,egi_privacy_moderator;
GRANT EXECUTE ON FUNCTION governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text)
 TO egi_privacy_moderator;
-- No login membership, historical query or historical population is performed.
COMMIT;
