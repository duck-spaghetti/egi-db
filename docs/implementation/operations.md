# Revision operations — checkpoint #1–#4

## Aggregate input and stored data

`governance.save_revision(kind, entity, expected_work, expected_public, body, reason)`
returns a saved revision UUID. Null entity creates a new identity; existing edits
provide the exact working and public heads observed by the caller. The body is a
transaction input object; canonical content is stored in typed relational tables,
not a JSON canonical record. Unknown top-level fields and non-string text fields
fail rather than being silently discarded.

All entity kinds accept name, original_language, contacts, territories and evidence.
Organization additionally accepts description, organization_type and website.
Location accepts location_kind, latitude/longitude, coordinate_state,
selected_geocoding_result_id, parent_location_id, addresses and organizations.
Service accepts description, delivery_mode, operational_status, cost_state/cost_note,
validity/closure fields, place, organizations, conditions, contact_links, languages
and coverage. Territory accepts code, timezone_name, country_code and boundary_wkt.

Contact entries include channel_type/value, optional normalization/purpose/label,
sort order, public flag and an optional stable component_id. Service contact links
identify an explicit target entity/contact component, with optional local label and
purpose. Organizations have organization_id/role_code; access conditions have kind,
required/not_required/conditional/unknown state and original details. Place is one
location_id or an area_description with optional territory_id. Coverage is separate
from map membership and access requirements. Territory lists define editorial scope;
for services they also populate explicit map membership. Shared entities retain
independent content and approvals. Creating a territory requires a global grant.

Supply existing component IDs to retain logical ownership across revisions. A
component cannot transfer to another entity or change kind. Original text is reused
by owner/field/component/language/value; explicit revision bindings preserve
unchanged translation applicability for the later translation slice.

Evidence is an object keyed by scalar field; `record` is an explicit fallback for
fields supported by one whole-record assertion. Each evidence array identifies
assertion_id and supporting/contradicting/context role. Components can override with
their own evidence array. Every supplied scalar/component receives a traceable
manual selection decision and reason; absent/default unknown values do not claim
verification. This interface does not execute automatic matching/selection policy.
Raw source assertions, captures and processor versions remain immutable evidence.

## Review and publication

`review_revision(revision, expected_public, outcome, reason)` returns a decision UUID.
`publish_revision(revision, approved_decision, expected_public)` returns a publication
UUID. Approval belongs to that exact saved revision/submission; a later negative
review supersedes it. Both operations validate expected heads and current capabilities.

The user confirmed that the same editor can propose/approve with both capabilities
for every involved territory; proposal capability is rechecked on self-approval.
All scopes include working/public territory declarations and affected approved
services referencing shared data. Empty/unscoped work requires an explicit global
capability. No role can authorize itself by selecting a UI territory.

Service publication requires nonempty name/description, valid delivery mode,
supporting evidence and usable access: a public direct or explicitly linked channel
for remote offers, or an identifiable approved location/meaningful area context for
physical offers. Unknown hours/provider/cost stay representable. Missing information
remains in draft; structured diagnostics identify the field and failure code.
Publishing shared content validates affected published consumers and rolls back if
it would invalidate an existing contact/place reference. It never falls back to a
pending shared revision. Heads, publication history, affected change sequence and
audit advance in one transaction.

Minimal approved service/contact/verification views demonstrate this checkpoint.
Defunct services retain direct access and leave ordinary discovery. The user confirmed
that temporarily_closed services stay discoverable with their explicit status.
The full app projection, translation selection and future export lineage belong to #9.

## Restore and verification

`restore_revision(source_revision, expected_work, expected_public, reason)` creates a
new saved revision, copying its owned typed payload, original bindings, components,
territorial declarations and evidence choices. It records restore origin and actor,
retains intervening history and needs fresh review/publication. Shared identities
remain linked to independently approved current heads. Verification is not copied
as a fresh check. The first-group inventory is extended by the #5–#9 registry for hours, calendars
and pinned classifications. Read [directory operations](directory.md). Translations
remain attached to original units; unchanged/restored units reuse applicable history.

`verify_revision(revision, scope, field, component, checked_at, method, evidence, outcome)`
records one page, field or component check on a saved revision. A component/field must
exist in that revision. Checking a phone leaves hours unverified. Future-dated checks
fail. Historical verification is retained. Public projections expose missing/old checks;
numerical aging thresholds remain unselected caller policy.

## Errors and boundaries

Expected-base conflicts use SQLSTATE 40001 with stale_base/stale_submission. Capability
failures use 42501. Structural/completeness failures use 23514 and explicit diagnostic
messages; immutable records use 55000. Unsupported input and unsupported write
isolation use 22023. FK/unique errors identify their actual constraint.

Do not retry a stale-base mutation blindly: reload the approved/draft state and review
the conflict. A failed transaction leaves heads, audit and public sequence unchanged.
The first group is delivered to dev; hours/calendar, taxonomy/translation and public
reads are implemented in the subsequent local checkpoint. No automatic merge engine,
live source loader, HTTP endpoint, exporter or SQLite file is delivered.
