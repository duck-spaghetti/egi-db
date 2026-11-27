-- Revert egi_database:021_community_component_evidence on pg
BEGIN;
DROP FUNCTION editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text);
ALTER FUNCTION editorial.bind_community_body_unaligned(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text) RENAME TO bind_community_body;
DROP FUNCTION editorial.community_align_baseline(jsonb,jsonb);
CREATE OR REPLACE FUNCTION editorial.read_community_snapshot(contribution uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid:=preparation.actor(); s editorial.community_snapshots;
BEGIN
 SELECT * INTO s FROM editorial.community_snapshots WHERE contribution_id=contribution;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='community_snapshot_not_found'; END IF;
 RETURN jsonb_build_object('snapshot',to_jsonb(s),'diagnostics',editorial.community_diagnostics(s.values,s.evidence),
  'resolved_service_id',editorial.community_identity(s.contribution_id));
END $$;

COMMIT;
