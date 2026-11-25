-- Deploy egi_database:011_editorial
-- requires: 010_access
-- EGI-82: visitor contributions in a private, deletable store. Contact and text are
-- deleted on the agreed deadlines; only outcomes reach canonical history (ADR 0007).
BEGIN;

DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_intake') THEN CREATE ROLE egi_intake NOLOGIN; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_retention') THEN CREATE ROLE egi_retention NOLOGIN; END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname IN ('egi_intake','egi_retention')
           AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
  OR pg_has_role('egi_intake','egi_writer','MEMBER') OR pg_has_role('egi_intake','egi_editorial','MEMBER')
  OR pg_has_role('egi_retention','egi_writer','MEMBER') OR pg_has_role('egi_retention','egi_editorial','MEMBER') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='editorial_roles_not_isolated';
 END IF;
END $$;
CREATE SCHEMA editorial;

-- ============================================================================
-- Store
-- ============================================================================
-- One row: whether intake is open and its global limits (no IP, no per-person count).
CREATE TABLE editorial.intake_settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 open boolean NOT NULL DEFAULT true,
 window_limit integer NOT NULL DEFAULT 30 CHECK(window_limit>0),
 window_length interval NOT NULL DEFAULT interval '10 minutes' CHECK(window_length>interval '0'),
 daily_limit integer NOT NULL DEFAULT 300 CHECK(daily_limit>0)
);
INSERT INTO editorial.intake_settings DEFAULT VALUES;

-- `text` and `contact` are deleted on the deadlines; the row and its outcome remain.
CREATE TABLE editorial.contributions (
 contribution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 kind text NOT NULL CHECK(kind IN ('report','still_valid','new_service')),
 category text CHECK(category IN ('hours','contacts','address','closed','other')),
 service_id uuid REFERENCES data.services,
 public_revision_id uuid,
 author_kind text NOT NULL DEFAULT 'visitor' CHECK(author_kind IN ('visitor','reviewer','sync')),
 text text CHECK(char_length(text) BETWEEN 1 AND 4000),
 contact text CHECK(char_length(contact) BETWEEN 3 AND 200),
 state text NOT NULL DEFAULT 'new' CHECK(state IN ('new','claimed','waiting','closed')),
 waiting_reason text CHECK(waiting_reason IN ('evidence','submitter','admin')),
 claimed_by uuid REFERENCES governance.actors,
 outcome text CHECK(outcome IN ('published','no_change','rejected','duplicate')),
 outcome_reason text CHECK(btrim(outcome_reason)<>''),
 publication_id uuid REFERENCES governance.publications,
 closed_by uuid REFERENCES governance.actors,
 closed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 contact_deleted_at timestamptz,
 text_deleted_at timestamptz,
 CHECK((kind='report')=(category IS NOT NULL)),
 CHECK((kind='new_service')=(service_id IS NULL)),
 CHECK((service_id IS NULL)=(public_revision_id IS NULL)),
 CHECK((state='waiting')=(waiting_reason IS NOT NULL)),
 CHECK((state='closed')=(outcome IS NOT NULL AND closed_at IS NOT NULL)),
 CHECK((outcome='published')=(publication_id IS NOT NULL)),
 CHECK(contact IS NULL OR contact_deleted_at IS NULL),
 CHECK(text IS NULL OR text_deleted_at IS NULL)
);
CREATE INDEX contributions_created ON editorial.contributions(created_at);
CREATE INDEX contributions_open ON editorial.contributions(service_id) WHERE state<>'closed';
CREATE INDEX contributions_closed ON editorial.contributions(closed_at) WHERE state='closed';

-- One suggested value of a contribution and its decision. A visitor's value is text
-- and is deleted with the contribution's text.
CREATE TABLE editorial.proposals (
 proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 contribution_id uuid NOT NULL REFERENCES editorial.contributions,
 field text NOT NULL CHECK(field ~ '^[a-z][a-z_]{1,39}$'),
 value jsonb,
 decision text CHECK(decision IN ('accepted','amended','rejected')),
 decided_value jsonb,
 decision_note text CHECK(btrim(decision_note)<>''),
 decided_by uuid REFERENCES governance.actors,
 decided_at timestamptz,
 CHECK((decision IS NULL)=(decided_by IS NULL AND decided_at IS NULL)),
 CHECK(decision='amended' OR decided_value IS NULL)
);
CREATE INDEX proposals_contribution ON editorial.proposals(contribution_id);

-- Every step; details never carry contact or text. Actor NULL: the visitor's submission.
CREATE TABLE editorial.events (
 event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contribution_id uuid NOT NULL REFERENCES editorial.contributions,
 actor_id uuid REFERENCES governance.actors,
 action text NOT NULL CHECK(action IN ('submitted','claimed','released','reassigned','taken_over',
  'waiting','resumed','proposal_decided','closed')),
 details jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX events_contribution ON editorial.events(contribution_id);

-- ============================================================================
-- Intake: the public app's only write
-- ============================================================================
-- `message` is the visitor's free text. Returns stored, trapped (honeypot filled, nothing kept), limited or closed.
-- proposals: [{"field": "...", "value": "..."}], at most 10.
CREATE FUNCTION editorial.submit_contribution(kind text,service uuid,category text,message text,contact text,
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

-- ============================================================================
-- Moderation: every function acts as the person of the verified session
-- ============================================================================
CREATE FUNCTION editorial.locked(contribution uuid) RETURNS editorial.contributions
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c editorial.contributions;
BEGIN
 SELECT * INTO c FROM editorial.contributions WHERE contribution_id=contribution FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contribution_not_found'; END IF;
 IF c.state='closed' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='contribution_closed'; END IF;
 RETURN c;
END $$;

CREATE FUNCTION editorial.list_contributions(include_closed boolean DEFAULT false)
RETURNS TABLE(contribution_id uuid,kind text,category text,service_id uuid,public_revision_id uuid,author_kind text,
 state text,waiting_reason text,claimed_by uuid,claimed_by_name text,has_contact boolean,proposals bigint,
 outcome text,created_at timestamptz,closed_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM governance.current_actor();
 RETURN QUERY SELECT c.contribution_id,c.kind,c.category,c.service_id,c.public_revision_id,c.author_kind,c.state,
  c.waiting_reason,c.claimed_by,a.display_name,c.contact IS NOT NULL,
  (SELECT count(*) FROM editorial.proposals p WHERE p.contribution_id=c.contribution_id),
  c.outcome,c.created_at,c.closed_at
  FROM editorial.contributions c LEFT JOIN governance.actors a ON a.actor_id=c.claimed_by
  WHERE include_closed OR c.state<>'closed' ORDER BY c.created_at;
END $$;

-- Everything a moderator sees of one contribution: text, contact, proposals, history.
CREATE FUNCTION editorial.read_contribution(contribution uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 PERFORM governance.current_actor();
 SELECT to_jsonb(c)||jsonb_build_object(
  'claimed_by_name',(SELECT display_name FROM governance.actors WHERE actor_id=c.claimed_by),
  'proposals',COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.field,p.proposal_id) FROM editorial.proposals p
    WHERE p.contribution_id=c.contribution_id),'[]'::jsonb),
  'events',COALESCE((SELECT jsonb_agg(to_jsonb(e)||jsonb_build_object('actor_name',a.display_name) ORDER BY e.event_id)
    FROM editorial.events e LEFT JOIN governance.actors a ON a.actor_id=e.actor_id
    WHERE e.contribution_id=c.contribution_id),'[]'::jsonb))
  INTO result FROM editorial.contributions c WHERE c.contribution_id=contribution;
 IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='contribution_not_found'; END IF;
 RETURN result;
END $$;

-- People a case can be handed to: active accounts.
CREATE FUNCTION editorial.list_moderators() RETURNS TABLE(actor_id uuid,display_name text,role text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM governance.current_actor();
 RETURN QUERY SELECT a.actor_id,g.display_name,a.role FROM access.accounts a JOIN governance.actors g ON g.actor_id=a.actor_id
  WHERE a.state='active' ORDER BY g.display_name;
END $$;

-- Claim an unclaimed case, take over one claimed by someone else, release your own,
-- or hand it to another active person. A claim never locks the service.
CREATE FUNCTION editorial.claim(contribution uuid,action text DEFAULT 'claim',assignee uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE me uuid:=governance.current_actor(); c editorial.contributions:=editorial.locked(contribution); target uuid; event text;
BEGIN
 CASE action
  WHEN 'claim' THEN
   IF c.claimed_by IS NOT NULL AND c.claimed_by<>me THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='claimed_by_other'; END IF;
   target:=me; event:='claimed';
  WHEN 'take_over' THEN
   IF c.claimed_by IS NULL OR c.claimed_by=me THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='nothing_to_take_over'; END IF;
   target:=me; event:='taken_over';
  WHEN 'reassign' THEN
   IF NOT EXISTS(SELECT FROM access.accounts WHERE actor_id=assignee AND state='active') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='assignee_not_active';
   END IF;
   target:=assignee; event:='reassigned';
  WHEN 'release' THEN
   IF c.claimed_by IS DISTINCT FROM me THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='not_claimed_by_you'; END IF;
   target:=NULL; event:='released';
  ELSE RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='claim_action_invalid';
 END CASE;
 UPDATE editorial.contributions SET claimed_by=target,
  state=CASE WHEN state='waiting' THEN 'waiting' WHEN target IS NULL THEN 'new' ELSE 'claimed' END
  WHERE contribution_id=contribution;
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(contribution,me,event,jsonb_build_object('from',c.claimed_by,'to',target));
END $$;

-- Put a case on hold with a reason, or resume it. The deadlines do not move.
CREATE FUNCTION editorial.set_waiting(contribution uuid,reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE me uuid:=governance.current_actor(); c editorial.contributions:=editorial.locked(contribution);
BEGIN
 IF reason IS NULL THEN
  IF c.state<>'waiting' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='not_waiting'; END IF;
  UPDATE editorial.contributions SET state=CASE WHEN claimed_by IS NULL THEN 'new' ELSE 'claimed' END,waiting_reason=NULL
   WHERE contribution_id=contribution;
  INSERT INTO editorial.events(contribution_id,actor_id,action) VALUES(contribution,me,'resumed');
  RETURN;
 END IF;
 IF reason NOT IN ('evidence','submitter','admin') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='waiting_reason_invalid'; END IF;
 IF reason='submitter' AND c.contact IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='no_submitter_contact'; END IF;
 UPDATE editorial.contributions SET state='waiting',waiting_reason=reason WHERE contribution_id=contribution;
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(contribution,me,'waiting',jsonb_build_object('reason',reason));
END $$;

-- Accept, amend (with the moderator's value) or reject one proposal.
CREATE FUNCTION editorial.decide_proposal(proposal uuid,decision text,decided_value jsonb DEFAULT NULL,note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE me uuid:=governance.current_actor(); owner uuid;
BEGIN
 SELECT contribution_id INTO owner FROM editorial.proposals WHERE proposal_id=proposal;
 IF owner IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='proposal_not_found'; END IF;
 PERFORM editorial.locked(owner);
 IF decision NOT IN ('accepted','amended','rejected') OR (decision='amended')<>(decided_value IS NOT NULL) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='decision_invalid';
 END IF;
 UPDATE editorial.proposals SET decision=decide_proposal.decision,decided_value=decide_proposal.decided_value,
  decision_note=NULLIF(btrim(note),''),decided_by=me,decided_at=clock_timestamp() WHERE proposal_id=proposal;
 INSERT INTO editorial.events(contribution_id,actor_id,action,details)
  VALUES(owner,me,'proposal_decided',jsonb_build_object('proposal_id',proposal,'decision',decision));
END $$;

-- Close with an outcome. Published needs the publication of the contribution's service
-- (any service for a new-service proposal); other outcomes need a reason. Undecided
-- proposals are recorded as rejected by the closure. Closure starts the deadlines.
CREATE FUNCTION editorial.close_contribution(contribution uuid,outcome text,reason text DEFAULT NULL,publication uuid DEFAULT NULL) RETURNS void
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

-- The admin opens or closes intake and sets its global limits.
CREATE FUNCTION editorial.set_intake(open boolean,window_limit integer,daily_limit integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM access.require_admin();
 UPDATE editorial.intake_settings SET open=set_intake.open,window_limit=set_intake.window_limit,
  daily_limit=set_intake.daily_limit;
END $$;

CREATE FUNCTION editorial.read_intake() RETURNS editorial.intake_settings
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result editorial.intake_settings;
BEGIN
 PERFORM governance.current_actor();
 SELECT * INTO result FROM editorial.intake_settings;
 RETURN result;
END $$;

-- ============================================================================
-- Retention: contact at closure or after 90 days, text 30 days after closure
-- ============================================================================
CREATE FUNCTION editorial.purge_expired_contributions() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE contacts bigint; texts bigint;
BEGIN
 UPDATE editorial.contributions SET contact=NULL,contact_deleted_at=clock_timestamp()
  WHERE contact IS NOT NULL AND (state='closed' OR created_at<=clock_timestamp()-interval '90 days');
 GET DIAGNOSTICS contacts=ROW_COUNT;
 UPDATE editorial.contributions SET text=NULL,text_deleted_at=clock_timestamp()
  WHERE state='closed' AND closed_at<=clock_timestamp()-interval '30 days' AND text_deleted_at IS NULL;
 GET DIAGNOSTICS texts=ROW_COUNT;
 -- A proposal's values are part of the contribution's text.
 UPDATE editorial.proposals p SET value=NULL,decided_value=NULL FROM editorial.contributions c
  WHERE c.contribution_id=p.contribution_id AND c.text_deleted_at IS NOT NULL
   AND (p.value IS NOT NULL OR p.decided_value IS NOT NULL);
 RETURN jsonb_build_object('contacts',contacts,'texts',texts);
END $$;

-- ============================================================================
-- Privileges
-- ============================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA editorial FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA editorial FROM PUBLIC;
GRANT USAGE ON SCHEMA editorial TO egi_intake,egi_editorial,egi_retention;
GRANT EXECUTE ON FUNCTION editorial.submit_contribution(text,uuid,text,text,text,boolean,jsonb,text) TO egi_intake;
GRANT EXECUTE ON FUNCTION
 editorial.list_contributions(boolean),editorial.read_contribution(uuid),editorial.list_moderators(),
 editorial.claim(uuid,text,uuid),editorial.set_waiting(uuid,text),editorial.decide_proposal(uuid,text,jsonb,text),
 editorial.close_contribution(uuid,text,text,uuid),editorial.set_intake(boolean,integer,integer),editorial.read_intake()
TO egi_editorial;
GRANT EXECUTE ON FUNCTION editorial.purge_expired_contributions() TO egi_retention;
-- No login is created here: per environment, one `LOGIN IN ROLE egi_intake` for the public
-- app and one `LOGIN IN ROLE egi_retention` for the scheduled purge.
COMMIT;
