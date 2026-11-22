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
