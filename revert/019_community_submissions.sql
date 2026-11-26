-- Revert egi_database:019_community_submissions on pg
BEGIN;
DO $$ BEGIN IF EXISTS(SELECT FROM editorial.community_snapshots) OR EXISTS(SELECT FROM editorial.contributions WHERE author_kind='community') THEN
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='community_submissions_exist'; END IF; END $$;
DROP FUNCTION preparation.submit_item(uuid,uuid,uuid,uuid),editorial.read_community_snapshot(uuid),
 editorial.community_identity(uuid),editorial.authorize_community_closure(uuid,text,uuid),
 preparation.validate_references(jsonb),editorial.community_diagnostics(jsonb,jsonb);
DROP TABLE editorial.community_snapshots;
ALTER TABLE editorial.contributions DROP CONSTRAINT contributions_author_kind_check,
 ADD CONSTRAINT contributions_author_kind_check CHECK(author_kind IN ('visitor','reviewer','sync')),
 DROP CONSTRAINT contributions_public_target,
 ADD CONSTRAINT contributions_check2 CHECK((service_id IS NULL)=(public_revision_id IS NULL));
CREATE OR REPLACE FUNCTION editorial.submit_contribution(kind text,service uuid,category text,message text,contact text,
 contact_consent boolean,proposals jsonb,trap text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE settings editorial.intake_settings; revision uuid; result uuid; item jsonb;
BEGIN
 -- One intake at a time, so the global counts are exact.
 PERFORM pg_advisory_xact_lock(1162303812,2);
 SELECT * INTO settings FROM editorial.intake_settings;
 IF NOT settings.open THEN RETURN 'closed'; END IF;
 IF COALESCE(btrim(trap),'')<>'' THEN RETURN 'trapped'; END IF;
 IF (SELECT count(*) FROM editorial.contributions c WHERE c.created_at>clock_timestamp()-settings.window_length)>=settings.window_limit
  OR (SELECT count(*) FROM editorial.contributions c WHERE c.created_at>clock_timestamp()-interval '1 day')>=settings.daily_limit THEN
  RETURN 'limited';
 END IF;
 IF contact IS NOT NULL AND NOT COALESCE(contact_consent,false) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contact_requires_consent';
 END IF;
 proposals:=COALESCE(proposals,'[]'::jsonb);
 IF jsonb_typeof(proposals)<>'array' OR jsonb_array_length(proposals)>10
  OR EXISTS(SELECT FROM jsonb_array_elements(proposals) p WHERE jsonb_typeof(p)<>'object'
   OR jsonb_typeof(p->'field')<>'string' OR jsonb_typeof(p->'value')<>'string'
   OR char_length(p->>'value') NOT BETWEEN 1 AND 1000) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='proposals_invalid';
 END IF;
 IF kind='new_service' THEN
  IF service IS NOT NULL OR category IS NOT NULL
   OR NOT EXISTS(SELECT FROM jsonb_array_elements(proposals) p WHERE p->>'field'='name') THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='new_service_requires_name';
  END IF;
 ELSIF kind IN ('report','still_valid') THEN
  SELECT h.revision_id INTO revision FROM governance.published_heads h
   JOIN data.services s ON s.entity_id=h.entity_id WHERE h.entity_id=service;
  IF revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='service_not_public'; END IF;
  IF kind='still_valid' AND (category IS NOT NULL OR message IS NOT NULL OR jsonb_array_length(proposals)>0) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='still_valid_carries_nothing';
  END IF;
 ELSE
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contribution_kind_invalid';
 END IF;
 INSERT INTO editorial.contributions(kind,category,service_id,public_revision_id,text,contact)
  VALUES(kind,category,service,revision,NULLIF(btrim(message),''),NULLIF(btrim(contact),''))
  RETURNING contribution_id INTO result;
 FOR item IN SELECT * FROM jsonb_array_elements(proposals) LOOP
  INSERT INTO editorial.proposals(contribution_id,field,value) VALUES(result,item->>'field',item->'value');
 END LOOP;
 INSERT INTO editorial.events(contribution_id,action,details)
  VALUES(result,'submitted',jsonb_build_object('kind',kind,'proposals',jsonb_array_length(proposals)));
 RETURN 'stored';
END $$;

CREATE OR REPLACE FUNCTION editorial.close_contribution(contribution uuid,outcome text,reason text DEFAULT NULL,publication uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE me uuid:=governance.current_actor(); c editorial.contributions:=editorial.locked(contribution); published uuid;
BEGIN
 IF outcome NOT IN ('published','no_change','rejected','duplicate') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='outcome_invalid';
 END IF;
 IF outcome='published' THEN
  SELECT p.entity_id INTO published FROM governance.publications p JOIN data.services s ON s.entity_id=p.entity_id
   WHERE p.publication_id=publication;
  IF published IS NULL OR (c.service_id IS NOT NULL AND published<>c.service_id) THEN
   RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='publication_required';
  END IF;
 ELSIF COALESCE(btrim(reason),'')='' OR publication IS NOT NULL THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='reason_required';
 END IF;
 UPDATE editorial.proposals SET decision='rejected',decision_note='closed: '||outcome,decided_by=me,decided_at=clock_timestamp()
  WHERE contribution_id=contribution AND decision IS NULL;
 UPDATE editorial.contributions SET state='closed',waiting_reason=NULL,outcome=close_contribution.outcome,
  outcome_reason=NULLIF(btrim(reason),''),publication_id=publication,closed_by=me,closed_at=clock_timestamp()
  WHERE contribution_id=contribution;
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(contribution,me,'closed',jsonb_build_object('outcome',outcome,'publication_id',publication));
END $$;

COMMIT;
