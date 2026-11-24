# EGI canonical database specification v1.1

Date: 2026-10-05. Status: **consolidated specification with approved implementation approach;
first implementation group authorized; execution tracked in the action plan**.

The user accepted the existing structure as sufficient and explicitly requested
`to-spec`, followed by `plan-with-docs`. This document synthesizes settled decisions;
it does not reopen the domain interview or authorize implementation. Structural
baseline: [schema proposal v0.2](schema-proposal.md). Research/decision history:
[canonical database design](canonical-database.md). Definitions: [glossary](../../GLOSSARY.md).

## Problem Statement

EGI needs a dependable directory of humanitarian and social services. Existing
collections and application drafts cannot yet represent multiple sources with
conflicting information, reliable hours, editorial approval, revision history,
independent territorial taxonomies and partial dynamic translations consistently.
Copying their tables would also preserve assumptions that every service has a
point location, that a building determines its provider and that one category set
fits every territory.

Users need to distinguish the service offered at each place, understand how and
when to access it and recognize unknown or aging information. Editors need to retain
incomplete records, resolve conflicting assertions and correct or restore information
without destroying its source lineage or publishing unapproved changes.

## Solution

Build one authoritative PostgreSQL database with PostGIS, managed structurally by
Sqitch and usable through `psql`. Separate canonical information, source evidence,
governance, audit, geography, taxonomy and dynamic i18n responsibilities.

Represent distinct services per delivery place/area, reusable locations and several
role-bearing organizations per service. Preserve entity identity across genuine moves.
Maintain draft revisions and approved public versions over stable identity. Retain
original evidence and accountable decisions, including per-component verification,
restoration and source reprocessing history.

Use relational operating schedules and one initially shared exception calendar.
Support local territorial taxonomies and partial translations with original-field
fallback and visible translation-update work. Define one approved public dataset
contract that future app, HSDS and read-only SQLite projections can consume.

The first implementation plan concerns the database structure and agreed database
behavior with synthetic acceptance evidence. Real-data bootstrap, exporters and the
new application are separate implementation slices; their future contracts are
specified here so the structure can support them.

## User Stories

1. As a directory user, I want separate offers at separate places and accurate local
   contacts/hours, including several services in one building, so I can find the right
   service without confusing a host organization with a provider.
2. As an editor, I want to preserve drafts, sources and conflicting claims while
   publishing only approved information, so correction does not erase evidence or
   leak pending changes.
3. As an editor, I want scoped verification and a traceable restore of earlier
   information, so I can maintain confidence and recover from mistakes.
4. As a user, I want table-readable hours, open-now interpretation and a closing
   transition when known, with uncertainty and access restrictions clearly separate.
5. As a territorial maintainer, I want to adopt a shared taxonomy or an independent
   local vocabulary and set content-translation priorities, so a new territory need
   not inherit Rome's classifications or language priorities.
6. As a multilingual user, I want available approved translations field by field,
   with original fallback and language/direction metadata, independent of UI catalogs.
7. As a data maintainer, I want reproducible source processing and future HSDS/SQLite
   projections, so datasets share canonical identity without becoming separate authorities.

## Acceptance Criteria

The identifiers below are specification acceptance references, not issue/task IDs.
Outcomes are future behavior to verify; none is claimed implemented.

| ID | Observable outcome and relevant failure cases |
| --- | --- |
| AC01 | Similar services at different delivery places have distinct IDs/pages/history. One location can host several categories and providers; a host relationship never forces a provider relationship. |
| AC02 | A genuine permanent move retains service ID/history and records the new place. The old shared location and its other services do not change. Simultaneous offers at two places remain distinct. |
| AC03 | Telephone/online offers can be approved without coordinates if a usable channel exists. In-person offers require identifiable location/access directions; coarse itinerant areas are labelled without invented point coordinates. |
| AC04 | An incomplete record remains in draft with specific validation diagnostics. Publication requires name, meaningful description, delivery mode, source evidence, mode-specific usability and editorial approval. Missing optional hours/provider does not delete it. |
| AC05 | Pending edits do not change the approved public service or leak through shared contacts/locations/orgs. Approval identifies an exact saved revision and is attributable. A stale-base write/review cannot silently overwrite newer approved content. |
| AC06 | A restore creates a new revision identifying the earlier revision and actor. Hours, contacts, access and links are restored within explicit scope; shared organization content is not implicitly restored. It must pass validation/approval before becoming public. |
| AC07 | Every selected scalar/collection can be traced to supporting or conflicting source assertions and a decision. Multiple sources and negative claims survive new imports and interpretations. Automated straightforward selections follow explicit policy; ambiguity stays reviewable. |
| AC08 | Repeated capture/processing retains retrieval observations, stable dataset-scoped keys, immutable record versions and processor/configuration identity. Parser changes create new interpretations; source disappearance alone does not close/delete a service. |
| AC09 | Verification can cover a field/component or an entire page revision. Import/edit time is not verification. Checking a phone does not verify hours; aging information remains visible with a reconfirmation warning. |
| AC10 | Multiple organizations can hold distinct roles for one service. Management/operational delivery differ from funding/support; unknown provider remains representable. |
| AC11 | Contacts show available relevant channels, subject scope and purpose. Reusing an organization endpoint does not copy it into every service or expose unrelated/private contacts. |
| AC12 | Appointment, referral, document and eligibility requirements support structured values plus original notes. Cost is free/paid/variable/unknown. Missing information is not inferred as free/unrestricted, and audience taxonomy does not automatically exclude other users. |
| AC13 | Weekly tables and open-now interpretation use the same scoped local-time rules. Split shifts, previous-day overnight spillover and 24-hour operation are coherent. Missing/partial/conflicting declarations preserve uncertainty; contiguous applicable intervals yield the same closing transition. |
| AC14 | An applicable approved shared-calendar advisory says hours may vary and invites contact without fabricating closure/opening or a confirmed countdown. A confirmed closure/replacement uses evidence and a separately approved event/effect. |
| AC15 | All itinerant delivery places remain visible on non-operating days with their own days/hours; open-now is a separate filter. Known area without an exact stop is displayed as an area with explicit uncertainty. |
| AC16 | Map membership, service coverage and geographic access requirements remain distinct. The same entity can belong to overlapping territories without duplicate identity; Rome-only assumptions do not block another area. |
| AC17 | Canonical coordinates retain chosen evidence/provider/status and scalar latitude/longitude. Derived geometry agrees with them; missing geography does not block normalization/resolution. Competing/failed geocoder results remain retained. |
| AC18 | Each territory can adopt a shared taxonomy or an independent local copy. Independent edits do not affect the source taxonomy. A term may have multiple broader parents within one axis, but cycles/cross-axis hierarchy links are rejected. |
| AC19 | Category search includes the selected term and descendants in the territory's adopted hierarchy, ORs selections within an axis, ANDs distinct axes and returns each service once across multiple hierarchy paths. |
| AC20 | A description may be translated while the name remains original. Human/ai/ai_verified classes distinguish linguistic verification from editorial approval; approved ai content is allowed. Language priorities vary by territory without restricting globally supported UI languages. |
| AC21 | Publishing a changed original field preserves old translation history, uses original fallback for that field and creates visible update work. Unchanged originals keep their translations. Completing an obsolete translation cannot resolve work for a newer original. Pending original edits do not disrupt the published original's translations. |
| AC22 | Permanently closed services leave ordinary discovery but retain clearly labelled direct access and history. Temporary closure is a distinct operational state; an unconfirmed urgent report cannot bypass ordinary review in the MVP. |
| AC23 | A future HSDS projection applies explicit versioned required-field defaults, validates the resulting output and excludes remaining invalid records with diagnostics. Defaults do not erase canonical uncertainty/evidence. Missing optional coordinates/hours alone are not an invalid service. |
| AC24 | A future territory-scoped SQLite snapshot preserves stable IDs, approved public content, available translations, hours, relevant taxonomy and closed-service direct access. Drafts/raw evidence/full editorial history are absent; references close and version/date identify a consistent canonical snapshot. |
| AC25 | Structural deployment and live data population are separate. Sqitch structural checks do not depend on mutable imported records; real-data loading is a later reproducible bootstrap. |

### Remaining technical acceptance details

These do not reopen the product requirements. The action plan must settle the
execution surface, environment and verification approach before implementation.
Exact DST ambiguity policy, approved shared-resource invalidation, validation
diagnostic shapes, active/public hierarchy version transition and atomic
translation-update signaling must be made executable by the relevant planned unit.
Temporary-closure default search visibility, numerical freshness thresholds and
precise HSDS format/default recipes may remain explicit configuration decisions
before their dependent slice, not silently guessed values.

## Implementation Decisions

### Settled structural basis

- PostgreSQL/PostGIS is the authority, `psql` the client and Sqitch the schema manager.
  SQLite is a read-only distribution, not bidirectional synchronization.
- Canonical data, source evidence, governance, audit, geography, taxonomy and dynamic
  i18n have separate English namespaces. Public projections have an explicit contract;
  derived computation space is a future extension.
- Services are place/area-specific, locations host many services, and service/provider
  role links are independent from facility operator/host links.
- Stable identity supports saved revisions, working/public heads, accountable approval
  and new-revision restoration. Aggregate history includes related information.
- Core hours are relational. Local recurrence, dated effects, uncertainty and access
  are separate. The initial calendar is shared; later organization calendars are possible.
- Taxonomy has independent vocabulary identity, coherent releases and territorial
  adoption/classification context. Copying a vocabulary does not create automatic sync.
- Dynamic text is field-granular, with original identity/revision and translations.
  UI catalogs are not database content. Original changes create translation work.
- Required-field export defaults are explicit and output validation remains necessary.

### Proposed physical realization retained from the accepted structural proposal

The user considers the proposal sufficient as the basis for this specification;
this is not a claim of independently reviewed executable constraints. Recommend
typed UUID identities, typed revision payloads and owned component version rows;
composite ownership constraints; immutable captures/assertions; explicit resolution
and value-evidence decisions; content identity reusable for unchanged original fields;
frozen taxonomy releases and pinned territorial adoption.

The plan must determine how transactionally controlled write operations and approved
read projections expose these contracts. Table responsibilities stay as described
in the structural baseline; exact SQL, target engine versions, permissions and
constraint enforcement mechanisms are implementation-planning choices.

## Testing Decisions

### Selected behaviors and approved verification surface

Good checks demonstrate external contract outcomes, including negative cases,
instead of asserting every helper/table implementation. Prefer one principal
database contract surface: save/review/publish/restore operations and approved
public projections, with deterministic synthetic scenarios. The user confirmed this new seam in `plan-with-docs`, together with native SQL
synthetic checks via psql and Sqitch. It is approved as the intended interface, not
an implemented API. The native PostgreSQL 18.3 dedicated-test environment is selected;
actual server/extension readiness remains to be checked during future setup.

Use additional low-level checks only for structural integrity not observable through
that surface: typed ownership/FKs, impossible coordinate pairs and hierarchy cycles.
Sqitch deploy/verify/revert behavior is a separate structural lifecycle check in
a disposable environment. Do not run reversions against live/source-populated data.

No product code, automated suite, Sqitch project, application adapter or equivalent
existing test seam was found in the new database repository. The older app's fixtures
and serializers are evidence for scenarios, not a ready harness. The implementation plan now selects native psql/Sqitch synthetic checks and a
dedicated native PostgreSQL test database. Its review checkpoints are documented;
actual execution/addition of checks still requires the later implementation scope. No tests were created or run
while producing this specification.

### Future projection verification

HSDS validation against a pinned profile and SQLite referential/public-policy
checks belong to their later exporter slice. The initial structural scope must
preserve the relationships required by AC23–AC24 but must not claim those exporters
or consumer-timezone parity are implemented by creating tables alone.

## Out of Scope

- Product implementation in this specification/planning session.
- Importing real source collections or implementing the population bootstrap now.
- Building the new application, adopting the old app stack/endpoints or authentication UI.
- Implementing HSDS/SQLite file generators or full HSDS API protocol conformance now.
- Choosing the detailed local taxonomy vocabulary in this task.
- Managing confidential facilities in the MVP.
- Organization self-service, accredited urgent warnings and automatic trusted publication.
- Transport proximity calculations, walking navigation, live capacities, complex
  recurrence and delta synchronization.
- External issue publication, push/PR/merge/deploy or dependency installation without
  the later scope/authorization required by project instructions.

## Further Notes

Observed basis: the database repository contains documents only, with no configured
runtime/test commands. GitHub is selected as tracker; its repository is not yet created. The original application and source collection
remain read-only references. The approved authority boundary is recorded in
[ADR 0001](../adr/0001-canonical-database-and-offline-distribution.md).

The interview is closed for this synthesis. The user explicitly requested both
specification and implementation planning, so the accompanying action plan may
begin; approval of its approach does not itself authorize code, tests, installations
or database connections. The plan can flag a material technical gap without
silently changing the accepted product scope.

GitHub is the selected tracker; its repository still needs creation. Use the existing
local documentation representation during specification/planning. Repository creation
and issue publication are later explicitly scoped actions.
No issue IDs, tracker labels or remote delivery are implied. The approach and P1/P2 are confirmed; actual issue publication/implementation
remain subsequent separately scoped phases. See the approved plan r0.2.

## Execution clarifications, 2026-10-05

The user authorized grouped stepwise implementation through #1–#4 and explicitly
invoked execute-reviewed-task. Self-approval is allowed only with both propose and
approve capabilities for all involved territories. Temporarily closed services
remain discoverable with their explicit state; defunct services retain direct access
and leave ordinary discovery. These resolve the existing technical policy choices
without changing the approved product scope. The action plan records actual
implementation/evidence; proposal-stage statements above are not current execution
status. Further groups require checkpoint continuation.
