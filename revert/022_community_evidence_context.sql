-- Revert egi_database:022_community_evidence_context on pg
BEGIN;
CREATE OR REPLACE FUNCTION editorial.community_context_matches(source jsonb,target jsonb,source_path text[],target_path text[]) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE src_day integer:=array_position(source_path,'days'); dst_day integer:=array_position(target_path,'days');
BEGIN
 IF src_day IS NOT NULL AND dst_day IS NOT NULL THEN
  RETURN source#>(source_path[1:src_day+1]||ARRAY['weekday']) IS NOT DISTINCT FROM target#>(target_path[1:dst_day+1]||ARRAY['weekday']);
 END IF;
 RETURN true;
END $$;
COMMIT;
