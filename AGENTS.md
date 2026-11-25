# EGI database instructions

EGI's canonical database is being designed here. PostgreSQL is authoritative,
PostGIS supports spatial operations, `psql` is the database client, and Sqitch
will manage structure/deployment. A separate data bootstrap will follow once
source data and its contracts are ready. Future SQLite files are derived offline
distributions of the same canonical dataset.

## Current state

Issues #1–#10 (specification v1.1, plan r0.2) are delivered: `dev` integrated them
and PR #2 promoted them to `master`. New work follows the workspace development
cycle, is tracked in Linear (`repo/database`) and branches from the fetched
`origin/dev`; promoting `dev` to `master` needs the user's authorization. Preserve
existing `master` and `dev` history and original app/source references.

The #1–#10 execution agreement (grouped stepwise; Sqitch, SQL/DDL and synthetic
checks on a dedicated disposable PostgreSQL 18.3/PostGIS target) is historical;
its record is the action plan. New work needs its own approved scope.

Follow the shared workspace [AGENTS.md](../AGENTS.md) for autonomy, execution
approval, whole-set/stepwise mode, completion and external Git/delivery boundaries.
This repository remains in that shared workspace; local rules specialize the
database component. Keep shared rules authoritative in the parent entrypoint.
When the parent entrypoint is absent in a worktree/clone, read the
[worktree baseline](docs/agents/worktree-baseline.md).

## Read when relevant

- Before domain discussion or schema design, read [context](docs/agents/context.md),
  [GLOSSARY.md](GLOSSARY.md), and [canonical database design](docs/design/canonical-database.md) and
  [concrete schema proposal](docs/design/schema-proposal.md).
  Read relevant ADRs under `docs/adr/` when evaluating an architectural alternative.
- Before adapting an application contract, read [API and data inventory](docs/design/api-and-data-inventory.md).
  The original clone's `origin/wip` is evidence, not an approved schema or public contract.
- Before proposing checks, writing/reviewing future SQL or bootstrap code, read
  [database standards](docs/agents/standards.md).
- Before changing planning artifacts, starting a change session, reviewing readiness
  or preparing delivery, read [workflow](docs/agents/workflow.md) and
  [planning and collaboration](docs/agents/planning-and-collaboration.md).

Use English for database identifiers and maintained documentation. Record explicit
user decisions separately from research findings and recommendations. Track open
questions in the design; use ordinary chat questions for this interview so the user
can answer every round. Confirm shared understanding before treating the design as
review-ready. Linear is the tracker for new work; GitHub issues #1–#10 and their
task mapping in the action plan are historical. Before specification/task planning read
[specification](docs/design/specification.md), [action plan](docs/design/implementation-plan.md)
and [tracker conventions](docs/agents/issue-tracker.md). Do not infer implementation
scope from document creation.

## Commit attribution

No AI attribution in commits, pull requests or issues (no `Co-Authored-By` trailer for
Claude, Codex or another assistant, no "Generated with …" line); see the workspace
[AGENTS.md](../AGENTS.md#commit-attribution).
