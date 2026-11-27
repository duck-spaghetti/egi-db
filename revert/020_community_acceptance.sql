-- Revert egi_database:020_community_acceptance on pg
BEGIN;
DO $$ BEGIN IF EXISTS(SELECT FROM editorial.community_resolutions) OR EXISTS(SELECT FROM editorial.community_evidence) THEN
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_acceptance_exists'; END IF; END $$;
CREATE OR REPLACE FUNCTION governance.publication_diagnostics(target uuid) RETURNS TABLE(code text,field text)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT * FROM governance.prior_directory_diagnostics(target)
 UNION ALL SELECT 'unpublished_parent_location','parent_location_id' FROM data.location_revisions l WHERE l.revision_id=target AND l.parent_location_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.published_heads h WHERE h.entity_id=l.parent_location_id)
$$;
CREATE OR REPLACE FUNCTION editorial.community_identity(parent uuid) RETURNS uuid
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$ SELECT NULL::uuid $$;
CREATE OR REPLACE FUNCTION editorial.authorize_community_closure(contribution uuid,outcome text,publication uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN IF outcome='published' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_acceptance_required'; END IF; END $$;
DROP FUNCTION editorial.accept_community_item(uuid,jsonb,uuid),editorial.close_community_item(uuid,text,text,uuid),
 editorial.bind_community_body(editorial.community_snapshots,jsonb,jsonb,text[],uuid[],jsonb,text),
 editorial.materialize_community_locator(editorial.community_snapshots,uuid),editorial.community_observe(editorial.community_snapshots,text[],jsonb,jsonb),
 editorial.community_locator_supports(jsonb,jsonb,text[],text[],jsonb),editorial.community_context_matches(jsonb,jsonb,text[],text[]),
 editorial.community_claim_key(text[],jsonb),editorial.community_evidence_slot(text[]),editorial.community_normal_path(text[]),
 editorial.community_inherit_evidence(jsonb,jsonb),editorial.community_leaves(jsonb,text[]),editorial.community_without_evidence(jsonb),editorial.community_patch(jsonb,jsonb),editorial.community_path(text);
DROP TABLE editorial.community_evidence,editorial.community_resolutions;
DROP FUNCTION editorial.community_resolution_guard(),editorial.community_evidence_guard();
COMMIT;
