# EGI canonical database

This repository currently contains planning and agent documentation only.
PostgreSQL/PostGIS, `psql` and Sqitch are selected for the future implementation.
Data loading will use a separately designed bootstrap. A future SQLite distribution
will be generated from the canonical dataset for read-only offline use.

Start with [AGENTS.md](AGENTS.md). The [specification v1.1](docs/design/specification.md)
consolidates the selected behaviors. The [action plan r0.2](docs/design/implementation-plan.md)
records the approved approach/P1/P2; implementation remains unstarted and separately authorized. GitHub Issues is selected;
[duck-spaghetti/egi-database](https://github.com/duck-spaghetti/egi-database) is configured
as origin and the approved task set is published as issues #1–#10 under the
[tracker conventions](docs/agents/issue-tracker.md). Local documents remain uncommitted/unpushed.

 The [schema proposal](docs/design/schema-proposal.md)
contains proposed tables, columns, cardinalities, constraints, revision/restoration and
public/HSDS/SQLite projection contracts. The domain interview is consolidated; the
proposal awaits discussion and technical review and is not approved for implementation.

 The [working design](docs/design/canonical-database.md)
records requirements, findings, architecture proposals and the interview. It is
not yet an approved specification or an implementation plan.

The [API/data inventory](docs/design/api-and-data-inventory.md) records the earlier
app and sources examined. Source files remain in their existing locations.
No migrations, database instance, bootstrap or SQLite artifact have been created.
