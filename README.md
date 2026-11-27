# Development CI — EGI-138

See [owning CI verification](docs/implementation/development-ci.md) for the PR-to-dev workflow, required-check
identity, selected runtime and actual enforcement-evidence boundary.

# Current development checks — EGI-132

```sh
python3 scripts/check.py --profile quick --json
python3 scripts/check.py --profile complete --json
```

Activate the selected Python/build environment. This repository owns its checks;
shared reporting, commit-title policy and hook installer are consumed from one exact
app Git revision recorded in `.checks/tool-source.json`. Set EGI_DEVTOOLS_SOURCE to
that source checkout if its default sibling location is unavailable. All imported
shared files must match the pinned commit before they execute; missing/mismatched
source returns blocked (exit2). No new web runtime dependency is introduced.

Commit-msg/pre-push/CI use the same canonical validator through
`python3 scripts/commit_guard.py`. `python3 scripts/install_hooks.py` activates only
this assigned worktree's hooks and preserves unrelated hook paths. Ordinary titles
use EGI-positive-number: summary; merge/revert handling and exact legacy SHA exceptions
follow the shared policy. Local checkpoints may be incomplete; pre-push requires
clean matching source, passed Complete and applicable Integration. Required remote
CI enforcement remains session3 work, not evidence from hook configuration alone.

Quick checks owning plan triplets. Complete and Integration run the discovered
native SQL/permission/concurrency/deploy-revert-redeploy lifecycle on an owned
socket-only PostgreSQL18 fixture, then the existing Sqitch registry lifecycle.
They are separate results. Set EGI_PG_BIN, EGI_SQITCH and PERL5LIB for the already
selected native/contained toolchain. No inherited PG connection variable can redirect
Sqitch toward a retained target. The owned native log is `.local/native-last.log`;
fixture cleanup is limited to its generated directory and positively identified
postmaster. This runner creates no migration or production-data change. Standard-
library Python orchestrates existing SQL checks; no new Python test framework is used.

Exit0 means passed,1 failed and2 prerequisite-blocked. Common JSON schema1 reports
the selected profile, owning source commit, check status/reasons and timings.
Importer/sources and current product feature integration stay outside this scope.

## Earlier component setup and evidence

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
After disposable verification and independent review, 009 was applied on
2026-11-24 to the separately authorized local B1 demo after a private checked backup.
The demo retains 594 public services and zero orphan addresses; the register starts
empty and no real login belongs to the new role. No historical inventory/backfill,
remote delivery or staging/production deployment is included.

`010_access` (EGI-81, B3.1) lets the app act with one editorial login while the
database verifies each moderator's session and only then knows the actor: accounts,
OIDC or password identities, 48-hour invitations, 14-day sessions with 8 hours of
idle time, and `release_protection` as the admin's capability. See
[the contract](docs/implementation/access.md). Verified on disposable clusters only
(2026-11-25); not applied to any other database.

`011_editorial` (EGI-82, B3.1) stores visitor contributions privately: global intake
limits without IPs, claims, waiting reasons, per-proposal decisions, outcomes tied to
publications, and the retention purge (contact at closure or 90 days, text 30 days
after closure). See [the contract](docs/implementation/editorial.md). Verified on
disposable clusters only (2026-11-25).

`012_revision_body` (EGI-83, B3.1) reads a service or location revision back as the
body `save_revision` takes, so moderator edits start from the complete aggregate. Same
rules as sync's reader. See [the contract](docs/implementation/editorial.md). Verified
on disposable clusters only (2026-11-26).

`013_editorial_observations` (EGI-84, B3.1) records what a moderator verified as an
observation of the "Redazione EGI" source, so services and locations created in the
workspace cite evidence and publish under the unchanged evidence rule. See
[the contract](docs/implementation/editorial.md). Verified on disposable clusters only
(2026-11-26).

`014_preparations` (EGI-100, Community) adds explicitly shared private text
preparations, exact original input, immutable card versions, request replay and
expected-version saves. Uninvited Admins have no access. See
[the contract and verification limits](docs/implementation/preparations.md).
Only disposable verification is authorized at this stage.

`015_preparation_history` (EGI-101) adds paginated history, compensating undo,
owner-only workspace trash, per-card recovery and guarded 30-day private purge.
See [preparation lifecycle](docs/implementation/preparations.md#history-and-trash--015--egi-101).
No scheduler or environment login is installed by the migration.

`016_community_sources` (EGI-102) separates moderator source registration from
immutable Admin admission. It records registry metadata only; source-evidence
publication enforcement follows in EGI-106. See
[the contract](docs/implementation/community-sources.md).

`017_preparation_jobs` and `018_preparation_candidates` (EGI-103) add isolated
one-dispatch AI jobs, redacted eligible payloads, UTC monthly cost reservations
and explicit candidate creation/updates preserving manual fields. No live model,
credentials or worker login is seeded. See
[the job and candidate contract](docs/implementation/preparation-jobs.md).

`019_community_submissions` (EGI-105) sends a selected confirmed card as an
attributed immutable editorial snapshot, separate from its private original and
from canonical acceptance. It preserves visitor intake/retention and guards the
generic Community closure path. See [the contract](docs/implementation/community-submissions.md).

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
public origin (2026-11-19; the earlier `egi-database` repository and its issues #1–#10 were deleted).
Development uses `dev`; promoting `dev` to `master` needs the user's authorization.
Implementation happens on isolated task branches/worktrees from the fetched `origin/dev`,
tracked in Linear. Issues #1–#10 were delivered through PR #2; the checkpoint notes
below are historical.

The #5–#9 checkpoint adds relational hours and approved calendar effects, territorial
taxonomy, dynamic translations and public directory reads. Read the
[directory operations](docs/implementation/directory.md) for the implemented contract.
The group was reviewed and pushed to dev at 9d4013c. Ticket #10 supplies final
[integrated acceptance](docs/implementation/acceptance.md). The user authorized final
dev delivery, independent review, a PR to master and issue closure after verification.

Community proposal acceptance and publication boundaries are described in
[Community acceptance](docs/implementation/community-acceptance.md).

`023_preparation_source_facts` (EGI-114) preserves literal organization/category
claims separately from edited values and future canonical resolutions. v1 history
and selective snapshots remain immutable; old writes cannot drop v2 facts. See
[the version/evidence/lifecycle contract](docs/implementation/preparation-source-facts.md).
Only disposable verification has been performed; see EGI-117 below for explicit
reference acceptance. App matching/confirmation consumers follow separately.

`024_preparation_fact_candidates` completes EGI-114's provider seam: an explicit
immutable v2 job configuration, original/eligible quotation checks and candidate
materialization with stable private fact IDs. Existing v1 jobs remain compatible;
no model configuration or call is seeded. See the same source-fact contract.

`025_preparation_reference_catalog` and `026_community_reference_acceptance` (EGI-117)
provide bounded authorized catalog pages, context/head-checked choices and atomic
explicit organization draft creation. No lookup/save/extraction publishes an entity.
See [reference resolution](docs/implementation/reference-resolution.md) for v2
decisions, source attribution, publication and rollback boundaries.

`027_preparation_category_matches` completes the optional provider seam: a frozen
public category context in immutable configuration, current pre-dispatch checks,
conditional supplied-key matches and stable unconfirmed resolutions. Existing
context-free protocols remain compatible; no configuration/provider call is seeded.


`029_preparation_resolution_undo` restores literal corrections without reviving
stale reference decisions. Contract33 covers mapped-value undo and stable replay;
see [reference resolution](docs/implementation/reference-resolution.md).

The CW1 private workbench provider (EGI-146–149, migrations 030–037) adds versioned
[interpretations](docs/implementation/workbench-interpretations.md), immutable
[plans and packets](docs/implementation/workbench-plans.md), separate
[analysis/comparison coverage](docs/implementation/workbench-coverage.md), and
[private groups with resumable apply/undo](docs/implementation/workbench-groups.md).
The [context profile](docs/implementation/workbench-context.md) and
[scoped proposal/receipt readers](docs/implementation/workbench-proposals.md)
preserve exact owned source support and explicit human decisions. Model results
never publish or confirm categories; existing explicit Community moderation remains
the canonical boundary. Taxonomy proposals and CSV batch transport remain deferred.

`scripts/verify-workbench.py` uses a caller-selected resource-owner checkout whose
Git revision and source bytes are checked before import. The CW1 native handoff pins
`84044a266dcbabab8319c9f5682d0437c7bea732`; the app tooling is development-only,
with no database runtime dependency or copied resource module. Native SQL 40/41/43/44/45
and shell 42 cover the final proof/recovery/read/retention/concurrency changes on
owned PostgreSQL 18/Sqitch fixtures. These are technical workflow checks using
synthetic data, with no real model call or credentials. Semantic pilot acceptance
and real-provider evaluation remain separate gates.

## Owned native resources — EGI-142

Native plan checks and the separate Sqitch registry lifecycle now use the same
app-owned standard-library resource owner, verified byte-for-byte at the exact
revision in `.checks/tool-source.json`. `EGI_DEVTOOLS_SOURCE` selects its explicit
checkout. Missing or changed provider bytes block the check; no copied fallback.

Before native startup the runner measures the actual temporary filesystem:
less than15 GiB blocks;15–below30 GiB warns;30 GiB or more proceeds. The public
profile reports preflight separately and preserves its existing0/1/2 result codes.
The runner supervises exact-run resources after failures and timeouts; each cluster
checks identity and confirmed shutdown before removal. Failed shutdown preserves
files and fails the check. Existing demo/legacy clusters and backups are untouched.

`sh scripts/verify-disposable.sh` delegates to `scripts/sqitch_disposable.py` using
`EGI_PYTHON` or python3. The retained SQL/registry sequence is in
`scripts/sqitch-contracts.sh`; it is not a standalone database setup command.
Keep selected Sqitch/Perl prerequisites from the setup guide. Resource-policy
probes run with `python3 -m unittest discover -s tests -p test_resource_checks.py`.


## Consolidated native verification

The full runner discovers all SQL and concurrency contracts through the current
plan. A SQL file with a same-stem shell check is that check's committed setup,
not a standalone transaction test. The group concurrency check runs on a separate
owned `egi_workbench` cluster when invoked by the combined `egi_contract` suite;
its committed roles/data cannot contaminate later fixtures or reference races.
The native SQL and Sqitch registry paths both execute the actual race and retain
their separate lifecycle evidence. No existing database is used.

Committed concurrency fixtures intentionally exercise populated canonical state.
The complete checks run their full contract sequence both on a first deployment
and after structural revert/redeploy, using two fresh owned clusters. The second
cluster starts empty for reversion: contract31's committed publication must not
bypass migration026's real-data protection. Both native SQL and actual Sqitch
registry checks retain all discovered contracts, with no migration guard changed.
