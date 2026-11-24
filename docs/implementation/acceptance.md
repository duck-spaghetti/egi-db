# Integrated database acceptance — issue #10

## Approved scope and execution

Specification v1.1, action plan r0.2 and GitHub issue #10 require integrated native
PostgreSQL/PostGIS/Sqitch acceptance, not an exporter or application rollout.
The user reviewed issues #1–#9 and authorized their dev delivery plus #10 execution.
The actual fetched base is 9d4013c6d1f53a134ace042ff3d9be95d101d137; isolated
branch task/egi-database-10 retains the final implementation. The user approved
final delivery and requested independent review, a PR to master and issue closure.
The historical result below records the earlier self-review; the independent
[release review](review.md) and remediation supersede that checkpoint state.

Run `scripts/verify-disposable.sh` with the selected Sqitch/Perl runtime as described
in [setup](setup.md). It creates a unique private cluster under /private/tmp,
disables TCP, selects only its own Unix socket and runs psql with ON_ERROR_STOP.
The log identifies actual data directory, target egi_contract, port and versions.
No existing server, source-populated database or original source/app is used.

The lifecycle first deploys through 003_governance and runs #1–#4 contracts,
then adds 004_directory. It performs Sqitch verify, clean-data checks and ten
transaction-local behavioral SQL fixtures. Two real connections exercise the
mutation lock and stale-base SQLSTATE. Full revert/redeploy is followed by another
structural/clean-data/behavioral check pass and another two-connection test.
The trap stops/removes only the cluster created by this invocation.

## Specification-to-check matrix

Paths below are relative to tests/contract. The SQL labels identify concrete
assertions; expected-error helpers check the intended SQLSTATE and, where supplied,
the actual diagnostic. FK/check/unique tests deliberately identify constraint error
classes; they do not pass merely because unrelated SQL failed.

| Criterion | Concrete evidence | Scope or qualification |
| --- | --- | --- |
| AC01 | 03-canonical.sql shared facility; 10-integrated.sql distinct simultaneous service IDs and published independent offers in one building; 07-taxonomy.sql classifications | Location, service and provider identities stay independent. |
| AC02 | 10-integrated.sql published move, retained original association, unchanged old location head and remaining independent offer | A move is a new revision of the same service, not a new shared-location revision. |
| AC03 | 04-publication.sql usable direct/shared telephone channel; 10-integrated.sql approved online service without place and itinerant area without fabricated point | Mode usability gates are tested; coordinates are optional. |
| AC04 | 03-canonical.sql incomplete diagnostics/unknown cost; 04-publication.sql invalid review; 10-integrated.sql evidence-free complete-fields draft is retained and cannot be approved | Delivery mode is structurally required even for a service draft. Optional provider/hours remain optional. |
| AC05 | 04-publication.sql pending shared/service changes, exact approval and stale submissions; 09-directory.sql shared draft hidden; 05-concurrency.sh two-connection 40001 with one retained winner | No blind retry or silent overwrite; reads follow approved heads. |
| AC06 | 04-publication.sql retained restore origin/access/contact; 05-hours.sql hours restore; 06-calendar.sql effects restore; 07-taxonomy.sql pinned assignments restore; 10-integrated.sql one combined published move/restore with current shared endpoint | Restoration creates and reviews a new revision; verifications are not fabricated/copied. |
| AC07 | 02-evidence.sql retained positive/negative assertions, selected evidence and type-safe resolution; 10-integrated.sql supporting and contradicting schedule assertions; interval-level decisions in 05-hours.sql | Selected values carry actor/reason/evidence decisions. Automated matching/selection engines remain a later source-processing slice; no automatic selection is claimed. |
| AC08 | 02-evidence.sql repeated retrieval, reused version, two parser interpretations, dataset-scoped key and capture mismatch rejection; 10-integrated.sql failed/404 capture leaves published service intact | Source retrieval/parser workers remain future bootstrap/processing; the retained storage and absence of automatic closure are exercised. |
| AC09 | 04-publication.sql phone check does not verify hours; 05-hours.sql individual interval check; 09-directory.sql missing/old checks and explicit aging warning | Numerical review thresholds remain optional caller policy, not a seeded default. |
| AC10 | 03-canonical.sql host is not inferred; 10-integrated.sql operator/funder roles and independent building host | Unknown/no provider is publishable; multiple roles remain distinct. |
| AC11 | 04-publication.sql explicit linked endpoint and private/unrelated exclusion; 09-directory.sql labelled endpoint/private label read denied; 10-integrated.sql shared correction remains current after restore | Linked endpoints are references, not duplicated contact payloads. |
| AC12 | 03-canonical.sql unknown cost/requirements; 10-integrated.sql appointment/referral/document/eligibility states, original notes and variable cost | Audience classifications remain separate from access-condition rows; no automatic eligibility exclusion exists. |
| AC13 | 05-hours.sql ISO day tables, overnight boundaries, adjacent periods, effective date windows, 24h, unknown/partial/scope separation and repeated/skipped DST | User-confirmed civil-clock semantics apply. Transition horizon is eight elapsed days and is exposed; null is not a promise of indefinite operation. |
| AC14 | 06-calendar.sql hidden pending advisory, contact warning without countdown, approved closure/replacement, overnight effect, conflicts and related sequence | Exact approved event/effect revisions are separate; ordinary review cannot be bypassed. |
| AC15 | 10-integrated.sql published mobile area remains listed when closed, area has no invented coordinates, explicit only_open filter excludes it | Each place-specific mobile offer has its own service identity/schedule. |
| AC16 | 10-integrated.sql two map memberships, one coverage area and separate eligibility condition under one service ID; 07-taxonomy.sql independent second-territory adoption | Territory-specific taxonomy and translation configuration are supported; no Rome singleton is seeded. |
| AC17 | 03-canonical.sql generated point/scalar agreement; 10-integrated.sql chosen provider result, retained competing/failed candidates and selected_coordinates_mismatch rejection | No external geocoder call or routing/transport processing is executed. |
| AC18 | 07-taxonomy.sql frozen release, cycle/cross-axis rejection, independent copied identities/hierarchy; 10-integrated.sql copied term label and new local hierarchy edited without changing source | No auto-sync; adoption is explicit. |
| AC19 | 07-taxonomy.sql multi-parent deduplication, OR within an axis, AND across axes and wrong-territory/axis exclusion | Frozen adoption/release context, not label matching, drives expansion. |
| AC20 | 08-translations.sql human/ai/ai_verified, partial fallback and rtl metadata; 10-integrated.sql description-only translation and different territory priorities | Linguistic verification and editorial approval differ. UI catalogs/layout remain app concerns; arbitrary preferred language still falls back. |
| AC21 | 08-translations.sql pending original hidden, unchanged name unit retained, changed description fallback/work, old publication rejection and newer requirement unaffected by old completion | Translation history and exact original bindings remain retained. |
| AC22 | 04-publication.sql temporary discovery/defunct direct access; 09-directory.sql reader cannot write or access internal records, defunct excluded from snapshot but direct detail retained | No urgent-report bypass or unauthenticated mutation surface exists; accredited/self-service UI remains later work. |
| AC25 | 00-clean.sql no domain/source/actor/vocabulary seed after deploy and after redeploy; Sqitch verify independent of synthetic records | Real data/bootstrap is separate. Test fixture SQL is not a source loader. |

AC23 (HSDS serialization/default recipes/validator output) and AC24 (SQLite package
construction and consumer compatibility) remain explicitly future slices. Public
projection, exact IDs, approved related heads, coordinates and export-manifest
lineage provide structural inputs; no completed artifact/conformance is claimed.

## Review findings and recovery

The final task adds tests and operational evidence without editing any published
migration or changing the database/API contract. The initial integrated negative test
expected a generic geocoding message; inspection confirmed selected_coordinates_mismatch.
The fixture now asserts that exact diagnostic. This was a test-expectation correction,
not a production behavior change or relaxed constraint. The final diff was reviewed
against the approved scope and matrix; relevant lifecycle checks were rerun.

[Revision operations](operations.md) and [directory operations](directory.md) document
trusted session actors, territorial capabilities, expected-base errors, source
lineage, hours/calendar/taxonomy/i18n reads and public/private boundaries.
READ COMMITTED and one advisory transaction lock serialize controlled writes.
Read snapshots use a single stable statement or a consistent read-only transaction.

Editorial restoration preserves history and requires fresh approval. Sqitch revert
removes structural tables; it is verified on owned disposable fixtures only and can
fail with retained data that violates an older type contract. Production recovery
requires reviewed backup, restoration and deployed-data policy. This acceptance run
does not authorize production deployment, structural destruction of live data,
force-push, issue closure or master merge.

## Next slices

Real source capture/normalization/bootstrap, detailed territorial vocabulary,
application identity/pooling and HTTP endpoints, chosen freshness policy,
HSDS required-field recipes/serialization validation, and SQLite exporter/consumer
validation remain future work. Transport enrichment/routing and organization
self-service retain their previously agreed future scope.

## Recorded final result

On 2026-10-05 the complete runner exited 0 on egi_contract, created at
/private/tmp/egi-contract.enHRZN/data with Unix-socket port 65432 and no TCP
connection. PostgreSQL 18.3, PostGIS 3.6.0 and Sqitch 1.6.1 were logged. Upgrade,
structural checks, all fixtures, concurrency and revert/redeploy repetition passed.
The cluster was stopped/removed. Whitespace and shell syntax checks passed;
published migration/plan diff against 9d4013c is empty. Final human review and
local task delivery remain pending; this result is not production deployment.

## Consolidated initial release

The user subsequently authorized four numbered baseline changesets. Historical
ten-change evidence above is retained; current final verification uses atomic
001_foundation, 002_canonical, 003_governance and 004_directory and repeats all
behavioral/clean-data/concurrency checks. It is a fresh initial baseline, not an
old-registry upgrade. No live target or Git history is rewritten.

## Post-review final verification

The complete runner exited 0 again on 2026-10-05 after all three independent-review
findings were corrected. Target: egi_contract, /private/tmp/egi-contract.M3wzaF/data,
private socket port 65432, no TCP; PostgreSQL 18.3, PostGIS 3.6.0, Sqitch 1.6.1.
Both complete deployment cycles passed structural verification, clean-data checks,
ten behavioral contracts and real concurrency. New assertions cover previous-day
closing/countdown, taxonomy adoption sequence with no services, verification lock
contention (55P03) and rejection of REPEATABLE READ (22023).
The runner removed its cluster. Evidence: work/execution/review-remediation.log.
