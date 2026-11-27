-- Deploy egi_database:010_access
-- requires: 009_contact_protection_register
-- EGI-81, ADR 0011: the app connects with one editorial login; the database verifies
-- each moderator's session and only then knows the actor. Token hashes only.
BEGIN;

DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='egi_editorial') THEN
  CREATE ROLE egi_editorial NOLOGIN;
 END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='egi_editorial'
           AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
  OR pg_has_role('egi_sync','egi_editorial','MEMBER')
  OR pg_has_role('egi_editorial','egi_privacy_moderator','MEMBER') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='editorial_role_not_isolated';
 END IF;
END $$;
CREATE SCHEMA access;

-- A person behind the editorial login is an actor without a database role of its own.
ALTER TABLE governance.actors ALTER COLUMN database_role DROP NOT NULL;
ALTER TABLE governance.actor_grants DROP CONSTRAINT actor_grants_capability_check,
 ADD CONSTRAINT actor_grants_capability_check
  CHECK(capability IN ('propose','approve','publish','verify','release_protection'));

-- ============================================================================
-- Accounts, identities, invitations, sessions
-- ============================================================================
CREATE TABLE access.accounts (
 account_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 actor_id uuid UNIQUE NOT NULL REFERENCES governance.actors,
 login_name text UNIQUE NOT NULL CHECK(login_name ~ '^[a-z0-9][a-z0-9._-]{2,39}$'),
 role text NOT NULL CHECK(role IN ('admin','moderator')),
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','active','deactivated')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 created_by uuid REFERENCES governance.actors
);
-- `secret` is the app's argon2 password hash or the TOTP secret; OIDC is issuer + subject.
CREATE TABLE access.identities (
 identity_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 account_id uuid NOT NULL REFERENCES access.accounts,
 kind text NOT NULL CHECK(kind IN ('password','oidc','totp')),
 secret text CHECK(btrim(secret)<>''),
 issuer text CHECK(btrim(issuer)<>''),
 subject text CHECK(btrim(subject)<>''),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((kind='oidc')=(issuer IS NOT NULL AND subject IS NOT NULL)),
 CHECK((kind='oidc')=(secret IS NULL)),
 UNIQUE(account_id,kind)
);
CREATE UNIQUE INDEX identities_oidc ON access.identities(issuer,subject) WHERE kind='oidc';
CREATE TABLE access.invitations (
 invitation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 account_id uuid NOT NULL REFERENCES access.accounts,
 token_hash text UNIQUE NOT NULL CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 created_by uuid REFERENCES governance.actors,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz,
 revoked_at timestamptz,
 CHECK(expires_at>created_at)
);
CREATE TABLE access.sessions (
 session_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 account_id uuid NOT NULL REFERENCES access.accounts,
 token_hash text UNIQUE NOT NULL CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 method text NOT NULL CHECK(method IN ('password','oidc')),
 second_factor boolean NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL,
 revoked_at timestamptz,
 CHECK(expires_at>created_at)
);
CREATE INDEX sessions_open ON access.sessions(account_id) WHERE revoked_at IS NULL;
-- The verified actor of one transaction. A rolled-back transaction leaves no row;
-- committed rows only matter for their own transaction id and are pruned after a day.
CREATE TABLE access.request_actors (
 transaction_id xid8 PRIMARY KEY,
 session_id uuid NOT NULL REFERENCES access.sessions,
 actor_id uuid NOT NULL REFERENCES governance.actors,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX request_actors_age ON access.request_actors(created_at);
-- Every account step; actor NULL when the person acts before signing in or the owner bootstraps.
CREATE TABLE access.events (
 event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 account_id uuid NOT NULL REFERENCES access.accounts,
 actor_id uuid REFERENCES governance.actors,
 action text NOT NULL CHECK(action IN ('account_created','invitation_created','invitation_accepted',
  'session_opened','session_closed','session_revoked','account_deactivated')),
 details jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- Session verification and the actor
-- ============================================================================
-- Direct membership only: a superuser passes pg_has_role for every role.
CREATE FUNCTION access.editorial_login() RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles u ON u.oid=m.member
  WHERE g.rolname='egi_editorial' AND u.rolname=session_user)
$$;

CREATE OR REPLACE FUNCTION governance.current_actor() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result uuid;
BEGIN
 IF access.editorial_login() THEN
  SELECT actor_id INTO result FROM access.request_actors WHERE transaction_id=pg_current_xact_id_if_assigned();
  IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='session_required'; END IF;
  RETURN result;
 END IF;
 SELECT actor_id INTO result FROM governance.actors WHERE database_role=session_user AND enabled;
 IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='unregistered_actor'; END IF;
 RETURN result;
END $$;

CREATE FUNCTION access.require_editorial_login() RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NOT access.editorial_login() THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='editorial_login_required'; END IF;
END $$;

-- Verify the session behind this request and bind its person to the transaction.
-- Every editorial request calls it first; it fails closed with session_invalid.
CREATE FUNCTION access.verify_session(token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s access.sessions; a access.accounts; enabled boolean; display text; bound uuid;
BEGIN
 PERFORM access.require_editorial_login();
 SELECT * INTO s FROM access.sessions WHERE sessions.token_hash=verify_session.token_hash FOR UPDATE;
 IF s.session_id IS NOT NULL THEN
  SELECT * INTO a FROM access.accounts WHERE account_id=s.account_id;
  SELECT actors.enabled,actors.display_name INTO enabled,display FROM governance.actors WHERE actor_id=a.actor_id;
 END IF;
 IF s.session_id IS NULL OR s.revoked_at IS NOT NULL OR clock_timestamp()>=s.expires_at
  OR clock_timestamp()>=s.last_seen_at+interval '8 hours' OR a.state<>'active' OR NOT enabled THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='session_invalid';
 END IF;
 SELECT session_id INTO bound FROM access.request_actors WHERE transaction_id=pg_current_xact_id();
 IF bound IS NOT NULL AND bound<>s.session_id THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='session_already_bound';
 END IF;
 UPDATE access.sessions SET last_seen_at=clock_timestamp() WHERE session_id=s.session_id;
 DELETE FROM access.request_actors WHERE created_at<clock_timestamp()-interval '1 day';
 INSERT INTO access.request_actors(transaction_id,session_id,actor_id)
  VALUES(pg_current_xact_id(),s.session_id,a.actor_id) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('account_id',a.account_id,'actor_id',a.actor_id,'login_name',a.login_name,
  'display_name',display,'role',a.role,'method',s.method,'second_factor',s.second_factor);
END $$;

-- The account behind the verified session, which must be an active admin.
CREATE FUNCTION access.require_admin() RETURNS access.accounts
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a access.accounts;
BEGIN
 PERFORM access.require_editorial_login();
 SELECT * INTO a FROM access.accounts WHERE actor_id=governance.current_actor();
 IF NOT FOUND OR a.role<>'admin' OR a.state<>'active' THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='admin_required';
 END IF;
 RETURN a;
END $$;

-- ============================================================================
-- Sign-in: material for the app's checks, then a session
-- ============================================================================
CREATE FUNCTION access.password_material(login text)
RETURNS TABLE(account_id uuid,role text,password_hash text,totp_secret text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT a.account_id,a.role,p.secret,t.secret FROM access.accounts a
  JOIN access.identities p ON p.account_id=a.account_id AND p.kind='password'
  LEFT JOIN access.identities t ON t.account_id=a.account_id AND t.kind='totp'
  WHERE a.login_name=login AND a.state='active' AND access.editorial_login()
$$;

CREATE FUNCTION access.oidc_account(issuer text,subject text) RETURNS TABLE(account_id uuid,role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT a.account_id,a.role FROM access.accounts a JOIN access.identities i ON i.account_id=a.account_id
  WHERE i.kind='oidc' AND i.issuer=oidc_account.issuer AND i.subject=oidc_account.subject
   AND a.state='active' AND access.editorial_login()
$$;

-- Called by the app after it has checked the password (and code) or the OIDC token.
-- The admin signing in by password must have passed the second factor.
CREATE FUNCTION access.open_session(account uuid,token_hash text,method text,second_factor boolean) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a access.accounts; result uuid;
BEGIN
 PERFORM access.require_editorial_login();
 SELECT * INTO a FROM access.accounts WHERE account_id=account FOR UPDATE;
 IF NOT FOUND OR a.state<>'active'
  OR NOT EXISTS(SELECT FROM access.identities i WHERE i.account_id=account AND i.kind=open_session.method) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='sign_in_refused';
 END IF;
 IF a.role='admin' AND method='password' AND NOT COALESCE(second_factor,false) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='second_factor_required';
 END IF;
 INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at)
  VALUES(account,token_hash,method,COALESCE(second_factor,false),clock_timestamp()+interval '14 days')
  RETURNING session_id INTO result;
 INSERT INTO access.events(account_id,actor_id,action,details)
  VALUES(account,a.actor_id,'session_opened',jsonb_build_object('session_id',result,'method',method));
 RETURN result;
END $$;

-- Sign out: the person ends their own session.
CREATE FUNCTION access.close_session(token_hash text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s access.sessions;
BEGIN
 PERFORM access.require_editorial_login();
 UPDATE access.sessions SET revoked_at=clock_timestamp()
  WHERE sessions.token_hash=close_session.token_hash AND revoked_at IS NULL RETURNING * INTO s;
 IF FOUND THEN
  INSERT INTO access.events(account_id,actor_id,action,details)
   SELECT s.account_id,actor_id,'session_closed',jsonb_build_object('session_id',s.session_id)
   FROM access.accounts WHERE account_id=s.account_id;
 END IF;
END $$;

-- ============================================================================
-- Invitations
-- ============================================================================
CREATE FUNCTION access.read_invitation(token_hash text)
RETURNS TABLE(account_id uuid,login_name text,display_name text,role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT a.account_id,a.login_name,g.display_name,a.role FROM access.invitations i
  JOIN access.accounts a ON a.account_id=i.account_id JOIN governance.actors g ON g.actor_id=a.actor_id
  WHERE i.token_hash=read_invitation.token_hash AND i.used_at IS NULL AND i.revoked_at IS NULL
   AND clock_timestamp()<i.expires_at AND a.state<>'deactivated' AND access.editorial_login()
$$;

-- Accept an invitation: replace the account's sign-in methods with exactly one of
-- password or OIDC, plus an optional TOTP secret (required for an admin by password).
CREATE FUNCTION access.accept_invitation(token_hash text,method text,secret text,issuer text,subject text,totp_secret text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE i access.invitations; a access.accounts;
BEGIN
 PERFORM access.require_editorial_login();
 SELECT * INTO i FROM access.invitations WHERE invitations.token_hash=accept_invitation.token_hash FOR UPDATE;
 IF i.invitation_id IS NOT NULL THEN
  SELECT * INTO a FROM access.accounts WHERE account_id=i.account_id FOR UPDATE;
 END IF;
 IF i.invitation_id IS NULL OR i.used_at IS NOT NULL OR i.revoked_at IS NOT NULL OR clock_timestamp()>=i.expires_at
  OR a.state='deactivated' THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='invitation_invalid';
 END IF;
 IF method NOT IN ('password','oidc') OR (method='password')<>(secret IS NOT NULL)
  OR (method='oidc')<>(issuer IS NOT NULL AND subject IS NOT NULL) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='sign_in_method_invalid';
 END IF;
 IF a.role='admin' AND method='password' AND totp_secret IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='second_factor_required';
 END IF;
 DELETE FROM access.identities WHERE account_id=a.account_id;
 INSERT INTO access.identities(account_id,kind,secret,issuer,subject)
  VALUES(a.account_id,method,CASE WHEN method='password' THEN secret END,
   CASE WHEN method='oidc' THEN issuer END,CASE WHEN method='oidc' THEN subject END);
 IF totp_secret IS NOT NULL THEN
  INSERT INTO access.identities(account_id,kind,secret) VALUES(a.account_id,'totp',totp_secret);
 END IF;
 UPDATE access.invitations SET used_at=clock_timestamp() WHERE invitation_id=i.invitation_id;
 UPDATE access.invitations SET revoked_at=clock_timestamp()
  WHERE account_id=a.account_id AND invitation_id<>i.invitation_id AND used_at IS NULL AND revoked_at IS NULL;
 UPDATE access.sessions SET revoked_at=clock_timestamp() WHERE account_id=a.account_id AND revoked_at IS NULL;
 UPDATE access.accounts SET state='active' WHERE account_id=a.account_id;
 INSERT INTO access.events(account_id,actor_id,action,details)
  VALUES(a.account_id,a.actor_id,'invitation_accepted',
   jsonb_build_object('invitation_id',i.invitation_id,'method',method,'totp',totp_secret IS NOT NULL));
 RETURN a.account_id;
END $$;

-- ============================================================================
-- Account administration (admin session, or the owner for the first admin)
-- ============================================================================
CREATE FUNCTION access.create_invitation(account uuid,token_hash text,creator uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE result uuid;
BEGIN
 UPDATE access.invitations SET revoked_at=clock_timestamp()
  WHERE account_id=account AND used_at IS NULL AND revoked_at IS NULL;
 INSERT INTO access.invitations(account_id,token_hash,created_by,expires_at)
  VALUES(account,token_hash,creator,clock_timestamp()+interval '48 hours') RETURNING invitation_id INTO result;
 INSERT INTO access.events(account_id,actor_id,action,details)
  VALUES(account,creator,'invitation_created',jsonb_build_object('invitation_id',result));
 RETURN result;
END $$;

-- A new person: an actor without a database role, global editorial capabilities,
-- `release_protection` for the admin only, and a first invitation.
CREATE FUNCTION access.create_person(login text,display text,role text,token_hash text,creator uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid; result uuid; capability text;
BEGIN
 IF COALESCE(btrim(display),'')='' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='display_name_required'; END IF;
 INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,display) RETURNING actor_id INTO actor;
 INSERT INTO access.accounts(actor_id,login_name,role,created_by) VALUES(actor,login,role,creator)
  RETURNING account_id INTO result;
 FOREACH capability IN ARRAY ARRAY['propose','approve','publish','verify']
  ||CASE WHEN role='admin' THEN ARRAY['release_protection'] ELSE ARRAY[]::text[] END LOOP
  INSERT INTO governance.actor_grants(actor_id,capability) VALUES(actor,capability);
 END LOOP;
 INSERT INTO access.events(account_id,actor_id,action,details)
  VALUES(result,creator,'account_created',jsonb_build_object('role',role));
 PERFORM access.create_invitation(result,token_hash,creator);
 RETURN result;
END $$;

CREATE FUNCTION access.create_account(login text,display text,role text,token_hash text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 RETURN access.create_person(login,display,role,token_hash,(access.require_admin()).actor_id);
END $$;

-- Recovery: a new invitation; its acceptance replaces every sign-in method.
CREATE FUNCTION access.reissue_invitation(account uuid,token_hash text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admin access.accounts:=access.require_admin();
BEGIN
 IF NOT EXISTS(SELECT FROM access.accounts WHERE account_id=account AND state<>'deactivated') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='account_not_reissuable';
 END IF;
 RETURN access.create_invitation(account,token_hash,admin.actor_id);
END $$;

-- Ends every session and invitation at once; the last active admin cannot be removed.
CREATE FUNCTION access.deactivate_account(account uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admin access.accounts:=access.require_admin(); a access.accounts;
BEGIN
 SELECT * INTO a FROM access.accounts WHERE account_id=account FOR UPDATE;
 IF NOT FOUND OR a.state='deactivated' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='account_not_active'; END IF;
 IF a.role='admin' AND NOT EXISTS(SELECT FROM access.accounts WHERE role='admin' AND state='active' AND account_id<>account) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='last_admin';
 END IF;
 UPDATE access.accounts SET state='deactivated' WHERE account_id=account;
 UPDATE governance.actors SET enabled=false WHERE actor_id=a.actor_id;
 UPDATE access.sessions SET revoked_at=clock_timestamp() WHERE account_id=account AND revoked_at IS NULL;
 UPDATE access.invitations SET revoked_at=clock_timestamp() WHERE account_id=account AND used_at IS NULL AND revoked_at IS NULL;
 INSERT INTO access.events(account_id,actor_id,action) VALUES(account,admin.actor_id,'account_deactivated');
END $$;

CREATE FUNCTION access.revoke_session(target uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admin access.accounts:=access.require_admin(); s access.sessions;
BEGIN
 UPDATE access.sessions SET revoked_at=clock_timestamp() WHERE session_id=target AND revoked_at IS NULL RETURNING * INTO s;
 IF FOUND THEN
  INSERT INTO access.events(account_id,actor_id,action,details)
   VALUES(s.account_id,admin.actor_id,'session_revoked',jsonb_build_object('session_id',target));
 END IF;
END $$;

CREATE FUNCTION access.list_accounts()
RETURNS TABLE(account_id uuid,login_name text,display_name text,role text,state text,created_at timestamptz,
 open_sessions bigint,invitation_expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM access.require_admin();
 RETURN QUERY SELECT a.account_id,a.login_name,g.display_name,a.role,a.state,a.created_at,
  (SELECT count(*) FROM access.sessions s WHERE s.account_id=a.account_id AND s.revoked_at IS NULL
    AND clock_timestamp()<s.expires_at AND clock_timestamp()<s.last_seen_at+interval '8 hours'),
  (SELECT max(i.expires_at) FROM access.invitations i WHERE i.account_id=a.account_id AND i.used_at IS NULL
    AND i.revoked_at IS NULL AND clock_timestamp()<i.expires_at)
  FROM access.accounts a JOIN governance.actors g ON g.actor_id=a.actor_id ORDER BY a.login_name;
END $$;

CREATE FUNCTION access.list_sessions(account uuid)
RETURNS TABLE(session_id uuid,method text,second_factor boolean,created_at timestamptz,last_seen_at timestamptz,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM access.require_admin();
 RETURN QUERY SELECT s.session_id,s.method,s.second_factor,s.created_at,s.last_seen_at,s.expires_at
  FROM access.sessions s WHERE s.account_id=account AND s.revoked_at IS NULL
   AND clock_timestamp()<s.expires_at AND clock_timestamp()<s.last_seen_at+interval '8 hours'
  ORDER BY s.last_seen_at DESC;
END $$;

-- Owner only, once: the first admin and their invitation.
CREATE FUNCTION access.bootstrap_admin(login text,display text,token_hash text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT FROM access.accounts WHERE role='admin' AND state<>'deactivated') THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='admin_exists';
 END IF;
 RETURN access.create_person(login,display,'admin',token_hash,NULL);
END $$;

-- ============================================================================
-- Contact-protection release behind the editorial login
-- ============================================================================
CREATE OR REPLACE FUNCTION governance.publish_contact_protection_resolution(
 target uuid,approved_decision uuid,expected_public uuid,protection_ids uuid[],scope_service uuid,note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner uuid; protection governance.contact_protections; id uuid; result uuid; scopes uuid[]; affected uuid;
BEGIN
 IF access.editorial_login() THEN
  -- Behind the editorial login the person decides, not the role (ADR 0011).
  IF NOT EXISTS(SELECT FROM governance.actor_grants g WHERE g.actor_id=governance.current_actor()
     AND g.capability='release_protection' AND g.territory_id IS NULL
     AND clock_timestamp()>=g.valid_from AND (g.valid_until IS NULL OR clock_timestamp()<g.valid_until)) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='privacy_resolution_denied';
  END IF;
 ELSIF NOT pg_has_role(session_user,'egi_privacy_moderator','MEMBER') THEN
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

-- ============================================================================
-- Privileges
-- ============================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA access FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA access FROM PUBLIC;
GRANT USAGE ON SCHEMA access TO egi_editorial;
GRANT EXECUTE ON FUNCTION
 access.verify_session(text),access.password_material(text),access.oidc_account(text,text),
 access.open_session(uuid,text,text,boolean),access.close_session(text),access.read_invitation(text),
 access.accept_invitation(text,text,text,text,text,text),access.create_account(text,text,text,text),
 access.reissue_invitation(uuid,text),access.deactivate_account(uuid),access.revoke_session(uuid),
 access.list_accounts(),access.list_sessions(uuid)
TO egi_editorial;
-- The editorial login writes through the existing operations, under each person's grants.
GRANT egi_writer TO egi_editorial;
GRANT EXECUTE ON FUNCTION governance.read_contact_protections(uuid),governance.publish_contact_protection_resolution(uuid,uuid,uuid,uuid[],uuid,text) TO egi_editorial;
-- The service workspace reads drafts, evidence and source bodies, as sync does.
GRANT USAGE ON SCHEMA data,sources,i18n,geo,taxonomy TO egi_editorial;
GRANT SELECT ON ALL TABLES IN SCHEMA data,sources,i18n,geo,taxonomy TO egi_editorial;
GRANT SELECT ON
 governance.entity_revisions,governance.working_heads,governance.published_heads,
 governance.submissions,governance.review_decisions,governance.publications,governance.value_decisions,
 governance.value_evidence,governance.actors,governance.sync_entries,governance.source_service_links
TO egi_editorial;
-- No login is created here: the owner creates one `LOGIN IN ROLE egi_editorial` per environment.
COMMIT;
