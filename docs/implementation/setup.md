# Database setup and verification

## Selected runtime

The first execution group uses native PostgreSQL 18.3, PostGIS 3.6.0, Sqitch 1.6.1
and DBD::Pg 3.21.2. PostgreSQL binaries are explicitly selected from
`/Library/PostgreSQL/18/bin`; Anaconda's PostgreSQL 12 tools are not the target.
The native Perl driver was built against Homebrew libpq 18.6. Driver/client version
does not change the selected server version.

Homebrew's Sqitch formula failed in its bundle build with a working-directory
permission error. The selected Sqitch and PostgreSQL driver were successfully
installed through cpm into a contained workspace runtime. No Docker/container
system, pgTAP, Python application/test dependency or existing database was adopted.
Homebrew installed Sqitch's supporting Perl/cpm/libpq packages before that failure.

For the contained runtime in this session, set `PERL5LIB` to its `lib/perl5` directory
and `EGI_SQITCH` to its `bin/sqitch`. A normal Sqitch installation can use its PATH
executable. Tool installation is separate from the repository; no executable or
credential is committed.

## Reproduce the checkpoint

From the repository root:

```sh
EGI_PG_BIN=/Library/PostgreSQL/18/bin \
EGI_SQITCH=/path/to/sqitch \
sh scripts/verify-disposable.sh
```

For the contained installation, also export its `PERL5LIB` before this command.
The script creates its own private temporary cluster, initializes it, disables TCP,
creates `egi_contract`, deploys/verifies the structure, runs deterministic SQL
contracts and two-connection concurrency, reverts/redeploys and repeats checks.
Its trap stops and removes only the cluster it just created. Socket authentication
is trust within the owner's private temporary directory; this is a test harness,
not a production authentication configuration.

The four SQL contracts are transaction-local and roll back fixtures. The concurrency
check intentionally commits synthetic setup to exercise independent connections;
the enclosing lifecycle removes it with the disposable schema revert. Run that
check only on a newly deployed `egi_contract` target. Neither lifecycle nor fixtures
connect to the existing EDB cluster or any source-populated database.

The runner checks PostgreSQL major version 18; the execution evidence records the
exact 18.3 version used here. Updating the selected runtime remains a reviewed choice.

## Deployment and operational identity

Sqitch plan/deploy/revert/verify scripts govern structure. Real data population,
source retrieval/normalization jobs and detailed vocabulary remain separate work.

An administrator deploys the schema and registers trusted actors by actual PostgreSQL
login role in `governance.actors`. Grant a writer login membership in `egi_writer`;
then assign explicit propose/approve/publish/verify capabilities, globally or by
territory, through `governance.actor_grants`. `egi_reader` grants approved views only.
Application authentication and pool identity propagation are later integration work;
a mutable actor request parameter or reader-controlled session variable grants no
editorial identity. Session authorization is reserved for privileged test setup.

Controlled writes require READ COMMITTED transactions. An advisory transaction lock
serializes edits/reviews/publications so shared-resource scope checks and expected
heads remain consistent. Read-only projections can be assembled using one consistent
transaction snapshot. This simple concurrency policy prioritizes correctness for the
initial directory; increasing write concurrency needs equivalent acceptance evidence.

Current deploy creates cluster roles if absent. Revert retains them because other
databases may use them. It also retains PostGIS and the restricted public-schema
CREATE privilege. Database owners/administrators remain trusted and can bypass
ordinary role boundaries; app users are never database owners.

## Recovery

Revision restoration is an editorial operation creating a new retained revision.
Sqitch revert is structural recovery and can destroy tables. Use the disposable
runner for lifecycle verification; production backup/recovery is a separate future
policy. Published migrations should receive new dependency-ordered changes rather
than edits to released history. The initial migrations are still under checkpoint
review and have not been delivered as product migrations to dev/master.
