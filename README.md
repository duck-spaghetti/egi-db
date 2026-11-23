# EGI canonical database

PostgreSQL/PostGIS is EGI's authoritative database. Sqitch manages structure;
real-data population will use a separate bootstrap. Future SQLite files are
read-only offline distributions of approved canonical information.

The initial implementation includes typed identity/revisions, retained source
evidence, canonical drafts, controlled publication, scoped verification, restoration
and approved public directory reads. No real source data, application or exporter
is delivered. The baseline uses four numbered Sqitch triplets: `001_foundation`,
`002_canonical`, `003_governance` and `004_directory`.
`005_sync` adds [versions per source, withdrawal and same-service links](docs/implementation/sync.md).
`006_hardening` keeps session temporary objects from shadowing what the functions name:
every function searches `pg_temp` last, and only an explicit grant gives `TEMPORARY`.
It also completes the approved sync review with guarded orphan-location withdrawal,
shared-contact change notifications, scope checks, location territory reads and
three supporting indexes. Native contracts, concurrency and revert/redeploy passed
on 2026-11-22; application of 006 is confined to authorized local A2/A3 targets.

`007_linked_supplements` adds the explicitly approved A3 reader projection for
linked secondary contacts/access conditions, without new tables or changing
001–006. Only an exact approved, source-pinned working revision behind a current
public principal is eligible; private and pending fields remain inaccessible.
See [the contract](docs/implementation/sync.md#linked-supplements--007).
007 is applied only to disposable checks and the isolated local A3 database.

`008_contact_aliases` (B1) extends 007's private-contact suppression to terminal
phone shorthand such as `06 45460313/4`: a private compound on the principal now
also hides each derived alternative. No table, grant or public JSON shape changes.
See [the contract](docs/implementation/sync.md#contact-aliases--008). 008 is applied
only to disposable checks and the isolated local B1 database.

`009_contact_protection_register` (EGI-67) adds persistent, attributable privacy
protections and guarded public reads across linked descriptions. Sync consumes a
bounded private operation; release requires an explicitly reviewed publication
and the separate `egi_privacy_moderator` role. See [the contract](docs/implementation/sync.md#persistent-contact-protections--009).
Execution is currently confined to disposable tests: no historical inventory,
backfill, retained demo application or real-login membership grant has occurred.

## Start here

- [AGENTS.md](AGENTS.md): execution scope and decision boundaries.
- [Specification v1.1](docs/design/specification.md): approved behavior.
- [Action plan r0.2](docs/design/implementation-plan.md): approved sequence, actual
  issue mapping and current execution evidence.
- [Setup and verification](docs/implementation/setup.md): native runtime and the
  dedicated disposable contract runner.
- [Revision operations](docs/implementation/operations.md): aggregate input,
  publication/restore, trusted actors and errors.
- [Structural proposal](docs/design/schema-proposal.md), [design ledger](docs/design/canonical-database.md)
  and [API/source inventory](docs/design/api-and-data-inventory.md): design basis and evidence.

## Development workflow

[duck-spaghetti/egi-db](https://github.com/duck-spaghetti/egi-db) is the
public origin (2026-11-19; the earlier `egi-database` repository and its issues #1–#10 were deleted). Development uses dev; completed reviewed development integrates
into master. The initial remote main commit is preserved. Implementation happens
on isolated task branches/worktrees from fetched dev; checkpoint approval and
external delivery are recorded separately in the action plan.

The #5–#9 checkpoint adds relational hours and approved calendar effects, territorial
taxonomy, dynamic translations and public directory reads. Read the
[directory operations](docs/implementation/directory.md) for the implemented contract.
The group was reviewed and pushed to dev at 9d4013c. Ticket #10 supplies final
[integrated acceptance](docs/implementation/acceptance.md). The user authorized final
dev delivery, independent review, a PR to master and issue closure after verification.
