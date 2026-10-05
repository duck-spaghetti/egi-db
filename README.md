# EGI canonical database

PostgreSQL/PostGIS is EGI's authoritative database. Sqitch manages structure;
real-data population will use a separate bootstrap. Future SQLite files are
read-only offline distributions of approved canonical information.

The first implementation checkpoint (#1–#4) includes typed identity/revisions,
retained source evidence, canonical drafts, controlled publication, scoped
verification and new-revision restoration. It is under grouped stepwise review;
no real source data, application or exporter is delivered.

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

[duck-spaghetti/egi-database](https://github.com/duck-spaghetti/egi-database) is the
private origin. Development uses dev; completed reviewed development integrates
into master. The initial remote main commit is preserved. Implementation happens
on isolated task branches/worktrees from fetched dev; checkpoint approval and
external delivery are recorded separately in the action plan.

The first checkpoint pauses after #4. Weekly hours/calendar, territorial taxonomy,
dynamic translations and the full public projection follow in #5–#9 after continuation.
The integrated whole-set acceptance ticket #10 follows that group.
