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
