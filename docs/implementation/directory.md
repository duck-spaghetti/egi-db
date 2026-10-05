# Hours, calendars, territorial taxonomy and dynamic text — checkpoint #5–#9

This is the database contract. No HTTP service, live source loader, HSDS serializer
or SQLite file is delivered. The first four published Sqitch changes remain intact;
six new changes extend them. All controlled write entrypoints require READ COMMITTED,
trusted session actors and the existing serialized operation lock.

## Revision-owned hours

`save_revision` accepts `schedules` on services, organizations and locations.
Service/intake schedules belong to services; contact schedules reference a public
or private contact component in the same revision. Private contact hours are hidden
from public reads. These collections replace the previous saved aggregate; omission
means no hours in the new revision, not an implicit patch of the old revision.

```json
{
  "schedules": [{
    "component_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "scope": "service",
    "timezone": "Europe/Rome",
    "completeness": "complete",
    "days": [{
      "weekday": 1,
      "state": "intervals",
      "completeness": "complete",
      "intervals": [{"opens": "22:00", "closes": "02:00", "end_day_offset": 1}]
    }]
  }]
}
```

ISO weekdays are 1–7. Days have intervals/closed/unknown states; missing days are
unknown. Partial coverage stays partial. Intervals are half-open and at most 24h;
next-day equal endpoints represent 24h. Adjacent/overlapping intervals are evaluated
as a continuous open period. Every schedule and interval has its own accountable
value decision, defaulting to the supplied hours/record evidence when narrower
assertions are absent. Validity dates apply to the day the interval starts.

The user confirmed **local-clock DST semantics** on 2026-10-05: repeated civil
intervals occur both times, nonexistent civil intervals do not occur, and spans
across a jump remain open when their civil predicate remains true. Real countdowns
use elapsed time. The evaluator checks actual civil endpoints and clock jumps;
it does not assume every offset change is an hour. These are interpretations of
published schedules, not a new real-world verification of the provider's behavior.

`api.weekly_hours` supplies tabular rendering. `api.weekly_opening(entity, instant,
scope, contact)` evaluates the weekly baseline. `api.opening` includes calendar and
operational closure. Scope defaults to service; intake and contact are separate.
No is_open_now value is stored. Missing/conflicting effective schedules yield unknown.
An asserted interval in a partial declaration can establish open; outside that
interval, incomplete coverage prevents an invented closed assertion.

The response contains status, certainty, basis, timezone, next transition and an
optional closing countdown. The transition search horizon is explicitly eight
elapsed days; null means no known transition within that horizon. Unknown next
states never produce a closing promise. Temporarily closed and defunct services
return a declared closed status; temporary closure remains discoverable. Itinerant
places remain listed on non-operating days with their own local schedule.

## Shared exception calendar

`create_calendar` registers the initial shared calendar; the schema does not impose
a singleton. Actual calendars/events are bootstrap or editorial data, not migration
seeds. `save_revision('calendar_event', ...)` accepts name, optional description,
calendar_id, date_from/date_until and event_kind. Default kind is advisory.
Calendar-event identities use the existing exact revision review/publication workflow.
Territorial calendar changes require capabilities for their consumers' territories.

A schedule explicitly adopts a calendar through `calendar_links`, referencing its
stable schedule component ID. A territorial calendar must match a declared territory.
An approved advisory returns unknown plus contact_warning; weekly baseline remains
available and no definite countdown is presented. An unapproved event is invisible.

Confirmed events require approved exact event versions and explicit closed/replace/add
effects with accountable evidence. Replace/add intervals are typed child rows; closed
has no intervals. Previous-day overnight effects are honored. Multiple applicable
confirmed effects, or a newly approved event without an approved interpretation,
produce uncertainty. Updating the shared event advances affected service sequences;
it does not mutate a service revision or silently retarget an old exact effect.
Restoration copies schedules, days, intervals, calendar links and effects into a
new revision, with fresh value-decision IDs and the same shared identity references.

## Frozen territorial taxonomy

Vocabulary and term metadata use common save/review/publish operations with kinds
`taxonomy_vocabulary` and `taxonomy_term`. Stable vocabulary/axis/code/origin identity
cannot be edited through a later metadata revision. `create_taxonomy_axis` adds an
axis to an approved vocabulary; no detailed vocabulary is loaded by migrations.

`freeze_taxonomy_release` receives an exact approved vocabulary revision, axis
presentation, exact active approved term revisions and broader edges. It requires
propose, approve and publish capabilities; this is the permitted combined self-review
path, recorded explicitly in audit. The coherent release is sealed atomically.
Children cannot be appended after sealing; edges stay within an axis and cycles fail.

`adopt_taxonomy_release` explicitly pins a frozen release for a territory/date window
with the same three-capability policy and an exact audit target. Conflicting windows
for the same axis code fail. A transition that drops terms used by approved local
services fails with taxonomy_assignment_migration_required. Existing assignments
retain their adoption/release; a new release never silently reclassifies them.
Stage nonoverlapping adoptions and explicitly revise/review affected service
assignments for a transition. No automatic migration or vocabulary synchronization
engine is included.

Services accept `classifications` containing adoption_id/term_id. Map membership,
adoption/release and released term must agree. A local copy has distinct vocabulary,
axis and term identities plus origin vocabulary/release lineage; local edits never
change the source. fork_taxonomy_release copies the exact frozen axes, terms, hierarchy and selected
evidence into new identities, records the term identity map and approves/freezes
the copy through the permitted combined self-review path. Adoption remains explicit;
real vocabulary loading remains bootstrap work.

`api.taxonomy_search(territory, selections, at_date)` expands descendants, ORs
selections within an axis, ANDs axes and returns each discoverable service once.
Selections are `{ "axis-code": ["term-uuid", ...] }`; an empty object applies only
the territory filter. The selected adoption window and pinned release are used.

## Partial translations

`register_language` registers content language tags and ltr/rtl metadata with global
propose/approve capabilities. It is not an app UI catalog. `prioritize_language`
requires territorial propose/approve capabilities and opens work for relevant approved
originals. Territories can prioritize different dynamic languages; UI language
availability/preferences/direction remain application concerns.

`propose_translation`, `review_translation` and `publish_translation` preserve immutable
candidates, exact review and expected publication bases. Human/ai/ai_verified are
linguistic classifications, distinct from editorial approval. ai_verified requires
an AI origin/model lineage and explicit verify capability; editorial approval alone
keeps ai. Publishing a private or obsolete original fails. A historical original
still used by an adopted frozen taxonomy release remains applicable.

`api.resolve_text(content, preferred)` resolves each approved public fragment separately,
returning actual language/direction/class and original fallback. Partial translations
are valid. Unchanged original units are reused across revisions; only changed fields
fall back and signal work. `governance.translation_work` derives open/resolved/superseded
status against the exact public requirement (including adopted frozen terms);
translation_worklist supplies a controlled territorial editor read surface, while generation and old completions cannot
resolve a newer requirement. Translation history remains retained.

## Approved directory and future exports

Reader endpoints include service_detail, directory_snapshot, reference_closure,
opening, taxonomy_search and resolve_text. Reader views expose approved territories,
taxonomy, locations, organizations, whitelisted source attribution, weekly hours and
public sequence. Private/source/governance tables and translation work are inaccessible.
No internal actor, raw evidence payload, conflict or artifact locator is serialized.

`service_detail(service, preferred, instant, review_after)` includes public shared
heads, labelled explicitly relevant contacts, scoped hours/verification, cost/access,
places/areas, classifications, languages, coverage and source attribution. Defunct
services retain direct access. A contact can have multiple explicit purposes without
cross-multiplying entries. Shared contacts include checks from their actual current
revision, not a fabricated verification on the service.

Verification is separate from edits/imports. Missing checks warn; old checks remain
visible. Numerical aging policy is still unselected: review_after is optional explicit
caller policy, and omission returns threshold_not_configured. No threshold is seeded.

`directory_snapshot` returns one consistent statement snapshot, monotonic sequence,
discoverable services, pinned taxonomy/edges, territory and shared reference closure.
Unknown opening is excluded only when the explicit only_open filter is requested.
Related publications, translation changes and current scoped verifications advance
affected resource sequences atomically. Draft verification does not alter public state.
For multiple statements, callers must use a consistent read-only transaction snapshot.

Reference closure includes shared/parent locations, organizations and location roles;
territory references carry approved metadata or an identity-only unpublished marker.
A future offline exporter must apply its consumer contract to those markers and exact
IDs; this JSON response is not a completed SQLite package. api.export_manifests retains
future format/schema/policy/sequence/territory/language/checksum lineage, with no app
reader table privilege or exporter write role selected yet. HSDS mapping/defaults and
invalid-record exclusion remain described in the approved schema proposal; no HSDS
conformance or serialized package is claimed.

Sqitch revert destroys structural tables and may fail if retained component identities
would violate the older type contract. It is verified only on disposable fixtures;
production recovery requires backups and reviewed data handling. Editorial restore
is the safe retained-history operation and is verified separately here.
