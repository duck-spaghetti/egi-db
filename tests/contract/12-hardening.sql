-- Every exposed function is called beside shadowing temporary types whose check only
-- reports whether it runs as someone other than the caller. NULL arguments can stop a
-- function early, so the first assertion also covers every function's setting.
BEGIN;
\ir helpers.sql
SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f'
 AND NOT COALESCE('search_path=pg_catalog, pg_temp'=ANY(p.proconfig),false)),'every function names pg_temp last');

CREATE ROLE egi_probe_reader LOGIN IN ROLE egi_reader;
CREATE ROLE egi_probe_writer LOGIN IN ROLE egi_writer;
CREATE ROLE egi_probe_sync LOGIN IN ROLE egi_sync;
SELECT pg_temp.assert_true(bool_and(NOT has_database_privilege(r,current_database(),'TEMPORARY')),'no login creates temporary objects')
 FROM unnest(ARRAY['egi_probe_reader','egi_probe_writer','egi_probe_sync']) r;

CREATE TEMP TABLE probe_calls AS
 SELECT r.role_name, p.oid::regprocedure::text AS signature,
  format('SELECT %I.%I(%s)',n.nspname,p.proname,COALESCE((
   SELECT string_agg(format('NULL::%I.%I',tn.nspname,t.typname),',' ORDER BY a.position)
   FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(type_id,position)
   JOIN pg_type t ON t.oid=a.type_id JOIN pg_namespace tn ON tn.oid=t.typnamespace),'')) AS call
 FROM (VALUES('egi_probe_reader'),('egi_probe_writer'),('egi_probe_sync')) r(role_name)
 CROSS JOIN pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f'
 AND p.prorettype<>'trigger'::regtype
 AND has_schema_privilege(r.role_name,n.oid,'USAGE') AND has_function_privilege(r.role_name,p.oid,'EXECUTE');
GRANT SELECT ON probe_calls TO PUBLIC;
SELECT pg_temp.assert_true(count(DISTINCT role_name)=3,'each role has functions to probe') FROM probe_calls;

CREATE FUNCTION pg_temp.foreign_rights() RETURNS pg_catalog.bool LANGUAGE plpgsql AS $$
BEGIN
 IF current_user<>session_user THEN RAISE EXCEPTION USING ERRCODE='EG001',MESSAGE='evaluated_with_other_rights'; END IF;
 RETURN true;
END $$;
CREATE FUNCTION pg_temp.probe_hits() RETURNS pg_catalog.int4 LANGUAGE plpgsql AS $$
DECLARE target pg_catalog.text; hits pg_catalog.int4:=0;
BEGIN
 FOR target IN SELECT c.call FROM pg_temp.probe_calls c WHERE c.role_name=session_user LOOP
  BEGIN EXECUTE target;
  EXCEPTION
   WHEN SQLSTATE 'EG001' THEN hits:=hits+1; RAISE NOTICE 'shadowed: %',target;
   WHEN OTHERS THEN NULL; -- NULL arguments and missing capabilities are expected
  END;
 END LOOP;
 RETURN hits;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.assert_true(boolean,text),pg_temp.foreign_rights(),pg_temp.probe_hits() TO PUBLIC;
CREATE DOMAIN pg_temp.uuid AS pg_catalog.uuid CHECK(pg_temp.foreign_rights());
CREATE DOMAIN pg_temp.text AS pg_catalog.text CHECK(pg_temp.foreign_rights());
CREATE DOMAIN pg_temp.jsonb AS pg_catalog.jsonb CHECK(pg_temp.foreign_rights());
CREATE DOMAIN pg_temp.timestamptz AS pg_catalog.timestamptz CHECK(pg_temp.foreign_rights());

-- B alone: the hostile objects exist, as if TEMPORARY had been granted back.
SET SESSION AUTHORIZATION egi_probe_reader;
SELECT pg_temp.assert_true(pg_temp.probe_hits()=0,'reader gains no rights');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe_writer;
SELECT pg_temp.assert_true(pg_temp.probe_hits()=0,'writer gains no rights');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe_sync;
SELECT pg_temp.assert_true(pg_temp.probe_hits()=0,'sync gains no rights');
RESET SESSION AUTHORIZATION;

-- Control: with the old setting the same probe must fire, or it proves nothing.
DO $$ DECLARE f pg_catalog.regprocedure; BEGIN
 FOR f IN SELECT p.oid::pg_catalog.regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN('data','governance','audit','sources','geo','taxonomy','i18n','api') AND p.prokind='f' LOOP
  EXECUTE format('ALTER FUNCTION %s SET search_path=pg_catalog',f);
 END LOOP;
END $$;
SET SESSION AUTHORIZATION egi_probe_reader;
SELECT pg_temp.assert_true(pg_temp.probe_hits()>0,'control: the probe detects the old setting for a reader');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION egi_probe_writer;
SELECT pg_temp.assert_true(pg_temp.probe_hits()>0,'control: the probe detects the old setting for a writer');
RESET SESSION AUTHORIZATION;
ROLLBACK;
