-- Deploy egi_database:022_community_evidence_context
-- requires: 021_community_component_evidence
BEGIN;
-- Equal scalar values in different components do not authorize mixing their
-- meaning: e.g. one contact's label with another number, or two time intervals.
CREATE OR REPLACE FUNCTION editorial.community_context_matches(source jsonb,target jsonb,source_path text[],target_path text[]) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE rule record; sp integer; tp integer; k text; source_component jsonb; target_component jsonb;
BEGIN
 FOR rule IN SELECT * FROM (VALUES
  ('contacts',ARRAY['channel_type','value']),('addresses',ARRAY['formatted','line1','locality','postal_code']),
  ('organizations',ARRAY['organization_id']),('conditions',ARRAY['condition_kind']),
  ('languages',ARRAY['language_code','availability_kind']),('coverage',ARRAY['territory_id','geometry_wkt']),
  ('classifications',ARRAY['adoption_id','term_id']),('schedules',ARRAY['scope','contact_component_id']),
  ('days',ARRAY['weekday']),('intervals',ARRAY['opens','closes','end_day_offset']),
  ('calendar_links',ARRAY['calendar_id','schedule_id']),('effects',ARRAY['event_version_id','kind'])
 ) AS contexts(component,keys) LOOP
  sp:=array_position(source_path,rule.component); tp:=array_position(target_path,rule.component);
  IF sp IS NULL OR tp IS NULL THEN CONTINUE; END IF;
  source_component:=source#>source_path[1:sp+1]; target_component:=target#>target_path[1:tp+1];
  FOREACH k IN ARRAY rule.keys LOOP
   IF source_component->k IS DISTINCT FROM target_component->k THEN RETURN false; END IF;
  END LOOP;
 END LOOP;
 RETURN true;
END $$;
COMMIT;
