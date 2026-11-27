# Community source registration and admission

`016_community_sources` (EGI-102) separates registry metadata from private originals
and from permission to use Community-derived evidence in a new publication.

`editorial.register_community_source(metadata,key)` requires the existing verified
editorial session and active enabled moderator/Admin. It accepts only `name` and
`source_kind` (required nonblank strings, maximum 200/80 characters), plus optional
`publisher` (500), `homepage` (2048), `license` (2000) and `attribution` (4000).
Optional values may be null/unknown. It stores no raw input, capture, private note,
importer profile or caller-provided source code. Codes are allocated as
`community-<source UUID>`. A homepage is retained metadata; the function never fetches it.
Registration returns `{source_id}`. It does not claim a known license, public-source
AI eligibility, source admission or publication.

Actor/request-key locking and an immutable internal registration receipt provide
idempotency: the same normalized JSONB request returns the same source; changed
content with the same actor/key raises `40001 request_key_conflict`. JSON object key
order is immaterial. Different request keys intentionally need not deduplicate
similar source names; the UI should offer existing registry sources first.

`editorial.admit_community_source(source,reason)` requires an active Admin session
and an existing registry source. A nonblank reason of at most 2000 characters is
required. The first decision is immutable; concurrent/repeated calls return that
same decision, preserving its actor, timestamp and reason. Moderators can read
admission metadata but cannot insert/update/delete it directly. No withdrawal or
suspension operation is introduced.

This ticket records the decision only. EGI-106 adds authoritative publication
checks for Community-materialized assertions, including later evidence reuse and
restore. Until that integration exists, this is not a claim that new Community
publication is enabled. Existing captures, public heads, visitor intake and legacy
source behavior remain unchanged. Private inputs stay exclusively in preparation
storage.

Verification on 2026-11-26: native PostgreSQL/PostGIS contracts `00`–`19`, structural
verification, canonical concurrency and full direct-psql revert/redeploy passed
twice. Contract 19 checks moderator registration/Admin admission, replay/conflict,
unknown/raw-content keys, non-invented license, server codes, immutable decisions
and unchanged capture/publication/intake state. Self-review covered identity,
privileges, closed metadata and transaction boundaries. Sqitch CLI/registry was
not exercised because its installed Perl interpreter is absent. No shared database,
real login, scheduler or provider call was changed.

Revert refuses if any registration receipt or admission exists, preserving user
metadata/decisions. Structural deployment seeds no source or admission; retained
synthetic source registry rows belong to tests, not migrations.
