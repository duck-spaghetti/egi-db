# EGI database action plan r0.2

Date: 2026-10-05. Status: **approved planning basis; implementation not authorized or started**.

## Basis and approval

- Specification: [EGI canonical database v1.1](specification.md), synthesized from
  the closed domain interview and the user's acceptance of the structural basis.
- Structural detail: [schema proposal v0.2](schema-proposal.md).
- Facts/legacy contract: [API/data inventory](api-and-data-inventory.md).
- Authority: [database AGENTS](../../AGENTS.md) and inherited workspace instructions.
- The user explicitly invoked both `to-spec` and `plan-with-docs`. This authorizes
  specification/plan documents and the implementation-approach interview, not code,
  dependency installation, test execution, DB connections, issue publication or Git delivery.
- Tracker: **GitHub**, selected by the user on 2026-10-05. The user confirms the destination repository
  still needs creation; owner/name/visibility remain to be selected; no remote or issue IDs exist. Specification/plan stay local until
  separately authorized publication.
- The user replied “Confermo tutto” to the presented r0.1 plan and P1/P2 on
  2026-10-05. Record approval of that recommended approach and both choices. Revision
  r0.2 consolidates these selections without expanding scope. Units are not created issues.
- No approved execution model/mode or commit/push scope exists for the implementation set.

## Approach and decisions

### Selected basis

Preserve the accepted domain: place-specific services, shared facilities, role-bearing
providers, stable identity/revisions, approval and restoration, retained source evidence,
relational hours, regional taxonomy and dynamic i18n separated from the app's UI catalog.
Use PostgreSQL/PostGIS, `psql`, Sqitch, and future read-only SQLite.

### Observed environment and repository facts

Read-only inspection on 2026-10-05 found:

| Fact | Planning consequence / limit |
| --- | --- |
| Unborn `master`, no commits/remotes; Markdown files untracked | Preserve docs; establish initial Git history and agreed base before product worktrees. A remote fetch is impossible until a remote exists. |
| One checkout, no managed product worktree or existing plan/tracker config | Do not assume isolation or issue mapping has been configured. |
| `/Library/PostgreSQL/18/bin/psql` and `pg_config` report 18.3 | Native PostgreSQL toolchain exists outside current PATH; pin explicit executable paths. Server state/access not inspected by connection. |
| PostGIS control file declares 3.6.0 | Extension files exist; installed-in-database/loadable status not proven. |
| PATH resolves another `pg_config`, PostgreSQL 12.17 under Anaconda | Avoid accidental toolchain mixing when configuring Sqitch or extension checks. |
| `psql`, `sqitch`, `docker`, `podman` not found on inspected PATH | Does not prove global absence. Sqitch provisioning is a future authorized setup action. No container runtime was found in common checked locations. |
| No code/Sqitch project/harness/CI configured in repo | All proposed new commands/locations below are future contracts, not existing working checks. |

### Recommended scope for the first implementation set

Database structure plus the minimal transaction/read behavior required to verify its
contracts using synthetic fixtures. Do not import production sources or build the app,
matching algorithms, geocoder integrations or file exporters. Store processing evidence
and interfaces for those later capabilities without claiming they exist.

Recommended write surface: controlled SQL/PLpgSQL operations for save/review/publish/
restore and accountable decisions, alongside approved read views/functions. Application
authentication and HTTP adapters remain future work. Treat actor identity as supplied
by a trusted caller role, not an arbitrary public SQL parameter; untrusted readers have
no direct write access to base tables. Database privilege/role scope must enforce this.

Alternative: schema/constraints/public views first, with transaction orchestration in
a future application layer. This reduces current DB behavior code but leaves several
specification criteria unimplemented and unverified; it must not be labelled a complete
publication/rollback implementation. P2 confirms the DB-operation/verification approach; this alternative is not selected.

Recommended environment: use the observed PostgreSQL 18.3 installation with an
explicitly dedicated disposable test database and available PostGIS 3.6.0, after future
connection/extension checks and agreed access configuration. A container remains an
alternative if desired; it is not an assumed new dependency. P1 confirms the native dedicated-test-database target; readiness is still unverified.

### Proposed artifact and code locations

The spec/plan use the existing `docs/design` directory; no new tracker hierarchy is
created. GitHub tracker conventions are documented in `docs/agents/issue-tracker.md`.

Future product locations, not present/created by this session:

- Sqitch configuration/plan at repository root; `deploy/`, `revert/`, `verify/` SQL.
- A `tests/contract/` fixture/acceptance collection under approved P2; companion
  documented runner using selected `psql` and a dedicated target.
- Contract/operation documentation under existing `docs/` conventions.
- No bootstrap/import/export directories until those implementation slices are requested.

The plan recommends checked text/reference data, typed UUID identity, immutable
revision payloads/owned components, relational weekday intervals, frozen taxonomy
releases and reusable original content units. Routine constraint/index mechanics
stay within these contracts; a necessary structural change returns to the user.

## Sequence and proposed tasks

Group names are proposed planning units, not issue identifiers. Every group requires
the approved specification, approved P1/P2 and settled Git/task mapping before execution.
Creation/configuration of the future GitHub repository blocks remote bootstrap and
issue publication, not this planning record. The user already selected a new repository.

| Unit | Depends on | Outcome | Acceptance coverage |
| --- | --- | --- | --- |
| Foundation | Execution prerequisites | Reproducible Sqitch/PostGIS setup, typed identity/revisions and base actor/audit/text ownership | AC25 and structural parts of AC05–AC06 |
| Evidence | Foundation | Retained captures, assertions, processing and resolution/value-evidence decisions | AC07–AC08 |
| Canonical records | Foundation, Evidence | Service/org/place/territory/contact/access payloads and revision-owned relationships | AC01–AC04, AC10–AC12, AC16–AC17 |
| Publication and restoration | Canonical records | Reviewed revision operations, public heads, scoped verification and restore consistency | AC04–AC06, AC09, AC22 |
| Hours and calendar | Publication and restoration | Scoped weekday/date rules, approved shared exceptions and coherent opening contract | AC13–AC15 |
| Taxonomy and translations | Publication and restoration | Territorial frozen hierarchy, filters, partial translations and update queue | AC18–AC21 |
| Public projections | Hours and calendar, Taxonomy and translations | Shared approved public contract, related-change invalidation and export-ready relationships | AC05, AC11, AC16, structural support for AC23–AC24 |
| Integrated acceptance | All prior groups | Coherent clean deployment and contract behavior with documented evidence | Applicable AC01–AC22, AC25; no exporter completion claim |

### Foundation

**Inputs:** specification implementation decisions/testing proposal; schema sections
2–3, 8, 11 and 16; selected environment/tool paths; agreed Git bootstrap exception.

**Outcome:** a clean dedicated database can deploy/verify the first Sqitch dependency
chain with PostGIS, stable typed identities, actor identity and immutable revision
metadata. Establish original-text ownership primitives needed by typed payloads.

**Actions:**

1. Preserve current docs; establish approved initial commit/base/worktree procedure.
2. Configure Sqitch targets without committing credentials; record runtime/tool versions.
3. Add namespaces and PostGIS prerequisites, registry/typed identity ownership,
   components, actor/revision base and audit foundations.
4. Define original-content identity/link primitives; add cross-layer FKs in their
   owning migrations when prerequisites exist. Never disable integrity permanently
   to bypass a dependency cycle.
5. Document empty-database deploy/verify and disposable-target revert limits.

**Examples/checks:** wrong entity type for a revision and cross-owner component
references fail; valid identity/revision succeeds. Saved revision immutability is
established by controlled writes/privileges rather than merely promised in docs.

**Evidence:** dedicated-target identity/version confirmation; clean deploy/verify
logs; negative ownership outcomes. Recovery/revert checks use only disposable targets.
No existing real dataset is altered. Update README/standards/setup documentation.

**Execution prerequisites:** confirmed P1/P2 require setup verification; Git setup remains to establish. Executor must not invent credentials,
install an unselected container system or commit current untracked docs without scope.

### Evidence

**Inputs:** deployed identity base; schema sections 7–8; AC07–AC08.

**Actions:**

1. Add source/dataset/capture/record-version/observation relationships with retained
   raw artifacts/locators, hash and source metadata snapshot semantics.
2. Add processing runs, normalized subjects and immutable assertions.
3. Add match candidate, accountable link/merge/split participant and value/evidence
   relationships. Implement storage integrity, not a matching engine/threshold policy.
4. Link decision evidence to typed revised values without unchecked polymorphic FKs.

**Examples/checks:** two synthetic sources assert conflicting hours; both retained.
Same bytes retrieved twice produce two observations without requiring duplicate
record content. New parser version yields a new interpretation; approved selection
does not silently change. Repeated upstream keys are dataset-scoped.

**Evidence:** deterministic queryable lineage and rejected wrong-owner/type references.
Document normalization/decision input contracts and replay boundaries. A participant
history alone must not be advertised as a complete automated merge engine.

### Canonical records

**Inputs:** identity/text/evidence primitives; schema sections 4–5 and 9; AC01–AC04,
AC10–AC12 and AC16–AC17.

**Actions:**

1. Add typed org/place/service revision payloads and original-field links.
2. Add direct service/org role associations and independent facility host roles.
3. Add place/area context, contacts/labelled shared references, structured access/cost
   and service spoken-language data, with original source notes retained.
4. Add territories/membership/coverage and scalar coordinates/derived geometry;
   record geocoding-result evidence/cache contracts without choosing a geocoder.
5. Add publication-completeness diagnostics separate from draft storage integrity.

**Examples/checks:** separate Castrense/Tuscolano offers share provider identity;
one building hosts healthcare and legal services from separate providers; phone
service has no fake point; coarse itinerant context reports only a known area.
Move keeps service identity and does not modify old shared location coordinates.

**Evidence:** valid synthetic draft shapes and explicit missing-field diagnostics;
invalid coordinate pair and multiple simultaneous current place contexts rejected.
Publication itself is the next group. Document role semantics and privacy boundaries.

### Publication and restoration

**Inputs:** canonical revisions/diagnostics; approved write surface P2; schema sections
3, 8 and 12; AC04–AC06, AC09 and AC22.

**Actions:**

1. Define transactional save/review/publish operations with exact revision ownership,
   actor capabilities and expected-base checks. Public reads cannot mutate tables.
2. Advance public heads/public change sequence atomically; pending edits remain separate.
3. Restore an explicit earlier aggregate into a new revision with reason/origin;
   validate/review before publication; do not cascade restore shared entities.
4. Record component/page verification, preserving checked revision/time and future
   freshness-policy hooks without inventing numerical thresholds.
5. Implement definitive closure discovery/direct-access separation. Keep temporary
   closure distinct; proposed initial default is visible with a clear status, subject
   to review rather than silently claiming the product decided it.

**Examples/checks:** unapproved changed phone does not appear publicly; stale-base
approval fails with a diagnostic; restoring earlier hours/contacts creates a new
revision and leaves an independently edited shared org untouched. Out-of-scope actor
cannot publish a cross-territory change. Checking a phone leaves hours unverified.

**Evidence:** operation outputs, public projection state before/after, audit and
negative authorization results. Proposed checkpoint after this group. Do not make
public changes based solely on mutable session actor input accessible to readers.
Document transactional interfaces, errors and revision/approval guarantees.

### Hours and calendar

**Inputs:** approved publication workflow; schema section 6; AC13–AC15.

**Actions:**

1. Add normalized ISO weekday/day-coverage/interval rules and scoped IANA zones.
2. Add versioned shared calendar events, publication, applicability and typed effects.
3. Define the agreed database opening evaluation surface under approved P2;
   return certainty, basis and transition rather than a persisted is_open_now flag.
4. Handle spillover, contiguous intervals, 24-hour and unknown/partial rules.
5. Make DST ambiguous/nonexistent civil-time behavior deterministic and documented.
   Recommended conservative default: unknown/needs-review for affected occurrences,
   without inventing a definite countdown; confirm as part of this unit's contract.

**Examples/checks:** Monday 22:00–Tuesday 02:00 at Tuesday 01:00 is open; Tuesday
02:00 is outside the half-open interval. Adjacent intervals yield one continuous
closing transition. A holiday advisory returns contact warning with uncertain
exceptional hours. An approved confirmed closure overrides the applicable baseline.
Itinerant points still appear on non-operating days with local schedules.

**Evidence:** fixed instants/dates, weekly-table inputs and identical opening results,
including DST cases from the selected server timezone rules. Source descriptions
beyond supported recurrence remain evidence, not guessed structured schedules.

### Taxonomy and translations

**Inputs:** revision/publication/text/evidence base; schema sections 10–11; AC18–AC21.

**Actions:**

1. Add axes, term identity/revisions, frozen releases, multi-parent links and
   territorial adoption/classification with ownership/version integrity.
2. Implement cycle prevention and descendant filter behavior; cross-axis mappings
   remain separate from is-a edges. No detailed real territory vocabulary is loaded.
3. Add approved partial translations/classes, original-content reuse and territorial
   language priorities without introducing UI catalogs into the DB.
4. Atomically signal affected translation work when changed originals are published;
   unchanged field units retain their approved translations.
5. Freeze/pin release transitions and validate affected assignments; updating a
   shared vocabulary must not silently update unrelated local adoptions/copies.

**Examples/checks:** two parents reach one term/service once; a cycle is rejected.
Florence's hierarchy differs from Rome and a fork edit does not change its source.
Description changes while name stays unchanged: description falls back and creates
work, name translation remains. Old completed translation cannot clear newer work.
An approved ai translation is not automatically ai_verified. Arabic UI is an app
concern; DB returns actual field language/direction without territorial UI restriction.

**Evidence:** deterministic hierarchy/filter queries and before/after translation
selection/worklist state. Explicit FK/owner/version failures. Document release
adoption and text-unit reuse, avoiding all-fields invalidation on any revision save.

### Public projections

**Inputs:** approved canonical data/hours/taxonomy/i18n contracts; schema sections
12–14; AC05/AC11/AC16 and future-export structural criteria AC23–AC24.

**Actions:**

1. Define approved read views/functions with service identity, place/area, local
   classifications, translated/original field selection and labelled relevant contacts.
2. Expose sanitized source attribution and verification/freshness basis; no raw
   payload, draft, personal credential or internal conflict leak.
3. Advance/derive public affected-resource sequence for shared approved relationship
   changes; consistent snapshot reads/export lineage must be possible.
4. Preserve representation needed for future HSDS mapping and territorial SQLite
   snapshots, including closed-service direct access and reference closure.
5. Document unresolved exporter format/default recipes as later integration inputs;
   no file export/validator dependency is adopted here.

**Examples/checks:** ordinary search excludes defunct services, direct lookup labels
them closed; pending shared location/phone edits are absent. Approved shared correction
invalidates affected public resources without claiming direct service payload edits.
Local taxonomy/language coverage selects the intended territory without cloning identity.

**Evidence:** public payload/projection comparisons and negative leak scenarios.
No deployed HTTP routes, HSDS-valid package or SQLite artifact is claimed.

### Integrated acceptance

**Inputs:** all groups, complete planned check collection and selected target.

**Actions:** clean disposable deploy, Sqitch verify, contract fixture checks, permitted
revert/redeploy cycle and fresh post-redeploy checks; review diff/spec/docs and record
remaining future slices explicitly. No live data destruction or implicit production deploy.

**Evidence:** command results with target identity/version, spec-to-check matrix,
review findings/remediation and documentation covering setup, operations/errors,
source lineage, future export boundaries and recovery limits. Proposed final review
checkpoint; no completion claim based solely on migration success.

## Risks and verification

### Approved verification approach, not executed

Use deterministic SQL contract fixtures through the highest agreed DB surface and
`psql` with fail-on-error. Sqitch `verify` validates deployed structure independently
of changing source data. Do not add pgTAP/Python/container dependencies merely to
write checks; reconsider only if the agreed native approach cannot demonstrate
the required outcomes.

Proposed command forms, **not configured or run**:

- `sqitch deploy <dedicated-target>` then `sqitch verify <dedicated-target>`.
- Selected `psql` with `--set=ON_ERROR_STOP=1 --file=<contract-check>` against the
  dedicated test target; isolated transactions/fixtures with expected failure handling.
- `sqitch revert <dedicated-target>` and redeploy only on an explicitly disposable DB.

The concrete target, driver, runner and fixture file names are future setup outputs.
No existing command is claimed passing. Expected failure checks must assert the
intended constraint/error, not pass merely because any unrelated SQL failed.

### Risk controls

| Risk | Planned control |
| --- | --- |
| Untracked docs lost during Git bootstrap | Inventory/preserve them; initial history/base requires user scope; no reset/stash/discard. |
| Toolchain confusion or unintended DB target | Explicit PostgreSQL 18 binary/target checks; refuse unidentified or live target for destructive lifecycle checks. |
| Circular source/revision/text/review dependencies | Dependency-ordered schema definitions and delayed owning FK migrations; final integrity always enabled and checked. |
| Pending shared data leaks publicly | Approved-head joins, role restrictions, consistent transactions and leak fixtures. |
| Restore or new revision invalidates all translations | Field-content reuse and scoped update requests; unchanged-field scenario. |
| Role/actor spoofing | Trusted writer identity boundary, constrained operations/privileges, negative actor/scope checks. |
| A failed run leaves public heads/audit inconsistent | Atomic publication/restore and expected-base guards; retry/error fixture. |
| DST/calendar confidence falsely precise | Deterministic uncertainty and explicit basis; no guessed closure/countdown. |
| Regional vocabulary mutation changes other territories | Frozen releases, pinned adoptions and independent fork identity. |
| Tests depend on mutable real data | Synthetic fixtures only; bootstrap later. |

Restore of service content and Sqitch schema revert are different operations. User
revision restore must preserve history; Sqitch revert is schema recovery/lifecycle
work and may remove tables in a disposable target. Production recovery needs a
separate backed-up/deployed-data policy when production exists.

### Advisory model guidance

Applying `recommend-model` criteria: this is coupled schema/migration/publication
work, not mechanical translation of a table list. Preferred advisory executor/reviewer:
`gpt-6.1-sol` with `high` reasoning for the contract-heavy groups and integrated review;
use stronger reasoning/capability if ownership, concurrency, temporal integrity or
publication isolation cannot be established by the planned checks. Advice does not
select/change the current model or authorize delegation. Detailed docs alone do not
justify handing consequential migration behavior to a weaker model. Exact execution
model can remain user-selected when tasks are created.

## Open decisions

### Resolved planning choices and execution prerequisites

| Item | Recorded choice | Prerequisite / limit |
| --- | --- | --- |
| P1 — Environment | Confirmed: native PostgreSQL 18.3 with dedicated disposable test database, explicit toolchain and available PostGIS files; Sqitch later provisioned. | Connection/extension readiness, access and exact target still need future setup verification; no container selected. |
| P2 — Contract and verification | Confirmed: DB-level operations and approved views/functions; native SQL synthetic contract checks with psql/Sqitch. | Seam and approach approved; no tests created/run or dependency installed in this planning turn. |
| GitHub destination — partially settled | User confirms a repository is still to be created; propose a dedicated database repo. | Owner/name/visibility and creation/delivery scope are prerequisites for the later GitHub setup/issue phase, not repeated questions about whether a repository already exists. |

P1/P2 are settled; the planning interview is concluded for this revision. Reuse
approval of the presented recommended approach instead of asking the same questions
again. GitHub is selected but the repository still needs creation. Finalize owner/name/
visibility and creation/publication scope in that next phase, before creating issues.
No deployment, repository creation or issue publication is authorized by this plan alone.

Before implementation: establish Git base/bootstrap and isolation, tool/setup scope,
execution scope and whole-set/stepwise mode. Planned review checkpoints follow
Publication and restoration and Integrated acceptance; the mode determines pauses.
Remote push/issues require their own explicit delivery scope. Numerical freshness,
geocoder provider, API stack, exporter format and detailed vocabulary remain deferred
without blocking the structural set's applicable acceptance contracts.

## Execution record

| Item | State |
| --- | --- |
| Specification | v1.1 consolidates the selected test seam; structural/domain basis unchanged |
| Plan | r0.1 approach and P1/P2 confirmed by the user; r0.2 is their approved consolidation |
| Tracker | GitHub duck-spaghetti/egi-database; approved issues #1–#10 published with native dependencies |
| Execution mode | Not selected for any implementation set |
| Implementation | Not started; no SQL/migrations/bootstrap/tests created |
| Environment actions | Read-only executable/control-file inspection only; no DB connection/service start/install |
| Git delivery | origin configured by user request; no commit, push or PR performed |
| Evidence | Document synthesis and link/content checks only; no implementation verification results |

Approval is recorded above. This phase concludes at the agreed planning boundary;
issue creation and execution are subsequent phases.

## Revision history

- r0.1: presented specification/approach, synthetic checks and P1/P2 choices.
- r0.2: records the user's “Confermo tutto”; native environment and DB contract/check
  surface selected. Editorial consolidation, no new tasks or scope. GitHub creation,
  issue mapping and implementation remain subsequent separately scoped phases.

## Ticketing session update, 2026-10-05

The user created duck-spaghetti/egi-database and authorized setting origin and
running to-tickets for this plan. Origin is configured; GitHub inspection confirms
private visibility, default branch main and no issues. These facts supersede the
earlier repository-creation prerequisite; the approved r0.2 approach is unchanged.
The proposed 10-ticket breakdown separates weekly hours from calendar effects and
taxonomy from translations. Draft review numbers are not issue identities.
The user approved the 10-ticket breakdown (“va benissimo”). Issues #1–#10
were published under that authorization and verified against their intended bodies
and native blocking relationships. No commit/push or implementation has occurred.
Relevant plan context and specification outcomes will be included in issue bodies
while maintained documents remain unpublished. Git base/bootstrap, tool/setup scope
and execution mode remain implementation prerequisites.

## Published task mapping, 2026-10-05

The user approved the proposed breakdown. All 10 issues are open; their titles,
exact bodies and native blocking edges were read back and verified. The table is
the task-to-issue mapping for approved plan r0.2, not a new architectural revision.
The earlier planning prerequisites describe the state before the user created the
repository; repository creation and ticket publication are now fulfilled.

| Issue | Approved plan section | Blocked by |
| --- | --- | --- |
| [#1 — Establish reproducible database deployment and revision ownership](https://github.com/duck-spaghetti/egi-database/issues/1) | Foundation | None |
| [#2 — Retain source evidence and accountable canonical selections](https://github.com/duck-spaghetti/egi-database/issues/2) | Evidence | [#1](https://github.com/duck-spaghetti/egi-database/issues/1) |
| [#3 — Save usable service drafts across places and territories](https://github.com/duck-spaghetti/egi-database/issues/3) | Canonical records | [#2](https://github.com/duck-spaghetti/egi-database/issues/2) |
| [#4 — Publish, verify and restore exact service revisions](https://github.com/duck-spaghetti/egi-database/issues/4) | Publication and restoration | [#3](https://github.com/duck-spaghetti/egi-database/issues/3) |
| [#5 — Evaluate weekly service hours and closing transitions](https://github.com/duck-spaghetti/egi-database/issues/5) | Hours and calendar | [#4](https://github.com/duck-spaghetti/egi-database/issues/4) |
| [#6 — Apply approved shared calendar advisories and overrides](https://github.com/duck-spaghetti/egi-database/issues/6) | Hours and calendar | [#5](https://github.com/duck-spaghetti/egi-database/issues/5) |
| [#7 — Adopt territorial taxonomies and filter by descendants](https://github.com/duck-spaghetti/egi-database/issues/7) | Taxonomy and translations | [#4](https://github.com/duck-spaghetti/egi-database/issues/4) |
| [#8 — Resolve partial translations and signal outdated content](https://github.com/duck-spaghetti/egi-database/issues/8) | Taxonomy and translations | [#4](https://github.com/duck-spaghetti/egi-database/issues/4) |
| [#9 — Expose a coherent approved public directory projection](https://github.com/duck-spaghetti/egi-database/issues/9) | Public projections | [#6](https://github.com/duck-spaghetti/egi-database/issues/6), [#7](https://github.com/duck-spaghetti/egi-database/issues/7), [#8](https://github.com/duck-spaghetti/egi-database/issues/8) |
| [#10 — Verify the integrated database lifecycle and acceptance contracts](https://github.com/duck-spaghetti/egi-database/issues/10) | Integrated acceptance | [#9](https://github.com/duck-spaghetti/egi-database/issues/9) |

Issue #1 is the initial implementation frontier. Git bootstrap/base, task isolation,
tool/setup authorization and whole-set/stepwise mode must be settled before execution.
Issue publication does not authorize implementation or commit/push. Relevant approved
plan sections and specification outcomes are embedded in the issue bodies; full
structural documentation remains available locally and has not been pushed.

## Execution agreement, 2026-10-05

The user accepted the recommended grouped stepwise implementation, then explicitly
requested execute-reviewed-task. First authorized group: issues #1–#4; pause after
publication/restoration acceptance. Later groups #5–#9 and #10 require continuation.
The user selected dev as development base and master as completed integration target.
Preserve the remote initialization commit 87cc9d3d1b1637f59b4b26e570fa5b86e8a63369
(currently main). Create master at that base and publish the initial documentation
commit to dev. Keep main intact. Product work uses an isolated task branch/worktree
from verified origin/dev. Scope includes native Sqitch setup, approved SQL structure
and operations, dedicated disposable PostgreSQL/PostGIS verification and synthetic
checks. Existing server/data and original app/sources remain untouched.
Implementation delivery and final merge require verified reviewable results; the
current bootstrap push is specifically authorized. Do not advance past checkpoint #4.
