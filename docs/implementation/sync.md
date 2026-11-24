# Sync operations — 005_sync

Schema only: the importer's `egi-sync init` runs the bootstrap, and `egi-sync` is the
caller of these operations. Confirmed design: EGI-34, 2026-11-22.

| Object | Contract |
| --- | --- |
| `governance.sync_versions` | One append-only chain per dataset. `published` versions can be reactivated by a later one |
| `governance.sync_entries` | Every service the source has shown: identity, state, comparable content, the source's body before any merge |
| `governance.source_service_links` | Append-only decisions on two sources' services; the latest on a pair prevails |
| `record_sync_version` | Appends a version. Refuses a stale latest version with 40001 `stale_version` |
| `withdraw_service` | Removes the public head, and a location no public head uses any more. States no closure; history and audit stay |
| `link_source_services` | Appends `same`, with its principal, or `distinct` |

## Withdrawal

Causes are `not_observed` and `duplicate`, reserved to members of `egi_sync`, and
`moderation`, open to a writer with the publish capability on the affected territories.
Every public read follows `published_heads`, so no view changes. A withdrawn service
returns only by an explicit publication. Not republishing after `moderation` is the
caller's rule: no trigger enforces it.

## Role

`egi_sync` is a member of `egi_writer`. It also reads canonical state and inserts
evidence (captures, records, versions, runs, subjects, assertions). It writes no
canonical table, head, registration or version directly.

## Revert

Refused with 55000 `sync_history_exists` once a version or link exists. The cluster role
and its membership are retained: another database may use them.

## 006_hardening

Every function of the EGI schemas has `search_path=pg_catalog,pg_temp`, and `PUBLIC` has no
`TEMPORARY` on the database. A new or replaced function must set the same path:
`tests/contract/12-hardening.sql` and the verify script fail otherwise. Database privileges
belong to one database: a copy made from a template, or a restore without them, needs
`REVOKE TEMPORARY ... FROM PUBLIC` again, and the verify script tells.

The user also confirmed review decisions Q76–Q88 before this unreleased migration
was completed. `withdraw_orphan_location(location, expected_public, note)` takes the
same write lock, checks the public head, refuses any public service/contact/child
consumer and requires publish capability on every affected territory. It removes
only the public head and records audit and public changes. PUBLIC and readers cannot
execute it; scoped writers and sync can. The caller selects affected orphan candidates.

`withdraw_service` now checks an orphan location's own scopes before removing it,
and notifies public services whose shared contact disappears. Moderation may hide
an unpublished service with a null expected public head; stale expectations still
fail. Original functions in 001–005 remain immutable.

Sync can SELECT `revision_territories` to preserve a location's memberships. Three
indexes support repeated content lookup, revision evidence reads and service history.
Revert removes these additions and restores the 005 withdrawal operation, as well
as reopening the temporary-object defect; use revert only on disposable databases.


## Linked supplements — 007

A3 user decision: a review of the exact secondary revision authorizes only its
public contacts and access conditions as fragments of the principal's card.
It does not publish that service or make any other secondary field public.
The exact deploy/revert/verify SQL and the principal-private-contact protection
were presented and explicitly approved before execution on disposable/A3 targets.

`api.linked_service_supplements(principal uuid DEFAULT NULL, preferred text DEFAULT NULL)`
returns JSON fragments with service/revision/component and source/capture
provenance. It requires the latest effective explicit same-service link resolved
through published source-version identity history; a current non-defunct public
principal that is not another secondary; an active loaded source entry pinned to
the secondary's sealed working head; latest approved review; no secondary public
head or moderation withdrawal. Draft identity rebindings cannot redirect it.
Drafts, rejections, changed working heads and obsolete pins are excluded.

`governance.resolved_source_links`, `supplement_text`, `supplement_provenance` and
`contact_fingerprint` are implementation helpers, revoked from PUBLIC and readers.
Only the public projection is granted to `egi_reader`; no raw-table grant changes.
Functions retain hardened search paths. Text follows the exact revision and eligible
approved translation head. Only public contacts are included; a normalized match
against an explicit private contact on the principal's current public revision is
suppressed (phone/WhatsApp normalization included). Removal of a contact is not
silently interpreted as a permanent suppression registry.

Review/link changes need not increment `api.public_sequence`; consumers must read
this projection afresh or implement an independently valid invalidation scheme.
A3's app reads it on every request. No schema contract for cache invalidation was
invented. Revert removes only 007 functions.

Verification on PostgreSQL 18.3/PostGIS 3.6: full deploy/verify/contracts/concurrency
and revert/redeploy through 007 passed; importer native cases additionally cover
approved/unreviewed/rejected/draft/hidden/distinct/obsolete identity boundaries,
private contacts and taxonomy scoping. The app's separate native harness verifies
reader isolation and fragment refresh while the core snapshot is still cached.
The production owner choice C and external delivery remain separate.

## Contact aliases — 008

B1 user decision (plan r0.1): 007 compared one fingerprint per contact, so a private
compound such as `06 45460313/4` (fingerprint `064546031314`) did not suppress the
secondary's public `06 45460313`. The private helper
`governance.contact_aliases(channel text, value text)` returns the original
fingerprint plus, for phone/WhatsApp values with an optional `Tel.`/`Telefono`
label and a 1–3 digit terminal suffix after at least six base digits, the base
number and the suffix-substituted number. `api.linked_service_supplements` changes
only fingerprint equality into alias-array overlap; its JSON shape, grants and
eligibility are unchanged. The helper is revoked from PUBLIC and readers. This is
conservative suppression, not general contact entity resolution, and creates no
public contact. The importer's `importers/common/phones.py` applies the same rule.

Revert restores the exact 007 projection and drops only the helper. Verification on
PostgreSQL 18.3/PostGIS 3.6: full deploy/verify/contracts/concurrency and
revert/redeploy through 008 passed; importer native cases reproduce the leak on 007
and show 008 suppressing both alternatives, labelled forms and phone/WhatsApp.


## Persistent contact protections — 009

EGI-67 records the confirmed persistent privacy remedy. Migration 009 preserves
001–008 and creates three append-only governance tables: protection activations,
immutable scope applications and reviewed resolutions. A scope application has its
own `scope_id`; a previous exclusion cannot clear a later reapplication. Sticky
same-service scope survives unlink/principal changes, and propagates from retained
scopes to later explicit same-service associations. Unrelated services sharing a
number are not a global blacklist.

Whole-value Italian single numbers, full slash-separated lists and one terminal
1–3 digit suffix establish identities across phone/WhatsApp/telephone-like `other`.
Unicode whitespace, supported prefixes and labels normalize consistently with the
importer. Recognition never turns `other` into a public/callable contact. Uncertain
private phone/WhatsApp or telephone-like `other` activates a hold; unrelated private
email, URL and notes do not. Own uncertainty preserves existing own-principal public
contacts, but inherited uncertainty cannot bypass secondary telephone withholding.
Detail, linked supplements, public contact view and label reads use effective state.

The registry starts empty. Effective reads also guard current private revisions;
triggers retain restrictions before publication replaces a head, withdrawal,
link changes or source-entry rebinding can lose that evidence. No historical
inventory or bulk population runs in deploy. Older restrictions absent from current
state remain outside the recovered history until a separately reviewed inventory.

`governance.read_contact_protections(service uuid)` returns only the effective
numbers, holds and protection identifiers needed by sync/authorized moderators,
checking existing actor and affected-territory capabilities. Ledger tables remain
inaccessible to public readers, ordinary writers and sync. The bounded boolean
`api.service_contact_visible(service, subject, component, contact_link)` checks an
actual public contact association and its effective label, without exposing keys.

`governance.publish_contact_protection_resolution(target, approved, expected_public,
protection_ids, scope_service, note)` requires `egi_privacy_moderator` (NOLOGIN),
existing publication authority across all affected territories, the exact approved
revision/head and a nonempty reason. A null scope service releases an origin
protection; a service value records a scoped exclusion. It publishes the revision
and records the resolution atomically under the existing write lock. Stale,
unauthorized or failed publication leaves both unchanged. Resolving one uncertain
component leaves an independent component's hold active. Routine publication,
restore and sync cannot release restrictions. No real login is automatically
made a member of this new role.

Revert refuses a populated register rather than deleting decision history; empty
disposable deploy/revert/redeploy remains supported. All definer helpers use a safe
search path and limited grants. Native importer histories cover protection retention,
SQL/Python matching, linked scope generations, explicit/failed/concurrent releases,
territorial denial and reader/sync privilege boundaries. The initial disposable
checkpoint excluded retained demo updates. A separate grant on 2026-11-24 authorized
application of this exact reviewed 009 to the existing B1 demo only, after backup.
Deploy/verify passed; all 594 details read successfully through the restricted
reader, with zero orphan addresses. The register remains empty, role membership
count is zero, and actual reader probes deny ledger access/private operations.
The two existing latest offline sync plans require no writes; persisted domain rows
and public sequence remain unchanged. No historical inventory/loading, real-login
role grant, remote delivery or staging/production application has occurred.
Workspace evidence: `.scratch/mvp/b1-contact-protection-demo.md` and its 2026-11-24
check directory. Overall B1 acceptance remains the user's decision.
