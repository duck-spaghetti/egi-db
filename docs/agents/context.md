# Database context

## User decisions

On 2026-10-05 the user selected these constraints:

- Design the first canonical EGI model, informed by existing sources and application drafts.
- Support an eventually validatable HSDS export, with its mapping designed now
  and exporter implementation later. EGI may keep its own application API contract;
  HSDS API protocol conformance is not selected. Physical storage need not copy HSDS.
- PostgreSQL is authoritative; PostGIS supplies geospatial capabilities; use `psql`
  as the client and Sqitch for schema/deployment management.
- Plan a separate population bootstrap when data is ready.
- Support Rome and surroundings first and multiple geographic areas later.
- Preserve source assertions, conflicting values, stable source identifiers when
  supplied, canonical lineage and reproducible reprocessing.
- Support evolving normalization, matching, entity resolution and merge decisions
  without fixing one algorithm into the canonical schema.
- Retain raw and normalized addresses, scalar coordinates, geocoding provider,
  evidence, confidence/status and cacheable results. Geocoding may occur after
  normalization/resolution; PostGIS is not the sole coordinate representation.
- Support future hierarchical taxonomy axes including need, service type and
  target population/access characteristics; detailed taxonomy is separate work.
- Keep SQLite feasible as a derived read-only offline/export representation of
  the same dataset, with portable core relationships and isolated spatial features.
- Use English identifiers and documents. Planning only: no code/schema implementation.
- Use hybrid canonical selection: retain all assertions, automate straightforward
  choices under explicit policies, and keep ambiguous conflicts/merges reviewable.
  Detailed policies and publication authority still require decisions.
- Current scope covers non-confidential facilities. The user does not want to manage
  or publicly map confidential facilities in the MVP; specialized private-location
  storage and workflows are deferred. No deletion of existing raw evidence is authorized.
- Q2 selects distinct service identities per delivery place/area, with independent
  pages/schedules/history and common organization/classification links. One facility
  may host several services across categories and from different organizations;
  hosting does not imply service delivery responsibility. Q28 selects preserved ID/history for a genuine permanent move, with the changed
  place recorded. Simultaneous delivery at different places retains distinct service
  identities. Exact temporal relationships and continuity evidence rules remain open.
- Distinguish service operating hours, intake/office hours and contact availability.
  Unknown hours stay unknown. Stored schedules must support simple tabular display,
  open-now queries and time-to-closing calculations; the physical representation
  and exceptional/conditional-hour policies are being designed.
- Separate map/editorial territories from service coverage and geographic access
  requirements; allow overlapping map territories while preserving canonical identity.

- Initially use one shared exception calendar; later support organization-managed
  pages and custom calendars. Support both advisory and confirmed variation events;
  default to possible variation and invite contact when reliable exceptional hours
  are unavailable. Calendar applicability/precedence and the organization authorization
  model remain open.
- Keep access conditions separate from calendar operating hours (Q8 confirmed).
- Store canonical weekly intervals in a relational table (selected 2026-10-05).
  The earlier JSON weekday-bitmask alternative is not selected as canonical storage.
  Weekday encoding, exact columns and any JSON API projection remain design details.

- Each service page includes a contact section showing available contacts and
  labelling channel (phone/email/etc.) and scope/purpose (organization/appointments/etc.).
  Relevance and ordering rules remain design details; Q9 does not select fallback-only
  display or unrestricted inclusion of organization contacts.

- Verification can cover individual information components or an entire service
  page. Keep verification times distinct from import and modification times; a
  check of one component does not verify unrelated information (Q10 confirmed).
  Freshness thresholds, actor authority and verification invalidation remain open.

- Aging information remains visible with a needs-reconfirmation warning (Q11
  confirmed). Time elapsed alone does not establish closure/invalidity or hide it.
  Review thresholds remain to be selected.

- Newly imported or proposed services require editorial approval before first
  publication (Q12 confirmed). Future automatic publication needs explicit policies.
  Updates to already published information also require approval (Q13 confirmed);
  retain the last approved public information while changes await review. Pending
  changes must not leak through shared related rows into public projections.
  Exact revision/approval storage remains open.
- Urgent unconfirmed public warnings are outside the current MVP (Q14). Revisit
  future support potentially involving accredited users; no accreditation model or
  privileged publication workflow has been selected. Ordinary review remains in effect.
  This does not alter the separately selected shared-calendar advisory capability.

- Publication can include services without coordinates or known hours, but requires
  validation of essential fields (Q15). Telephone services are a valid mode without
  coordinates, distinct from physical locations missing geocoding. Q16 confirms name, meaningful description, delivery mode, source evidence and editorial
  approval, plus a usable channel for telephone/online services or an identifiable
  location/access directions for in-person services. Known hours/organization are not
  universally required; detailed validation and mixed/mobile modes remain open.
- Retain incomplete/unready records in draft; adequately populated approved information
  belongs in a public/active workspace. Publication validation failure does not delete
  records. Q17 selects stable identity with pending/approved revisions and an explicit
  public projection; exact physical version storage remains open. Previously approved
  public information coexists with pending updates under Q13.
- Services, locations and organizations retain revision history and traceable restoration
  including hours, contacts, access conditions and relationships (Q17). Restore creates
  a new revision, preserves intervening history, and requires validation/approval for
  publication. Restoring a service does not automatically restore shared entities.

- A service may involve multiple organizations with explicit roles, distinguishing
  management/operational delivery from funding/support (Q18). Unknown organization
  remains permitted. Role vocabulary, contextual/temporal scope and HSDS designation
  for multiple responsible organizations remain open.

- Dynamic translations live in `i18n`, may cover only some fields, retain originals,
  and are classified as human/AI/AI-verified (Q19). Prefer the user's language and
  fall back to original per field. UI catalogs live in the app. Language-associated writing direction is confirmed (Q20); mixed-language fields
  preserve the existing interface direction. Exact class identifiers and AI
  publication/verification policy remain open.
- Provide a dedicated schema for periodically computed/stored PostGIS enrichments,
  initially proximity to public transport. The user subsequently clarifies that the entire transit enrichment feature is future
  work outside the MVP; no immediate implementation or further source investigation is
  needed. Initial future proximity uses direct distance; walking navigation comes later. Namespace `derived`, run/freshness policy and representation remain
  proposals. Q22 sources are in the earlier `egi-sources-roma/Roma Capitale` collection:
  local transport CSV has nine line records, not individual stations/stops. Its catalog
  link was inaccessible via the web tool; actual point-level source data and license
  still need inspection. No format or future routing provider is selected.

- Permanently closed services remain in history and accessible by direct public link
  clearly labelled closed, but are excluded from ordinary discovery (Q25). Temporary
  closure has a distinct operational status; its default visibility remains open.
  Publishing closure still follows ordinary editorial approval.

- Itinerant delivery places remain visible regardless of the current operating day;
  clearly display each place's own applicable days/hours (Q26 corrected decision).
  The earlier day-based hiding instruction was explicitly superseded. Default
  visibility is distinct from open-now filtering; Q2 selects distinct service identities per place/area.

- For itinerants with only a known area/neighborhood, show that area and explicitly
  indicate the exact location is unavailable (Q27). Do not invent a point marker;
  known actual stops can use points. Boundary source and rendering remain open.

- Within a taxonomy axis, terms can have multiple broader parents with cycle prevention
  (Q29). Hierarchy expresses is-a; cross-axis mappings/generic relations are distinct.
  Initial vocabularies can be trees. Detailed vocabulary remains separate work;
  physical constraint enforcement remains open. Q30 selects filtering by a term plus
  all descendants within its axis, deduplicating service results across hierarchy paths.
  Q31 selects OR within an axis and AND across selected axes.
- Taxonomy adoption is scoped to the map territory/region: future Florence need not
  use Rome's vocabulary/hierarchy. Classifications and filters require the selected
  territorial taxonomy context. Q32 permits explicit shared-taxonomy reuse or an independent local copy with separate
  edits. Exact copy/version strategy, shared governance and axis-sharing remain open.
- Supported UI languages remain globally available across territories. Dynamic service
  translation target languages/priorities may differ by territory (Rome/Barcelona);
  do not restrict UI languages by local content coverage. Existing partial translation
  and original fallback requirements remain in effect. Q33 permits an available applicable approved translation regardless of local priority;
  the user emphasizes the firm UI/content separation and considers this edge case minor.
  Shared reuse/local wording overrides can remain proposed details for later review.

## Observed state

`egi_database` is a newly initialized Git repository with unborn `master`, no commits
and no remotes. Its existing entrypoints referred to the shared workspace docs.
No product code, Sqitch configuration, deployed schema, test configuration or
database connection has been found here. `sqitch` and `psql` were not discoverable
on the shell PATH used for this inspection; that does not establish whether another
installation exists. Tool selection is settled; configuration is future work.

The original app remains in `../../../../personal_projects/egi-app` from this
document. Draft revision is `c090950874a8c5ac39c83f9ba2aa1ae06356af84` (`origin/wip`);
the checkout remains on `main`. Earlier data and SQL are in
`../../../../egi/sources/egi-sources-roma`. See the
[API/data inventory](../design/api-and-data-inventory.md) for detailed findings and
the [shared workspace context](../../../docs/agents/context.md) for the initial inventory.

## Settled boundaries and open decisions

The database technology choices do not select the entire application stack.
Poetry/FastAPI/SQLAlchemy/Jinja2 are observed in earlier drafts; their adoption for
the new app remains separate. The old SQL and ORM are competing evidence, neither
an authoritative contract. Preserve requirements demonstrated by the drafts while
allowing the new API to evolve through explicit decisions.

See the [design](../design/canonical-database.md) for the proposal and question tree.
GitHub Issues is selected; its repository still needs creation. Development
branch/remote bootstrap, test harness and deployment targets remain undecided. They do not block design
discussion. They must be settled before implementation that depends on them.

## Interview checkpoint

Core input is sufficient for a first concrete schema proposal. Consolidate technical
recommendations and existing decisions before additional granular questions. Estimated
remaining substantive questions: roughly 3–5, grouped around access/cost, governance/
attribution, HSDS completeness and optional offline packaging; not a fixed checklist.
Keep recommendations distinct from selected choices and deferred implementation setup.

## Consolidated closure round

Q34, Q35 and Q37 confirmed: structured access/cost alongside notes; accountable
proposal/approval roles with territorial scope and sanitized public source attribution;
territorial SQLite snapshots of approved public data/translations, including historical
closed-service access, excluding drafts/full editorial history. Q36 subsequently confirms required-field defaults and exclusion of still-invalid
HSDS output records after examples, preserving records/diagnostics. Specific default
recipes and provider designation remain technical export proposals. Do not assume missing coordinates/hours make a record invalid HSDS.

## Concrete schema proposal produced

The domain interview and Q34–Q37 closure round are consolidated. Read
[the schema proposal](../design/schema-proposal.md) before discussing tables, revision
integrity, translation reuse, taxonomy releases or public/export projection boundaries.
It is the concrete first proposal for review, not approved DDL or implementation.
The earlier working design remains the research/decision ledger. No further required
domain interview round is identified before reviewing the schema; unresolved technical
recommendations are explicitly proposed there. No SQL, Sqitch project or data loading
has been implemented.

## Specification and implementation planning, 2026-10-05

The user considers the schema structure sufficient and explicitly requests `to-spec`
then `plan-with-docs`. [Specification v1.1](../design/specification.md) synthesizes the
closed domain discussion. [Plan r0.2](../design/implementation-plan.md) records the approved approach,
environment and DB behavior/verification choices. Implementation has not started.
[GitHub tracker conventions](issue-tracker.md) record the selected provider and the
new repository still to create. No issues, remote changes or implementation occurred.

Read-only environment follow-up found PostgreSQL 18.3 client/binaries under
`/Library/PostgreSQL/18`, PostGIS control files declaring 3.6.0, and another 12.17
`pg_config` under Anaconda on PATH. Sqitch/container CLIs were not found on that PATH
or common inspected paths. No database connection verified server/extension readiness.
Use explicit tool paths in the eventual setup plan; do not confuse installation files
with a running configured database.

## Implementation planning confirmation

On 2026-10-05 the user replied “Confermo tutto” to the presented plan and P1/P2.
Record the native PostgreSQL 18.3 dedicated-test environment and DB-level
publication/restoration operations with psql/Sqitch synthetic checks as approved
planning choices. Plan r0.2 consolidates them without expanding scope; specification
v1.1 records the approved verification seam. No implementation, tests, installation
or connection has occurred. GitHub owner/name/visibility and execution mode remain
prerequisites for their later phases, not unresolved product interview questions.

## Ticket publication, 2026-10-05

The user created the private GitHub repository duck-spaghetti/egi-database and
authorized configuring origin and to-tickets. The 10-ticket breakdown was approved
with “va benissimo”; issues #1–#10 were published and their exact bodies/native
dependencies verified. See the action plan’s published mapping. No implementation,
commit/push, installation or DB connection occurred. Execution mode and Git bootstrap
remain implementation prerequisites.
