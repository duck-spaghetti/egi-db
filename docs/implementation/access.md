# Moderator access — 010

EGI-81 and the workspace's ADR 0011
(`project_egi/docs/adr/0011-verify-moderator-sessions-in-the-database.md`). The app connects with
one editorial login; the database verifies each moderator's session and only then
knows who acts. Writes keep going through the existing operations under each person's
grants (`governance.actor_grants`).

## Roles and logins

| Role | What it may do |
| --- | --- |
| `egi_editorial` (NOLOGIN) | The `access` functions below, `egi_writer`'s operations, the contact-protection read and release, and reads of drafts, evidence and source bodies (the same read set as `egi_sync`) |

The migration creates no login. Per environment the owner creates one, for example
`CREATE ROLE egi_editorial_login LOGIN PASSWORD '…' IN ROLE egi_editorial;`, and gives
its connection string to the app. The login must be a **direct** member of
`egi_editorial` and must not be registered in `governance.actors`.

## How a request acts

1. The app hashes the session token from the cookie (SHA-256, lowercase hex) and calls
   `access.verify_session(hash)` first in the transaction. It fails closed with
   `42501 session_invalid` for an unknown, revoked, expired (14 days), idle (8 hours)
   or deactivated session, and with `session_already_bound` for a second person in the
   same transaction.
2. The function binds the person to the transaction id (`access.request_actors`); a
   rolled-back transaction leaves nothing.
3. `governance.current_actor()` returns that person for the editorial login and raises
   `session_required` without a verified session. Other logins keep the `session_user`
   mapping; a superuser is never treated as the editorial login.

## Operations

| Function | Caller | Effect |
| --- | --- | --- |
| `password_material(login)` | before sign-in | argon2 hash, TOTP secret and role of an active account, for the app's check |
| `oidc_account(issuer, subject)` | before sign-in | the active account bound to that identity |
| `open_session(account, token_hash, method, second_factor)` | after the app's check | a 14-day session; an admin by password needs `second_factor` |
| `close_session(token_hash)` | the person | sign out |
| `read_invitation(token_hash)`, `accept_invitation(token_hash, method, secret, issuer, subject, totp_secret)` | the invited person | 48 hours, one use; acceptance replaces every sign-in method, closes old sessions and activates the account |
| `create_account`, `reissue_invitation`, `deactivate_account`, `revoke_session`, `list_accounts`, `list_sessions` | admin session | accounts by invitation; deactivation ends sessions and invitations at once and keeps the last admin |
| `bootstrap_admin(login, display, token_hash)` | owner, once | the first admin and their invitation |

Moderators get `propose`, `approve`, `publish` and `verify`; the admin also
`release_protection`, which `publish_contact_protection_resolution` checks behind the
editorial login (`egi_privacy_moderator` keeps working for direct logins). People have
an actor with no database role (`governance.actors.database_role` is now nullable).
Every account step is in `access.events`. Tokens are only stored as hashes; the app
stores password hashes (argon2) and TOTP secrets.

Revert refuses while accounts exist (`access_accounts_exist`).
