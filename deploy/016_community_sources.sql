-- Deploy egi_database:016_community_sources
-- requires: 015_preparation_history
-- EGI-102: non-confidential registry metadata and separate immutable Admin admission.
BEGIN;
CREATE TABLE editorial.community_source_requests (
 actor_id uuid NOT NULL REFERENCES governance.actors,
 request_key uuid NOT NULL,
 request_digest text NOT NULL,
 source_id uuid NOT NULL REFERENCES sources.registry,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(actor_id,request_key)
);
CREATE TABLE governance.community_source_admissions (
 source_id uuid PRIMARY KEY REFERENCES sources.registry,
 admitted_by uuid NOT NULL REFERENCES governance.actors,
 admitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 2000)
);
CREATE TRIGGER community_source_requests_immutable BEFORE UPDATE OR DELETE ON editorial.community_source_requests
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();
CREATE TRIGGER community_source_admissions_immutable BEFORE UPDATE OR DELETE ON governance.community_source_admissions
 FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();

CREATE FUNCTION editorial.register_community_source(metadata jsonb,key uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=governance.current_actor(); source uuid; old editorial.community_source_requests;
 digest text:=encode(sha256(convert_to(metadata::text,'UTF8')),'hex'); k text; v jsonb; bound integer;
BEGIN
 PERFORM access.require_editorial_login();
 IF NOT EXISTS(SELECT FROM access.accounts a JOIN governance.actors g USING(actor_id)
  WHERE a.actor_id=actor AND a.state='active' AND g.enabled) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='session_invalid'; END IF;
 IF key IS NULL OR jsonb_typeof(metadata) IS DISTINCT FROM 'object' OR NOT metadata ?& ARRAY['name','source_kind'] THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_metadata'; END IF;
 FOR k,v IN SELECT * FROM jsonb_each(metadata) LOOP
  bound:=CASE k WHEN 'name' THEN 200 WHEN 'source_kind' THEN 80 WHEN 'publisher' THEN 500
   WHEN 'homepage' THEN 2048 WHEN 'license' THEN 2000 WHEN 'attribution' THEN 4000 END;
  IF bound IS NULL OR (jsonb_typeof(v)<>'string' AND NOT (jsonb_typeof(v)='null' AND k NOT IN ('name','source_kind'))) OR
   length(v#>>'{}')>bound OR (k IN ('name','source_kind') AND COALESCE(length(btrim(v#>>'{}')),0)=0) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_source_metadata'; END IF;
 END LOOP;
 PERFORM pg_advisory_xact_lock(hashtextextended(actor::text||key::text,1));
 SELECT * INTO old FROM editorial.community_source_requests r WHERE r.actor_id=actor AND request_key=key;
 IF FOUND THEN
  IF old.request_digest<>digest THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='request_key_conflict'; END IF;
  RETURN jsonb_build_object('source_id',old.source_id);
 END IF;
 source:=gen_random_uuid();
 INSERT INTO sources.registry(source_id,code,name,publisher,source_kind,homepage,license,attribution)
  VALUES(source,'community-'||source::text,btrim(metadata->>'name'),NULLIF(btrim(metadata->>'publisher'),''),
   btrim(metadata->>'source_kind'),NULLIF(btrim(metadata->>'homepage'),''),NULLIF(btrim(metadata->>'license'),''),NULLIF(btrim(metadata->>'attribution'),''));
 INSERT INTO editorial.community_source_requests(actor_id,request_key,request_digest,source_id) VALUES(actor,key,digest,source);
 RETURN jsonb_build_object('source_id',source);
END $$;
CREATE FUNCTION editorial.admit_community_source(source uuid,reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admin access.accounts:=access.require_admin(); result jsonb;
BEGIN
 IF reason IS NULL OR length(btrim(reason)) NOT BETWEEN 1 AND 2000 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='source_admission_reason_required'; END IF;
 IF NOT EXISTS(SELECT FROM sources.registry WHERE source_id=source) THEN
  RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='source_not_found'; END IF;
 INSERT INTO governance.community_source_admissions(source_id,admitted_by,reason)
  VALUES(source,admin.actor_id,btrim(reason)) ON CONFLICT(source_id) DO NOTHING;
 SELECT to_jsonb(a) INTO result FROM governance.community_source_admissions a WHERE source_id=source;
 RETURN result;
END $$;
REVOKE ALL ON TABLE editorial.community_source_requests,governance.community_source_admissions FROM PUBLIC,egi_editorial;
REVOKE ALL ON FUNCTION editorial.register_community_source(jsonb,uuid),editorial.admit_community_source(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.register_community_source(jsonb,uuid),editorial.admit_community_source(uuid,text) TO egi_editorial;
GRANT SELECT ON governance.community_source_admissions TO egi_editorial;
COMMIT;
