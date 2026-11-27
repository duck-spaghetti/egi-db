# Required development verification — EGI-138

The PR-to-dev workflow invokes the owning Complete command and the canonical
commit-object validator. Official GitHub actions are fixed to exact source SHAs;
the shared app tooling revision comes from `.checks/tool-source.json` and its bytes
are verified before import. No provider credentials or live databases are used.

The Ubuntu24.04 runner installs PostgreSQL18/PostGIS and Sqitch from their selected
package sources, records versions and creates only the ephemeral runner's
`/private/tmp` base for the existing owned-resource interface. Native SQL and Sqitch
registry checks remain distinct. The same owning command now discovers database
resource-command regressions after its capacity preflight, including below15 GiB
blocking and non-success propagation for a failed supervised shutdown stage.

Local command: `python scripts/check.py --profile complete --json`. Set the selected
`EGI_PG_BIN`, `EGI_SQITCH`, optional runtime `PERL5LIB`, and `EGI_DEVTOOLS_SOURCE` as
documented in the README. CI consumes this command, not a separate SQL orchestration.
Reports and actual native/failure receipts are retained as workflow artifacts.

The exact required status identity is **EGI / database**. Repository rule activation
and controlled failed/passed check evidence must be read back before enforcement is
claimed. Scoped validation PRs do not authorize a protected-branch merge; final
delivery/acceptance remains the milestone's separate gate. Existing protections
must be preserved. Unavailable settings or runtime capability leaves acceptance blocked.

Primary references: [GitHub required status rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[Sqitch Debian packages](https://sqitch.org/download/debian/).
