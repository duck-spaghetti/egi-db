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
