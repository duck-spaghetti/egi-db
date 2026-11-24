# EGI canonical database — working design v0.1

Date: 2026-10-05. Status: **domain interview consolidated; concrete schema proposal
ready for discussion and technical review, not approved for implementation**. This is the maintained design document. It contains no executable
schema, Sqitch project or data-loading implementation. Final table boundaries,
constraints and delivery tasks depend on the interview.

The consolidated [schema proposal](schema-proposal.md) is now the primary artifact
for tables, columns, cardinalities, revision/restoration and projection contracts.
This document retains research findings and the interview decision ledger. Historical
open questions below are superseded where the final closure round resolves them.

## 1. Requirements already selected

| ID | User requirement |
| --- | --- |
| R1 | One authoritative PostgreSQL database with PostGIS; `psql` as client. |
| R2 | Sqitch manages structure/deployment. A separate bootstrap loads data later. |
| R3 | Use HSDS/Open Referral as a compatibility/reference model, with explicit adaptations and omissions. |
| R4 | Separate English schema namespaces for canonical data, governance, sources and related responsibilities. |
| R5 | Rome and surroundings initially; multiple geographic areas without a destructive redesign. |
| R6 | Preserve original assertions from every source, including conflicting descriptions of organizations, services, locations, contacts, addresses, hours and access conditions. |
| R7 | Preserve source registry, stable source-side identity when supplied, canonical mappings, lineage and reprocessing history. |
| R8 | Support normalization, candidate matching, entity resolution and evolving merge decisions without embedding one matching algorithm into canonical tables. |
| R9 | Raw/normalized addresses, scalar coordinates, spatial representations, geocoding provenance/provider/confidence/status and cached results. Geocoding can follow resolution. |
| R10 | Future hierarchical multi-axis taxonomy, including need, service type and population/access; its detailed vocabulary is separate work. |
| R11 | SQLite is a feasible read-only/offline/export representation of the canonical dataset; portable core relationships and explicit PostgreSQL/PostGIS boundaries. |
| R12 | Incremental implementation, explicit assumptions, compact textual ERD, proposed constraints/indexes, rejected alternatives and implementation phases. |
| R13 | Planning only. No schema/code implementation or database changes in this session. |
| R14 | Hybrid canonical selection: explicit automation policies, retained assertions and reviewable ambiguous conflicts/merges. Confirmed in round 1. |
| R15 | Current catalog covers non-confidential facilities. Confidential facility acquisition/management is outside the MVP; preserve existing evidence. Confirmed in round 1. |
| R16 | Distinct service/activity/contact schedules; unknown remains unknown. Stored hours support simple table rendering, open-now queries and closing countdowns. Confirmed in round 2. |
| R17 | Map/editorial territories are distinct from service coverage and geographic eligibility; overlapping map membership preserves canonical identity. Confirmed in round 2. |
| R18 | Canonical operating intervals are stored in a relational table. Exact weekday encoding and physical columns remain to be designed. |
| R19 | One shared exception calendar initially; support advisories and confirmed variations. Default to possible variation with an invitation to contact the facility when reliable hours are unavailable. Organization-managed pages/calendars are a future expansion. |
| R20 | Access conditions remain separate from calendar operating hours. |
| R21 | The service page has a contact section showing available contacts with their channel (phone/email/etc.) and scope/purpose (organization/appointments/etc.). |
| R22 | Verification can target individual information components or an entire service page. Verification time is distinct from import and modification times; checking one component does not verify unrelated information. |
| R23 | Aging information remains publicly visible with a needs-reconfirmation warning. Elapsed time alone does not trigger hiding; review thresholds remain to be selected. |
| R24 | Initial publication of an imported or proposed service requires editorial approval. Any future automatic publication requires explicitly selected policies. |
| R25 | Proposed updates to published information require approval; the last approved information remains public while changes await review. |
| R26 | Urgent unconfirmed warning publication is outside the current MVP. Future support involving accredited users remains open; no accreditation or privileged publication policy is selected. |
| R27 | Services may be published without coordinates or known hours, subject to validation of essential fields. Telephone/remote delivery is valid without geographic coordinates. |
| R28 | Minimum publication information: name, meaningful description, delivery mode, source evidence and editorial approval; usable channel for telephone/online delivery; identifiable location/access directions for in-person delivery. Known hours and responsible organization are not universal publication requirements. |
| R29 | Preserve incomplete/unready records in a draft workspace; expose adequately populated and approved records in a public/published workspace. Failure of publication validation does not delete records. Use stable entity identity and pending/approved revisions rather than moving entity identities between draft and public tables. |
| R30 | Retain revision history and traceable restoration for services, locations and organizations, including related hours, contacts, access conditions and relationships. Restoration creates a new revision, requires validation/approval before publication and does not automatically restore shared entities. |
| R31 | A service can involve multiple organizations with explicit roles. Management/operational delivery roles are distinct from funding/support roles; the organization may remain unknown. |
| R32 | Dynamic translations live in `i18n`, may cover only some fields, retain the original, and are classified as human, AI or AI-verified (`ia_verified` user term). Prefer the user's language and fall back to original information when unavailable. UI translation catalogs belong to the app. Writing direction follows language metadata; mixed-language fields do not change the established UI direction. Exact classification identifiers remain open. |
| R33 | Provide a dedicated schema for periodically computed and stored geospatial enrichments, such as location proximity to public transport. Use PostGIS and retained/versioned external sources; public reads consume stored results rather than recomputing distances for each request. This entire capability is a future development note, outside the current MVP. Initial future proximity uses direct distance; walking routing/navigation is a later expansion. |
| R34 | AI translations may be published after editorial approval while retaining classification `ai`; editorial publication approval is distinct from linguistic verification and does not imply `ai_verified`. |
| R35 | A changed published original makes dependent older translations unavailable in the current public response, with per-field fallback to the new original and retained history. Create a visible translation-update work signal for each affected field/language; unchanged translations remain usable. |
| R36 | Permanently closed services remain in history and accessible by direct public link clearly labelled closed, but are excluded from ordinary discovery. Temporary closure has a distinct operational status. |
| R37 | Itinerant delivery places remain visible regardless of the current operating day; each place clearly shows its own applicable days and hours. The initial day-based hiding proposal was explicitly superseded by the user. Q2 selects distinct services per delivery place/area. |
| R38 | When only an itinerant service area/neighborhood is known, display that area with an explicit exact-location-unavailable indication; do not invent a point marker. Actual known stops may use point locations. |
| R39 | Distinct services per delivery place/area, with independent identity, page, schedule and revision history. Similar offers at different places are linked through their organizations and classification, not one shared multi-location service identity. |
| R40 | One location/facility can host multiple services across categories and from different organizations. Hosting a service does not imply that the facility's operator provides it. |
| R41 | A genuine permanent relocation of the same service preserves its ID and revision history, recording the change of place. Simultaneous offers at distinct places retain distinct service identities. |
| R42 | Within each taxonomy axis, a term may have several broader parents; prevent cycles. Hierarchy expresses an is-a relationship, distinct from cross-axis mappings or generic associations. Initial vocabularies may use simple trees; detailed vocabulary remains separate work. |
| R43 | Filtering by a broader category includes services assigned to it or any descendant within the same axis. Each service is returned once despite multiple hierarchy paths. |
| R44 | Combine selections by OR within one taxonomy axis and AND across distinct selected axes. |
| R45 | Taxonomy is adopted per map territory/region. Different territories may use different vocabularies and hierarchies; no single Rome taxonomy is imposed on future maps. Classifications and filters must retain territory/taxonomy context. |
| R46 | Territories may explicitly reuse a shared taxonomy or create an independent local vocabulary, including a copy derived from an existing taxonomy. Local independent edits must not silently modify other maps. |
| R47 | All supported UI languages remain available across territories; dynamic service-content translation priorities/target languages may differ by territory. Do not derive UI language availability from local translation coverage or require complete translations to publish service content. |
| R48 | MVP access data supports structured appointment, referral, required documents and access requirements with original notes; cost distinguishes free, paid, variable and unknown. Missing information does not imply free/unrestricted access. |
| R49 | MVP supports proposing and editorial approval/publication capabilities, with attributable decisions and territorial authorization scope. Public source attribution includes source name/link and relevant retrieval/verification dates; raw payloads, conflicts and internal notes remain workspace data. |
| R50 | Offline SQLite snapshots are territory-scoped and include current approved public data, available translations and closed-service direct-access records, excluding closed services from default discovery. Exclude drafts/full editorial history; identify snapshot version/date. Refresh cadence/deltas remain future decisions. |
| R51 | HSDS export supports explicit required-field defaults and excludes records still invalid after mapping/defaults. Retain invalid records and validation diagnostics; output exclusion does not delete source/draft/history. |

The supplied architecture brief and the user's chat establish R1–R51. Database
versions, exact HSDS profile/completeness policy, deployment topology, tracker and
implementation execution mode remain open. The application stack is a separate decision.

## 2. Current repository and data findings

Detailed paths and observed contracts are in [API/data inventory](api-and-data-inventory.md).
The reference app is `origin/wip` at
`c090950874a8c5ac39c83f9ba2aa1ae06356af84`; its `main` checkout remains untouched.
The current database repository has no deployed schema, migration configuration,
data import or test suite.

The old SQL proposes 18 tables across `core`, `taxonomy`, `poi`, `gov`, `audit` and
`i18n`. The later ORM separates location/service contact tables and adds service
subcategory links, so it cannot simply consume that SQL unchanged. Both drafts
tie a service to one `place_id`; organization ownership is primarily attached to
the place. Categories/subcategories/tags encode one particular taxonomy shape.

The public API enriches services with location, labels, contacts, hours and sources.
Its publication filter includes `pending`; its protected-address logic hides address
strings while other data can still disclose position. Neither behavior is adopted
as the new public contract. The importer service is empty. Translation infrastructure
primarily covers taxonomy/UI rather than actual multilingual canonical content.

Representative source data includes itinerant services, incompletely specified
hours, multiple contact channels, eligibility/access notes and records beyond Rome.
Source evidence can distinguish phone availability, office hours and service hours.
Interpretation must preserve those distinctions and uncertainty.

## 3. HSDS reference and compatibility boundary

Research uses the pinned **HSDS v3.3.1** reference, listed by Open Referral as its
latest release at inspection time. Pinning this version for EGI is recommended,
and the user confirmed an eventually validatable HSDS export with mapping designed
now and exporter implementation later. EGI may keep its own API contract. Full
HSDS API conformance is not selected; final version pin and incomplete-data policy
remain specification details.
[Official release](https://github.com/openreferral/specification/releases/tag/v3.3.1).

HSDS is an interchange model that can coexist with a different storage model.
Its core concepts distinguish organizations, services, locations and
`service_at_location`, allowing one service to operate at multiple physical or
virtual locations. EGI can adopt those boundaries while maintaining its own
provenance and governance internals.
[HSDS overview](https://docs.openreferral.org/en/v3.3.1/hsds/overview.html).

| Treatment proposed | Concept | EGI mapping / consequence |
| --- | --- | --- |
| Adopt concept | Organization | Provider identity independent of one location or territory. |
| Adopt concept | Service | Logical offering, with responsibility and availability separate from editorial publication. |
| Adopt concept | Location | Delivery context; fixed physical, virtual or mobile handling must be chosen explicitly. |
| Adopt concept | Service at location | Explicit service/location relationship with its own identity and local information. |
| Adapt storage | Addresses, phone/contact/URL information | Structured address and channel records; named contact people/roles remain a distinct concept if needed. Serialization maps channels to their appropriate HSDS objects. |
| Adapt storage | Schedules, access, languages, fees | Retain source wording and normalized values. Define operating-hour scope, recurring rules and local overrides before committing table detail. |
| Adapt storage | Taxonomy and attributes | Generic vocabularies/terms/relationships/assignments support multiple axes; old categories become a presentation projection. |
| EGI extension | Provenance and resolution | Versioned raw records, normalized subjects/assertions, reversible resolution and explicit field selections. |
| EGI extension | Geography and distribution | Editorial/map territories, geocoding history and an offline public projection. |
| Candidate MVP deferral | Programs, funding, accreditation, live capacities, notifications, voting, transit graphs | Preserve relevant source evidence without implementing every HSDS object. Required launch concepts depend on later interview answers. |

For a conforming export, required fields and identifiers must be checked against
the selected JSON schemas; incomplete ingested information must not be filled
with invented facts. Organization, service and taxonomy requirements differ.
[HSDS schema reference](https://docs.openreferral.org/en/v3.3.1/hsds/schema_reference.html).

HSDS service availability values are distinct from EGI's draft editorial states.
Version 3.3 deprecates the service object's `schedules` field in favor of separate
`operating_hours` and `events`; an exporter must respect the selected version rather
than blindly renaming EGI's weekly slots.
[Pinned service schema](https://raw.githubusercontent.com/openreferral/specification/v3.3.1/schema/service.json).

Data serialization compatibility and HSDS API protocol conformance are separate
deliverables. The current app's routes, integer identifiers and response lists do
not establish protocol conformance. A mapping/export contract can be developed
independently of the internal DB layout.
[HSDS API reference](https://docs.openreferral.org/en/v3.3.1/hsds/api_reference.html).

## 4. Proposed domain boundaries and cardinalities

**Selected under Q2:** a service represents a distinct offer at a delivery place or
area. Similar services at Castrense and Tuscolano have independent identities/pages,
schedules and history, connected through organization associations and classification.
An optional future shared program grouping does not merge their service identities.
Telephone/online services remain valid without a physical-location association.
Itinerant offers at distinct places/areas follow the same place-specific identity.
Q28 selects identity continuity for genuine permanent relocation; mixed physical/remote
delivery and detailed continuity criteria remain open.

**Selected location cardinality:** one facility/location can host several services
across unrelated categories and from different organizations. The user's illustrative
hospital-plus-association example is a model requirement, not a verified claim about
a specific hospital. Link service responsibility directly to role-bearing organization
associations; do not derive it solely from the host facility. Exact facility/building,
room/entrance hierarchy and host/operator relationship tables remain proposals.

Propose an explicit service/place association or equivalent typed FK, with at most
one current delivery-place context per place-specific service. Ingestion drafts may
lack a resolved location; non-geographic modes do not require a fictitious location.
Keep temporal history and area-valued contexts possible. Exact columns, association
constraints are not approved DDL; Q28 selects relocation identity continuity. Orgs, contacts and programs
can be shared without coupling service publication or revision histories.

**P3 — proposal:** independent territories and catchment/access areas. A map/editorial
territory selects information for discovery and distribution. A service's eligibility
or catchment region describes whom it serves. They need not match the physical
location; regions can overlap. Organizations and services retain global identities
when included in more than one territory.

**P4 — integrity option requiring review:** a small `data.entities` registry supplies
stable identities for provenance targets. Typed domain tables reference that identity
and enforce entity kind using composite foreign keys/discriminators. This permits
foreign keys from source/decision evidence without unchecked `(table_name, id)` pairs.
The registry is not a generic EAV store: public names, relationships, coordinates,
costs and schedules remain typed domain data. The alternative is explicit typed
link tables for every provenance target; select the approach during the interview.

Prefer stable UUID canonical identities, preserved as text in SQLite. Exact UUID
generation/version and any legacy integer-ID adapter remain proposals. Names,
addresses and telephone numbers are matching evidence, not globally unique keys.
Existing frontend `Number(id)` assumptions will require an explicit adaptation if
UUIDs are selected. HSDS export IDs must remain stable even after reprocessing.

```text
organization * ── * service (role-bearing associations)
location/area 1 ── * place-specific service (physical/area delivery)
remote service ── usable access channel; no mandatory physical location
location     1 ── * address
territory    * ── * location / service (membership and catchment are distinct)

source 1 ── * source_record 1 ── * record_version
record_version 1 ── * normalized_record 1 ── * assertion
normalized_record * ── * canonical_entity (resolution decisions over time)
canonical_attribute ── selection decision ── * supporting assertions

taxonomy 1 ── * term; term * ── * broader term
canonical_entity * ── * term (scoped assignments)

canonical PostgreSQL data ── public projection ── HSDS / application / SQLite
```

The registry, relationship scopes and editorial territory assignments are pending
physical-design decisions, not implemented tables.

### Operating-hours representation — proposal after Q5

Accepted capabilities: distinguish service, intake/office and contact schedules;
retain unknown information honestly; render a simple weekly table; query open-now
and calculate the next closing transition. Q2 selects place-specific service identity; exact delivery-place/area
foreign keys remain physical design work.

Propose normalized schedule rules alongside retained source text. A free-text
hours field alone cannot supply reliable structured queries. Preserve imported
recurrence expressions as evidence and map supported cases explicitly; unrestricted
recurrence support is not silently assumed.

| Candidate component | Proposed information | Purpose |
| --- | --- | --- |
| `data.schedules` | Subject/scope, timezone name, effective dates, interpretation/completeness state, evidence and original description | Distinguish the activity/channel and calendar context. |
| `data.schedule_rules` | ISO weekday or a weekday bitmask (open choice), local start/end time, explicit end-day offset, multiple intervals per day; known-closed/unknown coverage where needed | Simple table rendering, split shifts, overnight openings and 24-hour operation. |
| `data.schedule_exceptions` and dated intervals | Date/range, closure or replacement hours, reason/evidence | One shared exception calendar in the MVP; support advisory and confirmed variation events. Applicability and precedence remain open. |
| Optional derived occurrences | Opening/closing instants, scope, effective rule/exception references, evaluator version | Future query acceleration/export; not a second schedule authority. |

Exact tables and constraints are proposals. The accepted requirement is behavior;
exception storage and a materialized query horizon are not approved physical choices.

Propose local opening times plus an explicit IANA timezone such as `Europe/Rome`,
then resolve dated occurrences to instants. PostgreSQL timestamps with time zone
retain an instant, not the original named zone; record the recurring schedule's
zone separately. A fixed UTC offset alone does not encode seasonal clock changes.
[PostgreSQL date/time documentation](https://www.postgresql.org/docs/current/datatype-datetime.html).

Proposed evaluation contract:

1. Select the subject/scope and schedule valid at the requested instant. Operational
   availability, editorial publication, schedule completeness and access remain distinct.
2. Apply selected exception/timezone semantics. Overnight spillover across dates,
   daylight-saving gaps/overlaps and overlapping rules require deterministic handling.
3. Derive effective half-open intervals `[opens_at, closes_at)`; merge adjoining or
   overlapping intervals only within the same applicable subject/condition.
4. Return `open`, `closed` or `unknown`, with evaluated scope/timezone/instant and
   evidence/completeness. Missing or ambiguous data must not produce false precision.
5. When open, return the end of the continuous effective opening as `closes_at`;
   derive the countdown from that instant. Continuous 24/7 opening may have no known
   closing transition; a known future exception can change that result.
6. When closed and information is sufficient, return the next opening instant.
   An exhausted search horizon differs from permanent closure or an unknown calendar.

Render the weekly table from the same selected rules, labelling known closure,
missing information and applicability. A current-week view may include exceptions;
a regular-week view shows the baseline. Define PostgreSQL queries and future SQLite
evaluation against the same semantics; exporting a stale `is_open_now` flag is
insufficient. Q8 confirms that access conditions remain separate from calendar opening status.
Conditional schedules and their applicable audience still require explicit semantics.

### Relational intervals selected; weekday encoding remains open

The user considered a JSON object keyed by weekday bitmasks, then selected a
relational table for canonical operating intervals on 2026-10-05. The alternatives
below retain the rationale for the discussion, not an open choice of JSON authority.
Weekday encoding remains a physical-design detail: a relational rule can carry one
weekday or a weekday mask. No API JSON shape has been selected.

Illustrative convention only: Monday=1, Tuesday=2, Wednesday=4, Thursday=8,
Friday=16, Saturday=32, Sunday=64; 31 means Monday–Friday and 127 means every day.
An interval starting on Friday and ending Saturday uses Friday's mask plus an
explicit end-day offset. Equal opening/closing times alone cannot distinguish a
zero-length interval from 24 hours. Unknown weekday coverage must not be inferred
as closure merely because no key/row exists.

PostgreSQL can expand JSON objects/arrays and apply integer bitwise operations to
cast mask keys. Thus this representation can support open-now queries and closing
calculations. It still needs timezone/date resolution, overnight spillover,
completeness, overlap handling and exception semantics.
[JSON functions](https://www.postgresql.org/docs/current/functions-json.html),
[integer operators](https://www.postgresql.org/docs/current/functions-math.html).

| Alternative | Benefits | Costs / constraints |
| --- | --- | --- |
| JSONB object keyed by weekday mask | Compact grouped weekly representation; convenient payload for consumers. | Keys are strings; every query must interpret them and expand intervals. Per-interval evidence, stable rule identity and constraints need an explicit document contract. Each mask has one key with an array of intervals. |
| Relational interval rules, with weekday or mask | Typed times, explicit ownership/evidence links and individual rule updates; ordinary relational validation. | More rows/columns; grouping for display or export is a projection. A weekday mask still needs agreed validation. |
| Relational authority plus derived JSON payload | One authoritative representation with a compact application/offline read shape. | Requires a documented projection and shared evaluation semantics; JSON must not become an independently editable authority. |

Selected: relational interval rules for canonical hours. Weekday versus mask
encoding remains open; a grouped JSON application projection is optional and proposed.
The rationale is per-value provenance and future organization calendars; no measured
performance advantage is claimed. JSONB supports indexes,
but a generic GIN index does not automatically optimize an arbitrary expanded
bitmask-and-time predicate. Query plans and scale must be assessed during authorized
implementation; no benchmarks were run.
[JSONB indexing](https://www.postgresql.org/docs/current/datatype-json.html#JSON-INDEXING).

For any future JSON read projection, consistently structured interval arrays and
named rule fields remain possible API design choices. Canonical JSON storage is not
selected. Exact columns, constraints and public payloads are still proposed.

### Shared exception calendar and later organization calendars

Q7 selects one shared exception calendar initially. Organization-managed pages and
custom calendars are an intended later expansion; roles, permissions and publishing
workflows are not yet selected. The user confirmed support for both advisory events
and confirmed variations on 2026-10-05. The default is an advisory: hours may vary,
invite the user to contact the facility because reliable exceptional hours are absent.
Confirmed variations can state an explicit closure or replacement hours with evidence;
a possible variation is not a confirmed closure or opening.

Propose explicit calendar identity, dated events and scoped schedule/calendar bindings
so an initial shared calendar can later coexist with organization calendars. Exact
tables are pending. Avoid hard-coding Rome or a permanent singleton into the model;
calendar applicability can later distinguish territories and subject scopes. Inheritance,
local overrides, conflict precedence and organization editing authority remain open.
Do not infer that all services close on a holiday or promise an exact closing time
when only a possible variation is known. Proposed evaluation contract: retain regular
hours as the baseline, expose an advisory and its reason/contact action separately,
and distinguish baseline-based opening from confirmed exceptional opening. A countdown
based on uncertain hours must not appear as a confirmed closing time. Exact response
fields, display wording and open-now filter inclusion remain to be agreed.

## 5. Proposed schema namespaces and table responsibilities

Namespace names below are proposals. Introduce them only as a corresponding slice
is implemented. The table families are a design inventory, not an instruction to
create every table in the first release.

| Namespace | Candidate tables/families | Responsibility / proposed minimum information |
| --- | --- | --- |
| `data` | `entities` (option P4) | Stable canonical identity, kind, revision and lifecycle/alias metadata. Typed payload stays in domain tables. |
| `data` | `organizations`, `services` | Public/provider names, descriptions and responsibility; service availability, publication state and cost/access summaries. Source identity stays elsewhere. |
| `data` | `locations`, `service_locations` | Delivery context and relationship-specific data. Canonical latitude/longitude may both be unknown. Q2 selects distinct services per place; one location hosts many services. Exact mobile/area relationships remain to be designed. |
| `data` | `addresses`, `contact_channels` | Address components plus normalized presentation; public phone/email/web/WhatsApp channels and their scope. Source spellings and variants remain assertions. Named-person contacts are not conflated with channels. |
| `data` | `schedules`, `schedule_rules`, candidate `schedule_exceptions`, `access_conditions` | Scoped schedule/access records with meaning retained, validity and interpretation state. Normalized rules support table/open-now/countdown requirements; exception scope, eligibility/documents and appointment behavior await later decisions. |
| `sources` | `sources`, `processing_runs` | Provider/source registry, attribution/license and retrieval policy; execution kind, parent run, input snapshot, parser/normalizer version, timestamps and result. Secrets belong outside provenance payloads. |
| `sources` | `source_records`, `record_versions` | Stable upstream key when present; retained raw payload or immutable artifact locator/hash and exact row/page/feature locator; retrieval and source-observed timestamps. Retrieval occurrences are recorded even when content is unchanged. |
| `sources` | `normalized_records`, `assertions` | One source row can yield several typed subjects. Per-run normalized subjects and field/relationship assertions retain raw values, interpreted values, language, scope, temporal validity, uncertainty and interpretation method. |
| `governance` | `resolution_decisions`, `value_decisions`, decision/evidence links | Match/unmatch/merge/split history, canonical value/collection selection and supporting assertions. Algorithmic suggestions and accepted decisions remain distinct. Exact current-binding representation awaits review. |
| `governance` | `submissions`, actor references (as needed) | Reviewable human/import proposals and accountable actors. Auth storage, roles, permissions and moderation state machine are separate interview choices. |
| `audit` | `entity_changes` | Durable canonical revision history, actor, causal decision/run, time and change/snapshot. This complements source evidence rather than replacing it. |
| `taxonomy` | `vocabularies`, `terms`, `term_relations`, `assignments` | Territory adoption, axes/versions and stable terms, broader/narrower relationships and context-scoped classified subjects; code/URI, scope, validity and provenance. Detailed term inventory is separate work. |
| `geo` | `territories`, membership/coverage links, `geocoding_results` | Map/editorial areas, service coverage and chosen spatial boundaries; reproducible provider results/cache entries including uncertain/failed results. Spatial indexes/materializations remain derived capabilities. |
| `i18n` | language registry and scoped translations | Partial dynamic field translations and term labels, with original revisions, origin/review and source lineage. UI translation catalogs live in the app; languages spoken by a service are distinct. |
| Proposed `derived` | `computation_runs`, `location_transit_proximity` and future typed enrichment results | Periodically computed, reproducible location enrichment with input revisions, algorithm/configuration version, computed time and freshness state. Namespace name and physical tables remain proposals. |
| Optional later `api` | public views/projections, export manifests | Explicit public read contract shared by application, HSDS and offline output. Views are not a second canonical authority. Namespace/table shape depends on the export contract. |

Keep common exact-contract columns relational. Versioned raw/normalized payloads
and extension metadata may use PostgreSQL JSONB. A JSONB document is useful for
evidence and optional extensions; it should not hide relationships the application
must filter, validate or traverse. The first physical table set will be chosen
after the interview rather than copying the HSDS object list.

## 6. Canonical data, source assertions and value selection

Proposed flow:

```text
retained source record version
  → versioned normalized subjects and assertions
  → candidate matches (algorithm/version/score/explanation)
  → accepted/rejected resolution decisions
  → canonical value or collection selections with evidence
  → typed canonical records and public projections
```

One raw source record can describe an organization, a location, several services
and contacts. Normalized subject identity is scoped to the record version and
processing run; an array index alone is not a durable upstream identity. Different
source subjects may link to the same canonical entity. One assertion may support
an attribute without making its entire source record authoritative.

**Example:** source A says a service runs 12:00–14:00; B says 12:30–15:00. Both
claims and their dates remain retained. An editor or an approved policy selects one
schedule, a combined interpretation, or an unresolved state. The selection cites
the supporting assertions and reason; the conflicting assertion is still available.
Combining two schedules by union is a decision, not a safe default.

Selection must support scalar fields, related row collections and negative claims
(for example, a provider explicitly saying a location closed). Distinguish absent,
unknown, explicitly empty and no-longer-valid values. A canonical correction can
itself be a manual-source assertion with accountable origin.

Accepted under Q10: verification may target individual information components or
an entire service page. Propose a verification record with explicit scope, checked
revision/value set, actor, method, supporting evidence and verification time. Import
and edit timestamps do not imply verification. A whole-page review must identify
what information/revision it covered; later changes cannot inherit verification
silently. Exact storage, actor authority and invalidation rules remain proposals. Under Q11,
aging information remains visible with a needs-reconfirmation warning. Freshness
is distinct from verified correctness, availability and publication state. Future
review thresholds can be scoped by information type; no threshold is selected yet.
Elapsed time alone must not establish closure or invalidate source evidence.

Proposed replay semantics: keep stable source-record identity; retain immutable
content versions and retrieval observations; run a new normalization with its own
version/evidence. Reprocessing proposes new values and mappings; it does not silently
overwrite editorial decisions. Upstream deletion or a source's temporary disappearance
does not automatically delete the real-world service.

Merge/split/unlink actions retain decision history and prior memberships. Preserve
old identifiers as redirects/tombstones where appropriate, define reference repair
and split behavior, and invalidate stale projections explicitly. A name or proximity
score alone never supplies a hard-coded merge rule. Model support is required;
the actual matching engine and thresholds are separate future work.

## 7. Geospatial and geocoding design

Store source coordinates/address claims in their original evidence context. Proposed
canonical locations contain scalar WGS84 latitude/longitude plus interpretation
status and references to the chosen evidence. Both coordinates can remain unknown,
so normalization/resolution and non-map presentation can precede geocoding.

PostGIS point representations are derived from the chosen coordinate pair in the
same transaction or explicitly verified materialization. Avoid two independently
editable spatial truths. Latitude/longitude order must be specified at every boundary;
GeoJSON uses longitude then latitude. Use `geometry(Point,4326)` for interchange and
spatial relationships; metric distance can use `geography` or an agreed projected
CRS. `ST_DWithin` distance units differ between geometry and geography.
[PostGIS documentation](https://postgis.net/docs/ST_DWithin.html).

A geocoding result records provider, request/input identity, provider/configuration
version where available, input address and context, returned address/coordinates,
precision/status, provider-native score, retrieval time and payload/evidence locator.
Keep native confidence semantics; scores from different providers are not automatically
comparable. Selecting a result creates a canonical decision instead of destroying
other candidates or source coordinates.

Proposed cache identity includes provider, normalized request, country/area/language
context and relevant method/version. Negative results need an explicit retry/expiry
policy; changed inputs can trigger a new request. Cache reuse and result redistribution
must follow the provider/source's terms. Provider selection and licensing decisions
remain open.

For mobile services, delivery stops/routes/sessions must be modeled explicitly when
required; inventing a fixed centroid is not equivalent. If confidential-location management is later introduced, its exact coordinates
and indirect revealing fields will need an approved public-projection policy. Public approximation, omission and contact-only presentation
are deferred alternatives outside the current MVP: Q4 excludes intentional
acquisition/management of confidential facilities. The public catalog currently
contains non-confidential facilities. Treatment of unexpected confidential evidence
in a future input feed must be settled before ingestion; existing source evidence
is not deleted by this scope decision.

### Future development note: persisted spatial enrichments

The user requests a future dedicated schema for derived computations, initially
proximity to Rome public transport. Subsequent clarification explicitly defers the
entire transport enrichment feature beyond the MVP. This section is a roadmap note,
not current implementation scope or a prerequisite for core database design review. Propose `derived` as an extensible English namespace; the
name and tables are not yet selected. External transport datasets are registered and
versioned through `sources`; their interpreted stops/stations and geometry can live
in `geo` or a future transport domain. Q22 identifies Roma Capitale public data in the earlier EGI source collection.
Inspection found `Roma Capitale/Fonti Roma Capitale.md` and
`Roma Capitale/data_output/roma_capitale_trasporto.csv` under
`/Users/marco-macbook/dev/egi/sources/egi-sources-roma`. The new
`project_egi/egi_sources` did not contain matching transport files.

The CSV has nine records describing three metro lines and six tram lines, with fields
`layer_type`, `line_or_category`, `name`, `address`, `lat`, `lon`, `source_url`,
`last_update`. It contains no individual stop/station IDs or entrance hierarchy.
All three metro line rows share the coordinate pair 41.9028/12.4964; these are not
individual station coordinates. Its update field reads 2026-01-19; this is a local
record value, not independently verified dataset freshness. The CSV cannot supply
reliable nearest-station distances. Retain it as evidence/catalog context rather
than treating its line points as stations.

Each row links to the same Roma Capitale catalog dataset:
https://dati.comune.roma.it/catalog/dataset/a7dadb4a-66ae-4eff-8ded-a102064702ba .
Opening that URL through the web tool failed on 2026-10-05; the dataset identity,
resources, license and current availability are not verified. The local `files.zip`
filename inventory had no transport/metro/GTFS/stops matches; no archive extraction
or source edits were performed. Actual point-level stop/station data, stable IDs,
licensing and dataset update semantics still need inspection. Do not assume the
local CSV is a GTFS feed or that its linked dataset has a particular format.

Compute per location/delivery point, then join the stored result into service details.
Services sharing a location can reuse the same result; telephone/online services
without a physical point do not receive fabricated proximity. Q2 selects distinct services per place/area.
Proposed typed results include location and target stop/station IDs, distance in meters,
measurement method, rank/category where useful, computation run/time, location geometry
revision, transport dataset version and algorithm/configuration version. Store structured
facts; generate and translate display sentences in the consumer rather than storing
only an Italian sentence.

Use periodic batch processing as requested. Additionally propose marking dependent
results stale when approved coordinates, target geometry/dataset version or computation
configuration changes. Atomic activation of a complete successful run prevents partially
refreshed public output; failure retains the previous result with explicit freshness.
Exact cadence, invalidation, retention and stale-publication policies remain open.
Restoring an older location revision must also re-evaluate result applicability.

Direct geodesic point distance and walking-route distance are different metrics.
`ST_Distance` with geography measures geodesic meters; `ST_DWithin` can limit candidates
within a meter radius. A walking result additionally needs a suitable route network
and routing method, not just two coordinates. Dataset station centers versus entrances
also affect the meaning of the result. Q21 selects direct geographic distance for the initial future enrichment. Pedestrian
routing and navigation are a further future expansion; a suitable free or inexpensive real-time provider
will be evaluated later. No routing provider/dependency is selected. Stop/station
reference-point semantics and target selection radius/count remain open.
[PostGIS distance](https://postgis.net/docs/ST_Distance.html),
[proximity](https://postgis.net/docs/ST_DWithin.html).

Optional future SQLite export can carry selected structured enrichment results and
input/freshness metadata, without rerunning PostGIS offline. Detailed enrichments are
a separately scoped implementation slice, not jobs or SQL authorized by this design.

### Itinerant place visibility — Q26 corrected decision

Show all known itinerant delivery places in default discovery even on non-operating
days. Each place has its own clearly displayed operating days/hours. In the user's
example A operates on X, B on Y, C on Z: all three remain visible, but each displays
only its applicable schedule. Do not combine all days into an apparently applicable
schedule for each place. Current opening state is a separate evaluated property or
explicit filter, not a condition for default visibility. The user's initial day-based
hiding instruction was superseded and must not be implemented.

Propose linking dated/recurring stop or delivery-context schedules to their actual
location/territory scope, preserving original schedule evidence and uncertainty.
Q2 subsequently selects distinct site/area-specific services, linked through their
organizations and taxonomy rather than one multi-location service identity. Q27 selects area/neighborhood presentation with an explicit exact-location-unavailable
indication when the precise stop is unknown. Do not convert the area's centroid into
an asserted stop coordinate; if no verified boundary is available, retain the area
reference/description and uncertainty rather than fabricate a polygon. Exact boundary
sources and UI geometry rendering remain design work.

## 8. Taxonomy, access and multilingual integration

Taxonomy adoption belongs to a map territory/region. Rome and Florence may use
different vocabularies and hierarchies. Do not encode a universal Rome taxonomy in
DDL or impose its categories on new territories. In this requirement, region denotes
a map/editorial territory, not necessarily an administrative Italian region; exact
binding/cardinality and whether axis definitions are shared remain to be clarified.

Axes such as `need`, `service_type` and `population_access` are data, not PostgreSQL
enums or category-specific columns. Terms have stable identity and code/URI; broader relations express hierarchy.
Q29 selects multiple broader parents within an axis, with cycle prevention (a DAG).
Hierarchy means is-a, not a generic related-to link. Cross-axis mappings and other
associations remain distinct relations. A term is stored once even when reachable
through several parents. Initial vocabularies can remain simple trees; this capability
does not require every term to have multiple parents. Propose explicit relation rows
and constraints; exact table shape and enforcement remain physical design work.

Classifications can apply at service, delivery context or other agreed subject scopes.
Preserve external taxonomy versions/mappings and evidence for inferred classifications.
Colors, icons and display ordering belong to presentation metadata/projections.
Taxonomy edits evolve independently of DDL, with validation and editorial history. Q30
selects descendant-inclusive filtering within the selected axis, deduplicating services
across all hierarchy paths. Return directly assigned classifications as evidence;
query expansion does not create extra canonical assignments or infer access eligibility. Q31 selects OR
within an axis and AND between selected axes. Evaluate hierarchy expansion and filter
combination against the active territory's taxonomy context, not every vocabulary.
Missing classification is not a claim of exclusion or a structured access requirement.
Exact recursive-query/materialized hierarchy strategy remains implementation design.

Propose territory/taxonomy adoption records linking each map territory to its chosen
vocabulary/version and axis configuration. Classification assignments retain the
subject, taxonomy term, adoption/territory context and evidence. A service shared by
overlapping map territories can be classified differently for each map without changing
its canonical identity. If vocabularies are reused, share their identity explicitly;
if local vocabularies differ, keep distinct term identity even when labels match.
Cross-vocabulary mappings can support future interoperability but must be explicit,
versioned and evidence-backed; do not infer equivalence from names or merge local terms.
Q32 selects both explicit reuse of a shared taxonomy and independent local copies.
A shared vocabulary has one versioned identity with intentional shared governance;
an independent copy has distinct identity and retained origin/version lineage, so local
changes do not silently alter its source taxonomy. Copy origin does not imply permanent
term equivalence or automatic synchronization. Exact copy/version strategy, shared-change
approval and mapping policy remain proposals.

Access conditions must distinguish descriptive population classification from an
actual access requirement: an eligibility rule, legal document, appointment, referral,
payment condition or accessibility characteristic. Plain source wording is preserved;
which criteria are structured in the MVP is a later interview branch.

Q19 selects partial field-level dynamic translations in `i18n`. A description can
be translated without translating the name. Retain original language/content revision,
translated field and language, origin/method, and review evidence/status. The user
selects human, AI and AI-verified classifications (their label: `ia_verified`);
proposed English codes `human`, `ai`, `ai_verified` await final naming. Distinguish
origin from review history so verification does not erase the fact of AI generation.
A changed original marks dependent translations for review under Q19; Q24 selects retention of stale translations in history, per-field fallback to the new
published original and a visible translation-update work signal. Q23 confirms that AI translations may be
published after editorial approval while remaining classified `ai`; approval alone
does not confer linguistic verification or change their class to `ai_verified`.

Select available content in the preferred language, falling back to the original
per field. Thus a translated description and original name are a valid mixed-language
response, not an incomplete whole-object translation. Return the actual language of
each field where useful. Q20 confirms language-associated writing direction (LTR/RTL). Mixed-language content
does not change the established interface direction. Propose rendering/isolation of
each translated/original text using its actual language direction; exact rendering
belongs to the app. No separate user direction override is selected. UI catalogs live in the application rather than the database. All supported UI
languages are available across territories; a territory's dynamic translation coverage
must not restrict the user's interface language. The user specifies separate territorial
translation priorities/target languages: Rome and Barcelona may prioritize different
service-content languages. Partial translations and per-field original fallback remain
valid independently of the UI language. Language metadata supporting dynamic
content may remain in `i18n`; languages spoken by services are independent facts.

### Territorial dynamic-translation priorities — additional user requirement

Propose language identity/direction metadata plus territory translation policy records
in `i18n`, indicating desired content languages and priorities. Exact policy tables,
priority representation and required/optional translation rules remain open. Language
availability in the app's UI is a separate globally supported catalog set; do not use
territory content policy as a UI-language allowlist or publication-completeness gate.

Keep translations bound to entity/field/original revision/target language. A local
priority alone need not create a duplicate translation of identical content: reusable
translations can serve overlapping territories. The user has selected different
priorities, not necessarily different wording for the same original/language. Local
wording overrides, region-specific language variants and visibility of non-priority
translations remain open. Propose that update worklists retain the affected translation
identity and allow territory-based prioritization without duplicate work for shared
content; existing stale translations still require update signals under Q24.

### Translation-update work signals — Q24 confirmed

On publication of a changed original field, invalidate current use of translations
bound to its older field revision and create a visible update signal per affected
field/language. Retain the prior translation and its verification history. Public
readers fall back to the newly approved original until a current translation is
approved; unchanged fields keep their translations. Pending edits must not invalidate
translations attached to the still-published original.

Propose an `i18n.translation_update_requests` worklist carrying entity/field/language,
required original-field revision, previous translation reference, reason, status and
creation/completion history. Exact table/name remains a proposal. Avoid duplicate
open work for the same target and revision; a later original revision can supersede
the request while preserving history. An obsolete translation completion must not
clear work for a newer original. Completion requires an approved translation matching
the current published field revision, not merely generation of new text.

The user authorizes update signalling, not automatic external messages or a selected
issue tracker. Dashboard/worklist presentation, assignment, notification channels and
worker automation remain future implementation details/decisions. No job, trigger,
notification or translation generation is implemented in this planning session.

## 9. Application/API coverage and proposed adapters

| Observed draft consumer requirement | Proposed canonical support | Decision/adapter needed |
| --- | --- | --- |
| Language and city/area selection | Language registry and reusable territories with public map settings | UI language vs spoken language; editorial territory selection. |
| Service map/list/detail | Service + delivery links + location + address + selected taxonomy | One service can yield multiple map entries; stable service and delivery IDs must be distinct. |
| Category/color/icon filters | Generic taxonomy with a presentation projection | Detailed taxonomy is separate; old category shape is an adapter if retained. |
| Weekly hours, 24h and open-now display | Scoped hours with timezone, validity, exceptions and interpretation state | Unknown hours must not be declared closed; service vs desk vs phone scope. |
| Cost and access notes | Cost/access semantics, provenance and local overrides | Avoid assuming free or universal access from missing source information. |
| Service/place contacts | Scoped channel associations; optional named-person contact concepts | Q9: show available contacts with channel and scope/purpose labels; exact relevance, ordering and phone/WhatsApp duplicate behavior remain open. |
| Sources in public details | Sanitized attribution from selected value lineage | Raw payloads and internal/source personal details are not automatically public. |
| Contribution/review/audit drafts | Proposals, accountable decisions and canonical revisions | Auth roles, trust and publication policy require decisions. |
| Entity CRUD | Typed tables and explicit write/change services in a future API | Generic unrestricted CRUD is observed draft behavior, not approved governance. |

The API inventory records exact draft fields and endpoints. Recommended compatibility
means supporting the app's intended capabilities with an explicit new contract;
preserving every legacy table/endpoint/response is not yet a requirement. Public
projections, rather than ORM field dumps, should become the shared application/export
contract if selected. Dataset revisions must reflect relevant related-entity changes,
not only the service row's own timestamp.

### Service contact section — Q9 confirmed

The user specifies a contact section inside each service page, showing available
contacts and identifying their kind. Distinguish channel (`phone`, `email`, etc.)
from subject scope (`organization`, `location`, `service`, or delivery context) and purpose (`appointments`, `general_information`, etc.). Scope and
purpose are separate dimensions even when combined into a readable UI label.

Propose channel endpoints plus scoped associations carrying purpose/label, source
evidence, applicability and optional contact availability. A service read projection
can assemble relevant contacts with explicit labels instead of duplicating an
organization endpoint into each service. Q9 selects presentation of available
contacts, not a fallback-only rule or unrestricted inclusion of every contact owned
by an organization. Exact relevance, ordering, duplicate phone/WhatsApp handling and
named-person exposure policies remain to be designed. No association table or API
field list has been implemented or approved.

### Initial publication approval — Q12 confirmed

Newly imported or proposed services require editorial approval before their first
public appearance. Canonical selection, verification and publication remain distinct:
an imported value can be selected without authorizing publication. Propose recording
the approved revision/scope, reviewer, decision time and evidence. Exact states,
permissions and approval granularity remain design choices. Future trusted-source
automatic publication is not selected. Q13 confirms that later changes to published
information also await approval, while the last approved information remains public.

Propose an explicit boundary between pending changes and the approved public revision
or approved component selections. A source refresh must not silently alter the public
API, HSDS export or offline projection through related contact, schedule or location
rows. Approved public selections and pending proposals retain their separate evidence
and audit history. Exact snapshot/component approval representation remains open;
Q13 does not select whole-page-only approval or a particular versioning implementation.
Under Q14, urgent unconfirmed public warnings are outside the MVP. Unconfirmed
reports remain review inputs under the ordinary approval process; they do not
create an immediate public warning. Future accredited-user warnings are a deferred
possibility, not an approved role or workflow. Shared-calendar advisories selected
under Q7 are a distinct approved capability and are not revoked by Q14.

### Publication validation and delivery modes — Q15 qualified confirmation

Coordinate-free services can be approved and published after essential-field
validation. The user explicitly identifies telephone services as a valid example.
Distinguish a non-geographic delivery mode from a physical location whose coordinates
are missing: neither should receive an invented point. Proposed mode labels include
`in_person`, `telephone`, `online` and `mobile`; combinations and their representation
remain open. Do not force a mandatory physical-location relationship into every service.
Q2 selects distinct services per place; remote services retain a non-geographic delivery mode.

Propose publication validation separate from ingestion/storage acceptance, with
common identity/description/evidence requirements and delivery-specific usability
requirements. A missing optional value, an inapplicable geographic field and a missing
required contact/access field are different validation outcomes. Q16 selects name, meaningful description, delivery mode, source evidence and editorial
approval, with a usable channel for telephone/online services and identifiable location
or access directions for in-person services. A mandatory taxonomy assignment is not
selected; detailed validation rules and mobile/mixed modes remain open. Preserve failed/pending records for correction without public
publication. Known hours are not universally required under Q15; unavailable hours
remain explicit rather than inferred open/closed. App presentation for remote services
and HSDS completeness/export eligibility remain separate contracts; public EGI approval
does not automatically mean every HSDS export profile is satisfied.

### Draft and public workspaces — requested after Q16

The user requires retaining incomplete/unready records in a draft workspace and
adequately populated approved records in an active/public workspace. Do not delete a
record merely because publication validation fails. Q17 selects stable entity identity with
pending/approved revisions and an explicit public projection. Exact physical tables
and version storage remain open; identity is not moved between draft/public tables.

Selected structural direction: stable canonical identity, reviewable pending revisions
and an explicit public projection of approved information. Draft records may lack fields
required for publication; identity and structural integrity still require suitable
constraints. Imported evidence remains in `sources`, even before canonical identity
is resolved; draft is not a substitute for retained source records.

A previously published entity can have an approved public version and a pending edit
simultaneously under Q13. A single mutually exclusive draft/public flag is insufficient
if it causes the published version to disappear during editing. Public projection
selection must also cover related hours, contacts and location records. Keep editorial
readiness/publication distinct from real-world service availability: HSDS active/inactive
status describes operational availability, not whether a record passes editorial review.
Proposed editorial terms `draft`, `pending_review`, `published` and separate operational
status remain naming choices. Q17 settles the structural direction, not executable
DDL. Withdrawal, archival, merges and actual retention/deletion policies remain open;
Q16 does not establish an unconditional prohibition on all future record deletion.

### Revision history and restoration — Q17 confirmed

Services, locations and organizations retain stable identity and version history.
Each revision records content, actor, time, reason and supporting source evidence.
Related schedules, contacts, access conditions and relationships belong to the
restoration contract; restoring only the main row is insufficient. Exact relational
snapshot/delta representation and aggregate boundaries remain design work.

A restore creates a new revision derived from a chosen earlier revision, preserving
intervening changes and recording the restore actor/reason. For example, restoring
revision 1 after revision 2 creates revision 3; public use requires validation and
approval. Retained verification history remains available, but old verification must
not be silently presented as a fresh check of current real-world conditions.

Restoration scope is explicit: a service can restore a relationship to an organization
without restoring that shared organization's own content or changing other services.
Coordinated restores require an explicit scope and consistency validation. No automatic
cascade restoration is selected. The public revision and any pending edits remain
distinguishable; sources and resolution decisions remain independently retained.

### Organizations and service roles — Q18 confirmed

A service may involve multiple organizations with explicit roles. Management and
operational delivery are distinct from funding or support. Unknown organization
remains permitted under the agreed publication minimum. Propose role-bearing
service/organization associations retaining evidence, temporal validity, revision
history and optional delivery-context scope; exact table shape and role vocabulary
remain design work. Q2 selects independent service identities across delivery places.

Do not select an arbitrary organization as the single owner for storage or export.
The HSDS mapping must explicitly handle its organization/service linkage contract
when EGI retains multiple organizational roles, distinguishing delivery responsibility
from funding. Export designation and any profile limitations remain open; no exporter
or final designation policy is implemented.

### Closed-service history and public access — Q25 confirmed

Permanently closed services retain history and stable direct public links. Default
search/list/map discovery excludes them; direct detail access clearly labels closure
and preserves known closure date/reason and evidence. Exact history presentation and
optional explicit archived-search controls are not selected. Closure is an operational
state, distinct from editorial publication, stale verification or a missing schedule.
A previously approved page can remain published as a historical closed-service page.

Temporary closure has a separate operational status and retains identity. Visibility
of temporarily closed services in default discovery still requires a decision; Q25
only settles exclusion for permanent closure. Public closure changes require approval
under Q13; an unconfirmed incoming report follows ordinary review under Q14 and does
not silently change public state. Offline and HSDS projections must preserve the
selected operational state and explicit discoverability policy; exact packaging remains
open. Closure does not authorize erasing source records or revision history.

### Relocation continuity — Q28 confirmed

A genuine permanent relocation preserves service identity and revision history.
Record the old and new place relationship with applicable dates when known and
retain evidence of continuity. The approved public revision presents the new place;
older revisions retain the previous location and information. No automatic new
identity arises solely from a changed address, nor does one shared name prove that
two records are the same service. Simultaneous offers at two places remain distinct
under Q2. Detailed continuity and transition validation are future design work.

Proposed downstream handling: location-based projections and future derived proximity
results follow the approved current place, while historical versions retain their
original scope. Do not edit the shared old location's coordinates to represent the
move: it may still host other services. The exact temporal relationship tables,
scheduled move publication and handling of unknown transition dates remain open.

## 10. SQLite distribution strategy

Accepted architectural boundary: SQLite is derived read-only data, not a second
authoritative write model. Proposed first distribution is a versioned full snapshot
of approved public records, scoped by territories/languages when needed. Delta/sync
packages can be considered later; deleted/unpublished/merged identifiers require
explicit semantics if deltas are introduced.

| Canonical representation | Proposed SQLite export |
| --- | --- |
| Stable UUIDs and FKs | Same IDs serialized as text; verify all retained references. |
| Scoped relational tables | Flat table names such as `data_services`; preserve relationships while PostgreSQL namespaces remain a server concern. |
| Boolean/date/timestamps | Agreed integer booleans and ISO text timestamps/dates with timezone semantics; portable decoding. |
| JSONB extension/evidence data | Selected public JSON encoded as text; raw internal provenance excluded unless separately authorized and redacted. |
| Coordinate pair and point geometry | Export scalar latitude/longitude and optional public GeoJSON/bounds; no PostGIS runtime dependency. |
| GiST/spatial SQL | Optional R*Tree bounds filtering, exact checks/distance in the agreed offline implementation. PostGIS behavior is not automatically reproduced. |
| Full-text search | Optional FTS5 after target-runtime support and language behavior are selected. |
| Canonical/private governance and history | Export only the chosen public attribution/history subset; exclude private editorial/auth/provider material. |

SQLite's type system differs from PostgreSQL; conversion is explicit, not a binary
database clone. Foreign-key enforcement must be enabled/verified by the export
validator. R*Tree/FTS5 availability depends on the intended SQLite build/runtime.
[SQLite types](https://www.sqlite.org/datatype3.html),
[foreign keys](https://www.sqlite.org/foreignkeys.html),
[R*Tree](https://www.sqlite.org/rtree.html), [FTS5](https://www.sqlite.org/fts5.html).

A future export manifest should identify canonical snapshot/revision, export schema
and projection-policy versions, creation time, area/language selection, license/
attribution, checksums and supported consumer version. Produce it from a consistent
database snapshot, verify referential closure and public redaction, then publish
atomically. Packages with multiple territories reference the same canonical IDs.
These are planned exporter responsibilities; no exporter has been written.

## 11. Sqitch, bootstrap and implementation boundaries

Selected: Sqitch for structural deployment and a later separate data population
script. Proposed changes are small dependency-ordered units with deploy/revert/verify
scripts. Sqitch supports dependency-aware changes and separate deployment,
reversion and verification actions.
[Sqitch manual](https://sqitch.org/docs/manual/sqitch/).

Proposed implementation organization, not created now:

```text
sqitch.plan / sqitch.conf
deploy/    structural changes
revert/    change-specific reversal or explicitly reviewed irreversible policy
verify/    structural/constraint assertions
bootstrap/ later reproducible dataset initialization
docs/      contracts, design and decisions
```

Keep source datasets and detailed taxonomy out of structural deployment by default.
Distinguish structural code registries from evolving editorial vocabulary. A later
bootstrap should identify input versions, schema compatibility, processing runs,
stable keys and selection rules, support safe reruns and report unresolved records.
It must not bypass provenance simply to make the directory nonempty.

Sqitch verify scripts establish expected deployed structure; they should not depend
on whatever mutable real-world records happen to be present. The full import/public/
export scenarios need separate fixtures and checks.
[Sqitch verify reference](https://sqitch.org/docs/manual/sqitch-verify/).

Database version support, test harness, PostgreSQL extension ownership, deployment
targets and backup/upgrade procedures are open future implementation decisions.
Destructive revert policy is not automatically approved. No Sqitch initialization,
SQL, database connection, data bootstrap or package installation is part of this phase.

## 12. Proposed constraints and invariants

These are proposed acceptance contracts, not installed constraints:

1. Source evidence and older interpretations remain available after a new import,
   normalization, selection, merge or split.
2. Upstream identifiers are unique in the proper source/dataset scope, not globally;
   distinguish missing stable keys from generated retrieval locators.
3. A normalized subject can contribute to a canonical entity without transferring
   authority to all its fields. Evidence targets and entity kinds remain valid.
4. Published service availability, editorial publication and evidence verification
   are different states. Unknown/conflicting values stay representable.
5. Service/location links have explicit identity and override semantics. Their
   uniqueness key must permit the delivery modes selected in the interview.
6. Scalar coordinates are both present or both absent, within valid WGS84 ranges;
   spatial derivations agree with the chosen pair. Missing geography is allowed during ingestion.
7. Hours preserve timezone, overnight meaning, validity and exceptions; unknown
   operating times do not become an automatic closed/open answer.
8. Territory membership and eligibility coverage are distinguishable. One entity
   can appear in several territories without duplicate identities.
9. Hierarchy changes preserve term identity, enforce the selected acyclicity and
   vocabulary boundaries, and retain classification provenance.
10. Public views, HSDS output and SQLite packages share approved-record selection
    rules. Confidential facilities are outside the current catalog scope; optional
    future protected-location support needs a separately selected contract.
11. Exports retain all needed foreign-key targets and supported consumer semantics,
    drawn from one consistent canonical snapshot.
12. Related changes advance the public resource/dataset revision. Source freshness,
    retrieval time and editorial modification time remain distinct.

## 13. Candidate indexes and uniqueness rules

- Domain PKs and relationship FKs; indexes on public state/provider/revision where
  supported by observed API queries.
- Source identity uniqueness on `(source, dataset scope, upstream key)` when the
  upstream key exists. Version/content hashes help deduplicate payload storage;
  hashes are not substitutes for source record identity or retrieval history.
- Normalization identity on input version, transform version, run and subject
  locator; current resolution/value binding indexes by canonical subject and scope.
- Assertion indexes on normalized subject, attribute/scope and validity where
  review/selection queries need them. Avoid indexing every raw JSON property.
- Taxonomy code uniqueness scoped to vocabulary/version; relationship and assignment
  indexes by parent/subject/term. Names/slugs are not automatically global keys.
- Territory membership/coverage indexes and GiST indexes on the spatial representation
  used by the selected public filters. A geography expression/index must match the
  metric-distance query strategy.
- Geocode cache lookup key includes provider and contextual request identity;
  retain multiple result versions and retry state rather than one overwritten row.

Exact uniqueness, partial-index and retention strategies require the settled domain
model and representative query/data volumes. Index proposals do not establish performance.

## 14. Decisions, alternatives and open design tree

Accepted architecture: [ADR 0001](../adr/0001-canonical-database-and-offline-distribution.md)
records one PostgreSQL authority and derived SQLite output. Requirements reject
source overwriting, geometry-only coordinates, independent SQLite write authority,
hard-coded matching and migration-bound categories. Those alternatives fail R6–R11.

Rejected for current canonical identity under Q2: one shared multi-location service.
Recommended but not selected: a provenance-target
registry; UUID internal/public IDs; field/collection-level selection evidence; a
public projection shared by exporters. Alternatives remain explicit in sections 4–10.

The interview tree begins with four independent decisions. Answers will unlock
detailed questions on contact/hour/access scopes, taxonomy hierarchy, provider
ownership, identity/reversibility, territorial coverage, languages, geocoding,
export packaging and operational implementation choices.

| Round 1 | Decision and recommendation | Status |
| --- | --- | --- |
| Q1 | Validatable HSDS export as the compatibility objective; mapping planned now, exporter later; application API may have its own contract. Full HSDS API conformance remains separate. | Confirmed by the user, 2026-10-05. |
| Q2 | Distinct services per delivery place/area; common organization/classification links similar offers. A location can host many services across categories and organizations. The earlier open decision is now settled. | Confirmed after examples, 2026-10-05. |
| Q3 | Hybrid selection: retain all assertions; automate straightforward choices using explicit policies; ambiguous conflicts and merges remain reviewable. Specific policy, actor and publication rules remain open. | Hybrid approach confirmed, 2026-10-05. |
| Q4 | Non-confidential facilities only in the current scope. No interest in publicly mapping confidential facilities or managing their specialized storage now; defer that functionality. Existing source evidence is preserved. | MVP scope selected, 2026-10-05. |


### Q2: retained comparison and selected outcome

Historical comparison: the user subsequently selected distinct site-specific services. Both designs can produce
one map entry at each delivery site; sharing logical service identity does not
require one marker, one centroid or one merged set of operating hours.

| Example: same association's meal service in two locations | Map/list presentation | Editorial implications |
| --- | --- | --- |
| One logical service, two delivery links | Entry A at location A and entry B at location B; each uses local hours, contacts and access details. | Common details can be maintained once; local differences are explicitly scoped. |
| Two site-specific services | Entry A at location A and entry B at location B, with independently stored details. | Independent lifecycle is simple; shared information and cross-source resolution require explicit grouping/update policy. |

Display identity and canonical identity need not be the same: a map entry can have
both a service identifier and a delivery-context identifier. Marker aggregation
when different services share the same location, and the definition of independently
managed offers, remain open presentation/domain decisions. The selected outcome is distinct site-specific services; exact marker aggregation
and frontend implementation remain open.

### Round 2: independent questions while Q2 remains open

| Question | Proposed decision | Status |
| --- | --- | --- |
| Q5 | Distinguish service/activity/contact schedules and preserve unknown hours. User additionally requires simple tabular rendering, open-now queries and closing countdowns. Physical rules and exception/conditional semantics remain proposals. | Confirmed and extended by the user, 2026-10-05. |
| Q6 | Separate map/editorial territories from service coverage/geographic eligibility; overlapping map membership preserves canonical identity. Boundary detail remains open. | Confirmed by the user, 2026-10-05. |

### Round 3: schedule semantics

| Question | Recommendation / boundary | Status |
| --- | --- | --- |
| Q7 | One shared exception calendar initially; future organization-managed pages and custom calendars. Support both advisories and confirmed replacement/closure rules. Default to possible variation and invite contact when reliable exceptional hours are absent. Applicability and precedence remain open. | Calendar scope and event types/default confirmed by the user, 2026-10-05. |
| Q8 | Access conditions remain separate from calendar operating hours. Detailed response/display contracts are still proposed. | Separation confirmed by the user, 2026-10-05. |

### Follow-up decisions and next interview branch

- Relational interval table selected, 2026-10-05; weekday encoding remains open.
- Shared calendar supports advisory and confirmed variation events. Advisory with
  contact invitation is the default when reliable exceptional hours are absent.
- Q9 confirmed, 2026-10-05: service pages include a contact section showing available
  contacts with channel and scope/purpose labels (for example phone/email and
  organization/appointments). This is not limited to a fallback-only display rule.
- Q10 confirmed, 2026-10-05: verification can apply to individual information
  components or an entire page. Retrieval/import, modification and actual verification
  times remain distinct; checking a phone number does not verify operating hours.
- Q11 confirmed, 2026-10-05: keep aging information visible with a
  needs-reconfirmation warning. Elapsed time alone does not hide a record or
  establish closure/invalidity. Review thresholds remain to be selected.
- Q12 confirmed, 2026-10-05: initial publication of newly imported or proposed
  services requires editorial approval. Future automatic publication needs explicit
  policies; hybrid canonical selection does not itself authorize publication.
- Q13 confirmed, 2026-10-05: updates to published information require approval;
  the last approved information remains public while imported/proposed changes await
  review. Pending updates and their evidence remain retained. No automatic public
  replacement is authorized by source refresh or hybrid canonical selection.
- Q14 answered, 2026-10-05: urgent unconfirmed public warnings are excluded from the
  current MVP. The user wants to revisit the possibility later, potentially for
  accredited users. This does not approve accreditation or privileged publication.
  Reports follow ordinary review; public information remains as last approved.
- Q15 confirmed with qualification, 2026-10-05: publication without coordinates or
  known hours is allowed, but essential fields must pass validation. Telephone services
  are a valid delivery mode without coordinates, not necessarily incomplete physical
  locations. Exact essential fields and delivery-specific requirements remain open.
- Q16 confirmed, 2026-10-05: name, meaningful description, delivery mode, source
  evidence and editorial approval; usable channel for telephone/online services and
  identifiable location/access directions for in-person services. Hours and responsible
  organization can be unknown. A taxonomy classification was not selected as mandatory.
  User additionally requests retaining incomplete/unready records in draft and a
  public/active space for adequately populated approved records, without deleting
  records merely because they fail publication validation.
- Q17 confirmed after clarification, 2026-10-05: stable identity, retained revision
  history and traceable restoration for services, locations and organizations. Include
  hours, contacts, access conditions and relationships. Restoration creates a new
  revision rather than deleting intervening history; validate and approve before public
  restoration. Restoring a service does not automatically restore a shared organization.
  Pending and approved versions can coexist. Exact physical version storage remains open.
- Q18 confirmed, 2026-10-05: multiple organizations may be involved in a service with
  explicit roles, separating management/operational delivery from funding/support.
  Unknown organization remains permitted under Q16. Role vocabulary, validity/scope
  details and HSDS mapping for multiple responsible organizations remain open.
- Q19 confirmed and extended, 2026-10-05: partial dynamic translations in `i18n`,
  preserving originals and classified as human/AI/AI-verified; app owns UI catalogs.
  Preferred-language content falls back to original per field. Preferred orientation
  needs clarification. AI linguistic-verification authority and final codes remain open; Q23 selects publication of editorially approved AI content.
- Additional requirement: dedicated stored-result schema for periodically computed
  spatial enrichments from external transport sources; proposed namespace `derived`.
- Q20 confirmed, 2026-10-05: language-associated writing direction; retain the existing
  UI direction when original and translated content mix languages. No explicit override
  preference or text-rendering implementation has been selected.
- Q21 confirmed then scope clarified, 2026-10-05: all transit enrichment is future work,
  not MVP. Initial future proximity uses direct distance; later walking routing/navigation
  depends on a suitable free/inexpensive real-time service. Further source inspection is
  deferred and is not a blocker for core database design.
- Q22 answered and inspected: Roma Capitale sources are in the earlier EGI collection.
  The local transport CSV lists nine line records, not station/stop coordinates. Its
  common catalog URL was not accessible via the web tool; point-level data still need
  inspection before selecting the transport ingestion contract.
- Q23 confirmed, 2026-10-05: AI translations may be published after editorial
  approval while remaining classified `ai`; publication approval is distinct from
  linguistic verification and does not automatically confer `ai_verified`.
- Q24 confirmed with addition, 2026-10-05: when a changed original is published,
  retain its older translations in history and fall back to the new original for each
  affected field until the updated translation is approved. Unchanged translations
  remain usable. Create a visible signal that translation updates are needed.
  Proposed implementation: a persistent field/language update worklist, not an external
  issue tracker or automatic email. Representation/assignment/notification choices remain open.
- Q25 confirmed, 2026-10-05: permanently closed services are retained in history,
  excluded from ordinary discovery and accessible by direct public link clearly labelled
  closed. Preserve known closure reason/date and evidence; temporary closures have a
  distinct operational status. Closure publication follows approval under Q13/Q14.
- Q26 answered and corrected by the user, 2026-10-05: show all itinerant delivery
  places regardless of the current operating day, clearly indicating when the service
  operates at each place. The earlier instruction to hide places outside their operating
  day was explicitly revoked before implementation. For A/X, B/Y, C/Z, display A with
  X's schedule, B with Y's schedule and C with Z's schedule. Default visibility is not
  an open-now filter. Q2 subsequently selects distinct services per place/area. Unknown exact stop locations
  and coarse-area rendering remain to be discussed.
- Q27 confirmed, 2026-10-05: show the known area/neighborhood with an explicit
  exact-location-unavailable indication rather than an invented point marker. Use
  point locations only for actually known stops. Boundary source/precision remains open.
- Q2 settled after concrete examples, 2026-10-05: independent services per place/area;
  similar offers linked through organizations and classification. One facility can host
  multiple services across categories and from different organizations. Hosting and
  delivery responsibility are distinct. Itinerant places follow place-specific identity.
- Q28 confirmed, 2026-10-05: a genuine permanent relocation of the same service
  preserves its ID/history and records the changed place. Simultaneous offers at
  different places retain distinct service identities. A shared name/category alone
  does not establish continuity; detailed evidence/transition rules remain design work.
- Q29 confirmed after explanation, 2026-10-05: allow several broader parents within
  one axis and prevent cycles. Hierarchy expresses is-a; distinguish generic relations
  and cross-axis mappings. Initial vocabularies may use trees. Multiple classifications
  of a service are independent of how many parents a term has. Detailed vocabulary
  remains a separate task.
- Q30 confirmed, 2026-10-05: category filtering includes the selected term and all
  descendants in its axis; deduplicate services reached through multiple hierarchy paths.
- Q31 confirmed, 2026-10-05: OR within each axis, AND between selected axes, with
  descendant expansion and deduplication under Q30.
- Added territorial requirement, 2026-10-05: taxonomy adoption is regional/map-specific;
  Florence need not use Rome's taxonomy because local services and categories can differ.
  Scope classifications and filtering to the territory's selected taxonomy. Exact reuse,
  axis-sharing and cross-vocabulary mapping policies remain open.
- Q32 confirmed, 2026-10-05: explicitly reuse a shared taxonomy or create an independent
  local vocabulary/copy. Independent local edits must not silently modify other maps.
  Copy origin/version lineage is proposed; automatic synchronization is not selected.
- Additional i18n clarification, 2026-10-05: supported UI languages remain globally
  available across territories; desired/prioritized dynamic service-content translation
  languages differ by territory (Rome versus Barcelona). Do not couple interface
  availability to local content translation coverage.
- Q33 accepted with emphasis, 2026-10-05: an applicable approved translation can be
  shown even if its language is not locally prioritized. The user finds this scenario
  unlikely and emphasizes the firm logical separation between global app UI languages
  and dynamic content translations. Do not prolong the interview over this edge case.
- Interview checkpoint: the user requests remaining-question count, open decisions and
  deliverable scope. Enough domain decisions exist to synthesize a first concrete schema
  proposal now. Consolidate technical recommendations rather than asking a confirmation
  for each internal detail. At that checkpoint, estimated roughly 3–5 substantive follow-up questions in
  grouped rounds; Q34–Q37 subsequently settle all but the HSDS export policy discussion.

### Consolidated closure round Q34–Q37

- Q34 confirmed: structured appointment/referral/documents/access requirements and
  cost states `free`, `paid`, `variable`, `unknown`, alongside original notes.
- Q35 confirmed: proposing and approval/publication capabilities, accountable actors,
  territorial authorization scope; public source names/links and relevant dates, with
  raw payloads/conflicts/internal notes kept in the workspace. Detailed role enforcement
  remains part of the proposal, not an implemented permission system.
- Q36 resolved after examples, 2026-10-05: support explicit defaults for required
  export fields and exclude records still invalid. Preserve records and diagnostics;
  the user notes these records will often also fail EGI validation, but validation
  contracts remain distinct. Verified v3.3.1 examples: unknown organization linkage
  for tabular organization_id; organization lacking required description; unknown
  status outside the required service enum. JSON/tabular requirements differ; absent
  hours/coordinates do not by themselves invalidate a service. Exact default recipes,
  output format and responsible-provider designation are technical mapping proposals
  in the concrete schema, not implicitly known canonical facts.
- Q37 confirmed: territory snapshots of current approved public data and available
  translations; retain closed-service direct-access information while excluding it from
  ordinary search; exclude drafts/full editorial history; version/date manifest.
  Refresh cadence and incremental sync remain later decisions.

### Remaining decisions and proposal scope at the interview checkpoint

Enough input exists for a first concrete database schema proposal; no implementation
or final specification approval is implied. The next deliverable should consolidate
schemas/tables/columns, cardinalities, logical keys/constraints, revision/restoration,
source lineage, regional taxonomy/i18n and application/HSDS/SQLite projections with
selected decisions, technical recommendations and open choices clearly separated.

The final Q34–Q37 round settles the outstanding domain policy groups: structured
access/cost, accountable editorial capabilities/public attribution, HSDS defaults and
invalid-output exclusion, and territorial approved-public SQLite snapshots. No further
mandatory domain interview round is identified before schema discussion. Technical
choices are presented as recommendations in the concrete schema proposal.

Technical recommendations to produce directly in the proposal, subject to review:
identity registry versus typed evidence links; UUID strategy/legacy adapters; exact
schema/table/column names; normalized revision and relationship representation;
weekday rule encoding, timezone/exception precedence; indexes; taxonomy adoption and
version representation; translation worklist; consistency and validation contracts.
Their proposed status does not require an interview question before they can be drawn.

Deferred work: detailed taxonomy vocabulary, numerical freshness thresholds, geocoder
provider/licensing, supported engine/deployment/test/remote/tracker configuration,
organization self-service/accreditation, transit enrichments and walking navigation.
These do not block the first schema proposal. Exact actor/policy/provider decisions
must precede the implementation slice that actually depends on them.

## 15. Suggested implementation phases and acceptance evidence

These phases are proposals, not tickets or execution authorization:

1. Finish the interview; settle domain definitions and compatibility/exposure
   contracts; review and approve the specification.
2. Establish selected Git/development/test conventions and Sqitch configuration;
   implement identity and core service/location relationships with integrity checks.
3. Implement source registry/versioning, normalization/assertion contracts,
   resolution/value decisions and audit. Demonstrate repeat imports and conflicts
   using small synthetic fixtures before loading a real collection.
4. Add territories, scoped contacts/hours/access and geocode selection/cache;
   introduce taxonomy structure and language integration without designing the detailed vocabulary.
5. Define and verify public/application and selected HSDS projections. Design the
   separate data bootstrap using actual input versions and canonicalization policy.
6. Populate verified data through the approved bootstrap; later implement SQLite
   distribution and consumer parity checks. Live capacities/advanced governance/
   transit or other extensions are separate scoped slices.

| Acceptance scenario | Evidence needed in a future implementation |
| --- | --- |
| Two sources describe the same service | One canonical service linked to both sources; both original descriptions and retrieval history remain inspectable. |
| Sources disagree about one hour/contact/access value | Both assertions retained; selected or unresolved canonical state and its accountable evidence visible. |
| A source is reprocessed after parser changes | New normalized interpretation with version/run lineage; old interpretation and editorial choices survive. |
| Place-specific services and shared facilities | Similar offers at different places have independent service IDs/history; one facility hosts several services with independently identified providers and categories. |
| Ingested location has no coordinates | Normalization/resolution succeeds; later geocoding selects evidence and produces consistent scalar/spatial values. |
| A second territory is activated | Existing canonical IDs reused, queries/packages scoped correctly, no Rome-only schema assumption. |
| Taxonomy gains another axis or hierarchy edge | Vocabulary data changes without category-specific DDL; constraints and historical classifications remain coherent. |
| Weekly table, open-now query and closing countdown use the same hours | Consistent split shifts, overnight/date boundaries, timezone interpretation, unknown days and next closing transition. Access remains separate under Q8; shared-calendar advisories do not imply confirmed hours; confirmed variations use their selected evidence. Precedence and conditional cases follow the pending detailed semantics. |
| Input unexpectedly includes a confidential facility | Do not introduce it into the current public catalog under the non-confidential scope. Select rejection/hold/evidence handling before implementing ingestion; specialized confidential-location management is deferred. |
| A SQLite snapshot is generated | Stable IDs, complete referenced records, conversion/public-policy checks and manifest tie it to one canonical snapshot. |
| Schema and dataset are provisioned separately | Sqitch verifies structure; rerunnable bootstrap records inputs/provenance and applies only the selected canonicalization policy. |

## 16. Readiness

**First concrete schema proposal produced; ready for discussion and technical review,
not approved for implementation.** Core domain interview and closure round are recorded.
Review [schema-proposal.md](schema-proposal.md), whose table definitions, integrity
mechanisms and default recipes remain technical proposals. Ask additional questions only
if that review reveals a material policy ambiguity. Transit work remains deferred.

Confirm shared understanding before marking the specification review-ready. The
requested `review-spec` skill is unavailable; an equivalent guided specification review
can be performed when stable. Available `to-tickets` belongs after a reviewed
specification and approved action plan, when the user requests that phase.
