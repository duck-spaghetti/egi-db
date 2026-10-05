# EGI draft app: database-facing contract inventory

Date: 2026-10-05. Status: observed draft evidence and design questions, not an approved API or database specification.

## Evidence boundary

Original reference repository: `/Users/marco-macbook/dev/personal_projects/egi-app`. All app paths below are repository-relative and were inspected with `git show` / `git grep` at `origin/wip`, commit `c090950874a8c5ac39c83f9ba2aa1ae06356af84`. No checkout, configuration, dependencies, database, or original source files were changed. `git status --short` was empty during inspection. This inventory documents code behavior without executing the app against a database; ORM declarations do not prove the deployed schema or grants.

Source data evidence is a separate working-tree snapshot, under `/Users/marco-macbook/dev/egi/sources/egi-sources-roma`; the source paths in section 8 are relative to that root and have no Git-ref assertion. Only CSV headers, representative rows and existing SQL were inspected; PDF/XLSX/KML contents were not exhaustively inspected.

## 1. Routing and generic entity contract

Sources: `app/backend/main.py`, `app/backend/api/__init__.py`, `app/backend/api/entities/{core,taxonomy,i18n,poi,gov,audit,crud}.py`.

All entity routers mount under `/api`. For every resource below, generated methods are `GET` and `POST` on its collection, and `GET`, `PATCH`, `DELETE` on `/{item_id}`. A schema index at `/api/{schema}` returns resource names, underlying tables, primary-key names and all column names.

| Prefix | Resource paths | Underlying tables |
| --- | --- | --- |
| `/api/core` | `languages`, `areas`, `organizations` | same plural names |
| `/api/taxonomy` | `categories`, `subcategories`, `tags` | same plural names |
| `/api/i18n` | `category-translations`, `subcategory-translations`, `tag-translations` | corresponding underscore names |
| `/api/poi` | `places`, `services`, `service-hours`, `service-subcategories`, `service-tags`, `place-contacts`, `service-contacts`, `sources` | corresponding underscore names |
| `/api/gov` | `users`, `submissions` | same plural names |
| `/api/audit` | `changes` | `changes` |

Generic collection reads default to `limit=100`, maximum 1000, `offset=0`, `sort_by=id`, `sort_order=asc`, `include_inactive=false`. Tables with `is_active` exclude inactive rows unless requested. All scalar column names can be exact query filters; unknown filters and geometry filters are ignored. Empty strings convert to null. Invalid sorting names fall back to first primary-key column. There is no total-count envelope or cursor. Single-row reads do not apply the active-row filter.

Request schemas are dynamically inferred from ORM columns; extra fields are ignored. Required create fields are non-null columns without ORM/server defaults. Create ignores single-column primary keys; composite keys are accepted. Patch fields are optional, including nullable request values for database non-null columns; keys are ignored. Serialization returns every ORM column, no relationships. Decimal values become strings, dates/times become ISO strings, geometry becomes GeoJSON. Thus generic `gov/users` exposes `password_hash`, email, properties; generic `poi/sources` exposes `raw_payload`; generic audit/submission resources expose snapshots, diffs and submitted payloads. No authentication/authorization dependency is present in the inspected entity route or session code: actual deployed DB grants remain unknown.

`service-subcategories` and `service-tags` identify items with comma-separated pairs in declared primary-key order. Deleting tables with `is_active` soft-deletes; all others physically delete. Every mutation commits independently; there is no generic multi-entity transaction endpoint. This behavior is evidence, not a recommended future governance contract.

Taxonomy aliases: `subcategories?category=` or `category_slug=` accepts numeric category IDs or normalized category slugs. `tags?tag_type=`, `type=` or `kind=` matches flat tag slug prefixes, because ORM Tag has no type column. This is a draft workaround, not reliable typed taxonomy semantics.

## 2. Public API projection

Source: `app/backend/api/public/router.py`.

### GET `/api/public/services`

Required `area_id>0`; `language` length 2–8 defaults to `it`; `limit` defaults to 2000, maximum 5000. Language normalizes to lowercase prefix before `-` and resolves an active language. Queries Service joined to Place and Category. Conditions: Place area equals requested area, active Place, Place status is not `hidden`, active Service, Service status is not `hidden`, active Category. Rows sort by descending Service ID. Consequently pending rows are public in the draft; validity dates are not used to filter future/expired services. Area existence/active status is not checked. There is no viewport, radius, text, category, changed-since, offset/cursor or single-service public endpoint.

Response is an untyped list of dictionaries. Exact fields:

- Service: `id`, `place_id`, `category_id`, `subcategory_id`, `name`, `description`, `cost_tag`, `cost_note`, `valid_from`, `valid_until`, `status`, `is_active`, `properties`, `created_at`, `updated_at`.
- Embedded `place`: `id`, `area_id`, `organization_id`, `name`, `address`, `address_normalized`, `geometry`, `is_protected_address`, `status`, `is_active`, `properties`, `contacts`, `sources`.
- Embedded `category`: `id`, `slug`, localized `label`, localized `description`, `color`, `sort_order`, `is_active`.
- Embedded primary `subcategory` or null, and additional `subcategories`: `id`, `category_id`, `slug`, localized `label`, localized `description`, `sort_order`, `is_active`, `properties`.
- `hours`: `id`, `weekday`, `opens_at`, `closes_at`, `is_24h`, `note`; sorted weekday/open time/id. Public times are truncated/formatted `HH:MM`.
- Service/place `contacts`: `id`, both `type` and `contact_type`, both `value` and `contact_value`, `label`, `sort_order`, `is_active`. Only active contacts are included.
- `tags`: `id`, `slug`, localized `label`, localized `description`, `sort_order`, `is_active`.
- Service/place `sources`: `id`, `entity_type`, `entity_id`, `source_type`, `source_name`, `source_url`, `source_ref`, `source_license`, `retrieved_at`, `is_primary`, `is_authoritative`, `notes`; raw payload excluded. Sources sort primary, authoritative, ID.

Taxonomy translation lookup falls back to raw slug if the requested language/translation is absent. It does not implement a second-language fallback or review requirement; unreviewed AI-generated taxonomy labels may be returned. Names/descriptions/cost notes/hour notes/contact labels are not translated.

Protected addresses: draft suppresses `address` and `address_normalized` only. It still returns exact Point geometry and arbitrary place/service properties and source URLs/notes. This does not establish a safe public/offline redaction policy.

Hours, contacts, sources, subcategories, tag links and translations are treated as optional only for PostgreSQL privilege error `42501`: the session rolls back and omits their data, with a warning. Missing tables and other DB errors fail. Partial-success payloads have no completeness/error marker. Core service/place/category queries are mandatory.

### GET `/api/public/areas`

Active areas ordered by name. Fields: `id`, `slug`, `name`, `country_code`, `admin_level` (always null in this endpoint despite ORM column), `default_zoom`, `is_active`, `default_center` Point GeoJSON, `geometry_bbox` Polygon GeoJSON. No area-type restriction. The public frontend calls these entities cities even when they represent other extents.

### GET `/api/public/languages`

Active languages ordered by `sort_order`, English name. Fields: `id`, `code`, `name_native`, `name_english`, `direction`, `is_active`, `sort_order`.

## 3. ORM entity/relationship inventory

Sources: `app/db/models/{core,taxonomy,poi,i18n,gov,audit}.py`.

Single-row identities are BigInteger primary keys. Most business tables have timezone-aware `created_at`, `updated_at`; defaults use server now while updates use ORM `onupdate`, which alone does not establish database-trigger coverage. Most extensible business objects use non-null JSONB `properties={}`.

| Table | Fields beyond timestamps / significant constraints |
| --- | --- |
| `core.languages` | `id`, unique `code` varchar(8), required native/English names, direction `ltr/rtl`, active, sort_order; no timestamps |
| `core.areas` | `id`, unique slug(80), name(160), country_code(2), nullable admin_level in province/metro_area/region/country/city/district; optional Polygon bbox and Point center SRID4326, default_zoom=11, active=false, properties; no parent/hierarchy/timezone |
| `core.organizations` | `id`, unique slug(120), required legal_name(255), optional display_name/type/website, partner flag, active, properties; type nonprofit/public/private/association/cooperative/foundation/informal |
| `taxonomy.categories` | `id`, unique slug(120), optional color(32), sort_order, active; no icon or area or hierarchical parent |
| `taxonomy.subcategories` | `id`, required category FK, slug(120), unique `(category_id,slug)`, sort_order, active, properties |
| `taxonomy.tags` | `id`, unique slug(120), sort_order, active; no tag_type or axis |
| `poi.places` | `id`, required area FK, optional organization FK, optional name/address/address_normalized, mandatory Point geometry SRID4326, protected-address flag, status pending/published/hidden (pending default), active, properties |
| `poi.services` | `id`, mandatory place FK and category FK, optional primary subcategory FK, optional name/description; cost_tag free/low_cost/paid/donation/variable (free default), cost_note; optional date validity range checked ascending; publication status pending/published/hidden; active, properties |
| `poi.service_hours` | `id`, required service FK cascade, ISO weekday1–7, time opens/closes optional only for is_24h=true, note(255), unique `(service_id,weekday,opens_at)`; no timezone, schedule type, exception date, explicit closed/unknown state, validity period or provenance |
| `poi.service_subcategories` | composite service/subcategory PK; service deletion cascades; no same-category constraint |
| `poi.service_tags` | composite service/tag PK; service deletion cascades |
| `poi.place_contacts`, `poi.service_contacts` | id, required owner FK cascade, type phone/email/website/whatsapp/telegram/fax/social, value(255), optional label(120), sort_order, active; no contact person/availability/language/provenance |
| `poi.sources` | id, required entity_type place/service and entity_id without FK; source_type osm/scrape/partner/manual/csv/api/import; name(120), URL(500), ref(255), license(80), required retrieved_at, optional raw_payload JSONB, primary/authoritative flags, notes; no source catalog, file snapshot, ingestion/resolution run or field assertion |
| `i18n.category_translations`, `subcategory_translations`, `tag_translations` | id, owner FK cascade, required language FK, required label(120), optional description, is_ai_generated, reviewed_at; unique owner/language; no reviewer, generation model/version or source-text revision |
| `gov.users` | id, unique required email(255), email_verified_at, optional password_hash/display_name, role new/contributor/trusted/moderator/admin/partner/banned, optional primary_area and organization FKs, active, properties, last_login_at |
| `gov.submissions` | id, submission_type create/update/delete/restore/flag; required entity_type string, optional target_entity_id without FK; optional submitter/reviewer FKs, status pending/approved/rejected/needs_changes/withdrawn/duplicate, priority1–10, area FK; required JSONB payload, optional payload_diff, reviewer_decision_at/note, parent_submission FK, properties |
| `audit.changes` | id, entity_schema/table strings and entity_id integer without target FK, operation insert/update/delete/restore, actor user FK, actor_type user/system/import/api/migration, source string and numeric source_ref, diff/full_snapshot JSONB, created_at; no updated_at |

Relationships imply Area has many Places; Organization has many Places; each Place has many Services. A Service cannot be directly attached to an Organization, multiple Places, no Place, an online channel or a coverage polygon. Service hours/contacts/taxonomy links are subordinate collections. Users have one role, one primary area, one organization; multi-area moderator membership is not represented. Submissions form parent/child threads; no approval-to-canonical-write behavior is implemented. Audit target format cannot directly describe composite-key associations. No inspected event listener or API service auto-creates audit entries.

## 4. Frontend requirements evidenced by actual calls

Sources: `app/frontend/static/js/{entry,map,i18n}.js`, `app/frontend/static/app.js`, `app/frontend/templates/{entry,map,index}.html`, `app/backend/api/pages/router.py`.

Entry wizard loads public areas and languages. Map route takes `city_id` and `lang`; server page context uses area Point and bbox extrema, default zoom. The server fallback uses `scalar_one_or_none` on all active areas without a limit: multiple active areas would raise a multiple-result exception, contradicting intended multi-area expansion. It is draft incompleteness, not a single-area requirement.

Map fetches generic categories and category translations (limit1000), public areas/languages and public services for area+language (limit2000). Category visibility is filtered client-side using optional `category.area_id` absent from ORM. Categories can carry `icon_path` in frontend expectations, absent from both public serializer and ORM. Map/list filters categories locally and sorts local Haversine distance if user location is known; nearest area selection is also client-side. Browser geolocation is transient frontend context, not an observed persisted user-position requirement. Transport-stop UI exists but `transportStops=[]`; no transport API/table contract is established.

One marker/list/detail item is a Service ID with Place point. Title falls back service.name → place.name → generic Service. Display includes category/subcategory, address, description, hours, merged service+place contacts, cost, tags; primary source URL is selected from service primary → first service source → first place source. Contacts are converted to call/email/site/social links and deduplicated in presentation. Exact geometry is used for marker/directions even for protected addresses. Numeric ID conversion is widespread in JavaScript; switching API identity to UUID/string requires explicit frontend adaptation.

Service content translation UI is present but `normalizePublicService()` forcibly sets `original_language=null`, `translations=[]`. Actual API has no service translation table/endpoints. UI-shell translation files exist for Italian, English, French and Arabic; this is separate from database data translation.

Opening calculation uses browser local time and weekly ISO weekdays, supports multiple intervals and cross-midnight closing (close <= open treated as overnight). Empty/absent schedules produce `isOpen=false` / Closed with a no-records note. There is no timezone/holiday/calendar handling. Unknown vs closed must be a future design decision; not evidence that missing schedules mean closed.

Contribution UI POSTs `/api/gov/submissions`, with create/service, nullable submitter, pending status/priority5, area, and arbitrary payload containing area/category/language IDs, name/description/cost, latitude/longitude/address/postal_code=null/source_url, snapshot city/category context, and details `{access_notes,cost_notes,contacts:[{type,value}],hours:[{weekday,opens_at,closes_at,is_closed}]}`. No importer or approval service consumes this payload. It contains language_id/access notes/explicit closed days that canonical service ORM does not support. Its initial cost choice is variable, whereas ORM/importer default free. Submitted user/reviewer/status fields are not protected by a dedicated server schema.

## 5. Importer shape and missing workflow

Sources: `app/backend/api/poi_importer/{schemas,helpers,router,service,dependencies}.py`, `docs/poi_bulk{,_minimal}_template.csv`.

Importer router has prefix `/api/poi-importer` but registers no endpoint; `service.py` is empty. Schemas/helpers are draft components, not a working import contract.

POIModel requires positive area_id, one Place, one Service. Place requires address and numeric lat[-90,90], lng[-180,180], optional name/protected flag/properties. Service requires category textual label/slug; optional subcategory/name/description, cost enum/default free/note and validity range. Collections include hours, contacts, nested tag/subcategory lists, sources and a raw_payload dictionary. Place has no organization ID or contact collection in importer payload. Service has no public-status field in this importer schema.

Hours use `is_24_hours` (ORM/API `is_24h`), require opening+closing unless 24h, weekday1–7, note255, no is_closed. Contact schema max value500 conflicts with ORM varchar255. Source payload lacks retrieved_at and entity target; orchestration would need to assign both. Tags/subcategories accept wrappers around nonempty lists. Full CSV template expects address/latitude/longitude/place_name/service_name/category/subcategory/description/cost fields, individual contact channels and contacts_raw, weekday/opens/closes/is_24h/hours_raw, tags/tags_raw, additional_subcategories/raw, validity dates and source ref/URL/license/notes. Minimal CSV only address, service_name, category: required coordinates and area must come from unimplemented external context/geocoding.

Helpers match active taxonomy slugs/all translation labels exactly after normalization, else RapidFuzz WRatio cutoff88; return ID/slug/name/match_type/score/matched_value. Subcategory can be scoped by category. No match returns `{}`; no entries are created. Alias collisions select the first candidate in sort order, without ambiguity output. This indicates needed match evidence and review, not an approved resolution algorithm.

## 6. Errors, security and completeness assumptions

Sources: generic CRUD and public routers, session/database files, frontend `readJson` functions.

Generic integrity failures →409; privilege sqlstate42501 →403; other DBAPI errors →500. Detail contains exception class, sqlstate and original DB message. Not-found →404; wrong composite-key arity →422. Input validation uses Pydantic but dynamic schemas omit database enum/length/check constraints; unsupported values often reach database constraints. Conversion errors on query values/key strings may escape DBAPI handling. Geometry request annotation is dictionary despite endpoint documentation promising WKT strings; Pydantic may reject WKT before converter. Exact filters cannot express ranges/geospatial searches.

Frontend logs/throws error details from JSON detail or HTTP text; no structured stable error-code contract, authorization flow, rate-limit, sync-error or data-completeness contract is established. `/health` reports ok without checking DB. One shared configured session connection serves public/admin writes in draft; database role segregation is not shown. SQLite behavior is entirely absent: PostgreSQL schemas, JSONB, GeoAlchemy and SQLstate-specific code do not transfer directly.

## 7. Legacy sample payload and SQL mismatches

Source at fixed app ref: `app/test_data.json`. It contains 201 groups and 315 services, 23 marked itinerant and 13 with empty hours. Group keys: identifier/nome/servizi. Service keys: identifier/bisogno/nome/posizione/numeri_telefono/email/orari_apertura/criteri_accesso/descrizione/prestazioni/tipologia/ente. Position has address, string lat/lng, itinerant boolean. External identifiers include non-integer IDs; prestation objects carry external id/name. Needs include documents, sleep, health, clothing/blankets, listening/support, hygiene, food, education, work.

The 44 access keys mix age bands, sex/gender/population, pregnancy, disability, migration/citizenship, addictions, housing, family composition, violence/torture survivors, legal documents, ISEE, residency, membership, assessment/intake, referrals, appointments/on-site booking, payment/contribution and language. A false boolean cannot be assumed to mean prohibited, not required, not targeted or unknown without source semantics. These groups need separate meaning and provenance, not one undifferentiated eligibility truth.

Source-tree `schema.sql` calls itself MVPv2 PostgreSQL14+/PostGIS3.x; it is existing SQL reference, not deployed evidence or the chosen future version. Differences versus fixed app ORM:

- SQL category slug80 vs ORM120, required validated color7 vs optional color32; SQL has icon_name, ORM no icon, frontend expects icon_path.
- SQL subcategory slug is globally unique, ORM only category/slug unique; delete cascade behavior differs.
- SQL tags require tag_type in access/population/modality/feature and slug80; ORM drops tag_type and uses slug120; route compensates via slug prefix.
- SQL lacks `poi.service_subcategories`; ORM/public loader expects it.
- SQL default inactive taxonomy categories/subcategories vs ORM active defaults; rendering can differ depending insertion path.
- SQL maintains updated_at with triggers while ORM contains onupdate: migration source of truth and database-side changes need explicit definition.

## 8. Representative real source data: merging and normalization constraints

Sources under the separate source root:

| Source paths | Observed columns / implications |
| --- | --- |
| `Sant'Egidio/data_output/dove_{dormire,curarsi,mangiare,lavarsi}_roma_final.csv` | Raw left/right extracted columns, title, address, transport text, contacts text, hours text, description, decimal lat/lon; curarsi also category. Source raw text and normalized fields coexist, but no source-item stable ID/locator, retrieval timestamp, license or geocode method in CSV columns. |
| `Programma Integra/data_output/servizi_migranti_normalizzati 2/Dati normalizzati-Tabella 1.csv` | Semicolon delimiter, id e.g. MAP-0001, file_origine, mappa, layer, name/address/locality/description, servizi_aiuta_per, link/email/phone, info_orari_note, contacts/courses, latitude/longitude, has_coordinates, missing fields/completeness, original description. Example has blank structured phone/email but both in raw contacts; no coordinates yet completeness100%. Reported completeness is parser-specific, not publishability. File-derived IDs need source namespace and snapshot stability checks. |
| `Roma Capitale/data_output/roma_capitale_{poi_essenziali,trasporto}.csv` | layer_type,line_or_category,name,address,lat,lon,source_url,last_update. Example transport record is a Metro line with a Rome-center Point, not an actual stop. Category/type and point semantics require classification; coordinates alone do not prove a navigable service location. |
| `1522/data_output/{centri_cav_lazio,cav_geocoded}.csv` | province,municipality,centre,address,contacts,hours; geocoded adds lat/lon and unnamed index column. Source spans Lazio beyond Rome. Exact-center publication policy must be distinct from source availability. |

Concrete examples that affect schema, from first CSV rows inspected:

- Sant'Egidio health entry separates secretariat weekday hours, Thursday membership/intake hours, and dental-service exceptions, with required photos/document and population criterion non-EU citizens in Italy at most5 years. Hours need purpose and eligibility context, not just one weekly set.
- Sant'Egidio hygiene entry has Monday/Wednesday/Friday for men, Tuesday/Thursday for women, same7:30–15:00 interval, shower+breakfast. Conditional schedules and multiple need axes must survive parsing.
- Sant'Egidio sleep entry is an association arranging temporary accommodation in third-party structures and project entry after interview; listed address can be intake/referral office, not sleeping facility.
- 1522 first entry has a telephone marked h24 but office opening times. Friday raw19:00–15:00 is ambiguous/error-prone; do not silently transform it into an overnight canonical interval. Preserve raw statement and resolution status.
- Programma Integra first entry CPIA2 has structured contact columns empty despite raw phone/email and source link; reprocessing must improve extraction without discarding original capture.

Cross-source normalization implications (proposals, not approved tables): preserve immutable captures and row/document locators, raw address and raw coordinate strings alongside normalized address and nullable validated scalar longitude/latitude; attach geocoder/provider/version, method, confidence/precision and timestamp when produced. Do not invent missing coordinates or infer centroid accuracy. Store source namespace+external key separately from canonical identities. Multiple captures may claim one canonical place/service or distinct services at the same place; organization name, shared phone, address proximity alone cannot dictate merge. Match runs need algorithm/version/parameters, candidate evidence, decision actor, reversibility and explicit rejected/ambiguous/conflict outcomes. Field/contact/hour/access assertions need source-specific value and validity/retrieval times plus links to selected canonical values. Differing statements can both be true for different service types, populations, periods or contact purposes.

## 9. Implications for the proposed public SQLite export

These are planning proposals from observed needs and the user's brief, not existing implementation:

- Define one canonical PostgreSQL dataset, with SQLite as read-only public projection. Export semantic scalar latitude/longitude and public area geometry/bounds independently of PostGIS storage; no requirement to emulate every private schema in SQLite.
- Stable export identity and referential links must survive builds, canonical merges and replacements. Existing integer-ID frontend usage is an adaptation constraint, not a mandate for canonical integer identity.
- Public output should satisfy a documented publication predicate, redaction policy and license policy. Generic governance/auth/audit/raw-ingestion tables should not automatically become offline data. Public source attributions may still be necessary.
- Define release ID/schema version/source dataset cutoff, area/language selection, build time, expiry/freshness, row counts/completeness, checksums and minimum app compatibility. Draft's max5000 endpoint is not an export mechanism.
- Unknown schedules and costs need explicit public semantics; browser timezone cannot determine multi-area services correctly. Offline client needs timezone/exception information or precomputed honest display semantics.
- Incremental sync/tombstones, offline queued edits and geo-search indexing remain decisions; read-only offline browse does not imply offline governance/write sync.

## 10. Blocking design questions for the interview

1. What is a canonical Service: a provider's offer reused across locations, or a specific offer at one location? Can organization be unknown temporarily, and can services be online/mobile/referral-only? Distinguish service coverage from project/map edition geography.
2. Which publication predicate is authoritative, and who approves data? Separate editorial approval, operational availability, freshness and privacy. What precise/coarse/no coordinates may be public for sensitive services?
3. Which eligibility claims are requirements, targeted populations, accepted populations or accessibility features? How represent unknown, explicit no, conditional logic, source disagreement and supporting text? Gender-dependent hours show this cannot always be a flat tag.
4. What wins a source conflict, and can a human override be permanent or time-limited? Do field assertions need review independently, and how are merges/splits reversed when the resolution algorithm changes?
5. Which schedules are for physical visits, a specific service, phone contact, appointments/intake or exceptions? Which timezone/holiday rules apply? What does absent hours mean publicly?
6. What multilingual service fields must be available, which languages, what fallback/review policies, and how stale translations track a changed original?
7. Which identities are shared across canonical DB, source records, HSDS export, API and SQLite? Are original external IDs and merged aliases preserved publicly?
8. What geographic relationship should services have to overlapping editions, administrative boundaries and actual service areas? Draft single Place.area_id cannot model all three.
9. Should contact details/addresses/hours/access be separately versioned canonical components with per-field sources? Which evidence/attributions are public vs governance-only, including protected-location sources?
10. Which offline package scope/retention/redaction guarantees are required, and how are deleted/hidden public records retired from installed snapshots? What API compatibility obligation exists to this reference draft versus a redesigned app?

## Approved brief versus remaining proposals

Parent-provided user brief establishes PostgreSQL/PostGIS, Sqitch structure management, later data bootstrap, expansion beyond Rome, separate English schema names, one canonical dataset and later SQLite public read-only export, scalar coordinates independent of PostGIS, detailed multi-source field provenance with conflicts/reprocessing and evolving algorithms. Future taxonomy is multi-axis/hierarchical and designed separately. The observed draft schemas/endpoints/enums, conflict algorithms, identity strategy, publication rules, governance roles, HSDS mappings and table layout are not approved merely because they exist in reference code.
