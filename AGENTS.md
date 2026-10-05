# EGI database instructions

EGI's canonical database is being designed here. PostgreSQL is authoritative,
PostGIS supports spatial operations, `psql` is the database client, and Sqitch
will manage structure/deployment. A separate data bootstrap will follow once
source data and its contracts are ready. Future SQLite files are derived offline
distributions of the same canonical dataset.

## Current authorization

The user authorized execution of the approved specification v1.1 and plan r0.2
through issues #5–#9, using execute-reviewed-task and grouped stepwise review.
The #1–#4 review was accepted and pushed to dev. Pause after #9; #10 requires continuation. Selected Sqitch setup,
SQL/DDL and synthetic checks on a dedicated disposable PostgreSQL 18.3/PostGIS
target are within this execution scope. Preserve original app/source references.

Development uses dev; completed reviewed development integrates into master. The
initial documentation commit/push to dev and branch bootstrap are authorized.
Implement on an isolated task branch/worktree from fetched origin/dev. Delivery
of implementation commits and final merge follow the execution agreement in the
action plan; preserve the existing remote main history.

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
review-ready. GitHub is the selected tracker; the user-created repository is configured as origin.
The approved `to-tickets` breakdown is published as issues #1–#10; read the action
plan’s task mapping before execution. Execution mode is grouped stepwise, with the next checkpoint after issue #9. Before specification/task planning read
[specification](docs/design/specification.md), [action plan](docs/design/implementation-plan.md)
and [tracker conventions](docs/agents/issue-tracker.md). Specification/plan approval
state is recorded there; do not infer implementation scope from document creation.
