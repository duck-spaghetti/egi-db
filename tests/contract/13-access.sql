-- EGI-81, ADR 0011: one editorial login, sessions verified by the database.
-- Runs in autocommit: each verified session binds one transaction, so scenarios
-- use their own BEGIN/COMMIT. Everything created here is removed at the end.
\ir helpers.sql
CREATE FUNCTION pg_temp.h(token text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT encode(sha256(convert_to(token,'UTF8')),'hex') $$;
CREATE ROLE egi_probe_editorial LOGIN IN ROLE egi_editorial;

SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='access' AND p.prokind='f'
 AND NOT COALESCE('search_path=pg_catalog, pg_temp'=ANY(p.proconfig),false)),'every access function names pg_temp last');
-- A superuser passes pg_has_role for every role; it must not count as the editorial login.
SELECT pg_temp.expect_error('SELECT governance.current_actor()','42501','unregistered_actor');

-- First admin: owner only, once.
SELECT access.bootstrap_admin('admin1','Admin One',pg_temp.h('inv-admin')) AS admin_account \gset
SELECT pg_temp.expect_error(format('SELECT access.bootstrap_admin(%L,%L,%L)','admin2','Admin Two',pg_temp.h('x')),'55000','admin_exists');

SET SESSION AUTHORIZATION egi_probe_editorial;
SELECT pg_temp.expect_error('SELECT * FROM access.sessions','42501');
SELECT pg_temp.expect_error(format('SELECT access.bootstrap_admin(%L,%L,%L)','x1','X',pg_temp.h('y')),'42501');
SELECT pg_temp.expect_error($$SELECT governance.save_revision('service',NULL,NULL,NULL,'{}'::jsonb,'x')$$,'42501','session_required');

-- Invitation: an admin signing in by password needs a TOTP secret; one use only.
SELECT pg_temp.assert_true((SELECT login_name FROM access.read_invitation(pg_temp.h('inv-admin')))='admin1','invitation readable');
SELECT pg_temp.expect_error(format('SELECT access.accept_invitation(%L,%L,%L,NULL,NULL,NULL)',
 pg_temp.h('inv-admin'),'password','$argon2id$admin'),'42501','second_factor_required');
SELECT access.accept_invitation(pg_temp.h('inv-admin'),'password','$argon2id$admin',NULL,NULL,'JBSWY3DPEHPK3PXP');
SELECT pg_temp.expect_error(format('SELECT access.accept_invitation(%L,%L,%L,NULL,NULL,%L)',
 pg_temp.h('inv-admin'),'password','$argon2id$other','JBSWY3DPEHPK3PXQ'),'42501','invitation_invalid');
SELECT pg_temp.assert_true((SELECT password_hash='$argon2id$admin' AND totp_secret='JBSWY3DPEHPK3PXP' AND role='admin'
 FROM access.password_material('admin1')),'password material for the app''s check');

-- Sessions: the admin by password only with the second factor.
SELECT pg_temp.expect_error(format('SELECT access.open_session(%L,%L,%L,false)',:'admin_account',pg_temp.h('s-admin'),'password'),
 '42501','second_factor_required');
SELECT access.open_session(:'admin_account',pg_temp.h('s-admin'),'password',true) IS NOT NULL AS admin_session;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('unknown')),'42501','session_invalid');
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin'))->>'actor_id' AS admin_actor \gset
SELECT access.create_account('mod1','Mod One','moderator',pg_temp.h('inv-mod1')) AS mod1 \gset
SELECT access.create_account('mod2','Mod Two','moderator',pg_temp.h('inv-mod2')) AS mod2 \gset
COMMIT;
SELECT pg_temp.expect_error('SELECT access.list_accounts()','42501','session_required');

-- OIDC: bound by issuer and subject, unique across accounts.
SELECT access.accept_invitation(pg_temp.h('inv-mod1'),'oidc',NULL,'https://accounts.google.com','sub-1',NULL);
SELECT pg_temp.assert_true((SELECT account_id FROM access.oidc_account('https://accounts.google.com','sub-1'))=:'mod1',
 'OIDC identity resolves its account');
SELECT pg_temp.expect_error(format('SELECT access.accept_invitation(%L,%L,NULL,%L,%L,NULL)',
 pg_temp.h('inv-mod2'),'oidc','https://accounts.google.com','sub-1'),'23505');
SELECT access.open_session(:'mod1',pg_temp.h('s-mod1'),'oidc',false) IS NOT NULL AS mod1_session;
SELECT pg_temp.expect_error(format('SELECT access.open_session(%L,%L,%L,false)',:'mod1',pg_temp.h('s-mod1b'),'password'),
 '42501','sign_in_refused');

-- One person per transaction; capabilities stay per person.
BEGIN;
SELECT access.verify_session(pg_temp.h('s-mod1')) IS NOT NULL AS mod1_verified;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-admin')),'42501','session_already_bound');
SELECT pg_temp.expect_error('SELECT access.list_accounts()','42501','admin_required');
SELECT pg_temp.expect_error('SELECT governance.publish_contact_protection_resolution(NULL,NULL,NULL,ARRAY[]::uuid[],NULL,NULL)',
 '42501','privacy_resolution_denied');
COMMIT;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS admin_verified;
-- The admin passes the release check and stops at the argument validation that follows it.
SELECT pg_temp.expect_error('SELECT governance.publish_contact_protection_resolution(NULL,NULL,NULL,ARRAY[]::uuid[],NULL,NULL)',
 '22023','privacy_resolution_reason_and_targets_required');
SELECT pg_temp.assert_true((SELECT count(*) FROM access.list_accounts())=3,'the admin lists accounts');
COMMIT;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true((SELECT bool_and(created_by=:'admin_actor') FROM access.accounts WHERE role='moderator'),
 'a verified session yields its actor: the admin created both moderators');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM access.sessions WHERE token_hash LIKE 's-%')
 AND NOT EXISTS(SELECT FROM access.invitations WHERE token_hash LIKE 'inv-%'),'tokens are stored only as hashes');
SELECT pg_temp.assert_true((SELECT array_agg(capability ORDER BY capability) FROM governance.actor_grants g
 JOIN access.accounts a ON a.actor_id=g.actor_id WHERE a.login_name='mod1')=ARRAY['approve','propose','publish','verify'],
 'moderator capabilities');
SELECT pg_temp.assert_true((SELECT bool_or(capability='release_protection') FROM governance.actor_grants g
 JOIN access.accounts a ON a.actor_id=g.actor_id WHERE a.login_name='admin1'),'release_protection is the admin''s');

-- Idle and absolute expiry.
UPDATE access.sessions SET last_seen_at=clock_timestamp()-interval '9 hours' WHERE token_hash=pg_temp.h('s-mod1');
SET SESSION AUTHORIZATION egi_probe_editorial;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-mod1')),'42501','session_invalid');
RESET SESSION AUTHORIZATION;
UPDATE access.sessions SET last_seen_at=clock_timestamp(),created_at=clock_timestamp()-interval '15 days',
 expires_at=clock_timestamp()-interval '1 day' WHERE token_hash=pg_temp.h('s-mod1');
UPDATE access.invitations SET created_at=clock_timestamp()-interval '3 days',expires_at=clock_timestamp()-interval '1 day'
 WHERE token_hash=pg_temp.h('inv-mod2');
SET SESSION AUTHORIZATION egi_probe_editorial;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-mod1')),'42501','session_invalid');

-- Invitation expiry and recovery by a new invitation.
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM access.read_invitation(pg_temp.h('inv-mod2'))),'an expired invitation is unreadable');
SELECT pg_temp.expect_error(format('SELECT access.accept_invitation(%L,%L,%L,NULL,NULL,NULL)',
 pg_temp.h('inv-mod2'),'password','$argon2id$mod2'),'42501','invitation_invalid');
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS admin_verified;
SELECT access.reissue_invitation(:'mod2',pg_temp.h('inv-mod2b')) IS NOT NULL AS reissued;
COMMIT;
SELECT access.accept_invitation(pg_temp.h('inv-mod2b'),'password','$argon2id$mod2',NULL,NULL,NULL) IS NOT NULL AS mod2_active;
SELECT access.open_session(:'mod2',pg_temp.h('s-mod2'),'password',false) IS NOT NULL AS mod2_session;

-- Revocation and deactivation take effect at once; the last admin stays.
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS admin_verified;
SELECT access.revoke_session((SELECT session_id FROM access.list_sessions(:'mod2')));
COMMIT;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-mod2')),'42501','session_invalid');
SELECT access.open_session(:'mod2',pg_temp.h('s-mod2b'),'password',false) IS NOT NULL AS mod2_session_again;
BEGIN;
SELECT access.verify_session(pg_temp.h('s-admin')) IS NOT NULL AS admin_verified;
SELECT access.deactivate_account(:'mod2');
SELECT pg_temp.expect_error(format('SELECT access.deactivate_account(%L)',:'admin_account'),'55000','last_admin');
COMMIT;
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-mod2b')),'42501','session_invalid');
SELECT pg_temp.expect_error(format('SELECT access.open_session(%L,%L,%L,false)',:'mod2',pg_temp.h('s-mod2c'),'password'),
 '42501','sign_in_refused');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM access.password_material('mod2')),'a deactivated account has no sign-in');

-- Sign out.
SELECT access.close_session(pg_temp.h('s-admin'));
SELECT pg_temp.expect_error(format('SELECT access.verify_session(%L)',pg_temp.h('s-admin')),'42501','session_invalid');
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(NOT (SELECT g.enabled FROM governance.actors g JOIN access.accounts a ON a.actor_id=g.actor_id
 WHERE a.login_name='mod2'),'a deactivated person is a disabled actor');
SELECT pg_temp.assert_true((SELECT array_agg(DISTINCT action ORDER BY action) FROM access.events)=ARRAY['account_created',
 'account_deactivated','invitation_accepted','invitation_created','session_closed','session_opened','session_revoked'],
 'every account step is recorded');

-- Remove everything this file created, so later revert checks find no accounts.
DELETE FROM access.request_actors;
DELETE FROM access.events;
DELETE FROM access.sessions;
DELETE FROM access.invitations;
DELETE FROM access.identities;
DELETE FROM governance.actor_grants WHERE actor_id IN (SELECT actor_id FROM access.accounts);
WITH gone AS (DELETE FROM access.accounts RETURNING actor_id)
DELETE FROM governance.actors WHERE actor_id IN (SELECT actor_id FROM gone);
DROP ROLE egi_probe_editorial;
