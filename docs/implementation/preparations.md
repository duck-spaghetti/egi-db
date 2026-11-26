# Private Community preparations

`014_preparations` implements EGI-100, the first provider contract for Community
text insertion. It is additive to B3.1 candidate 013; this is a candidate milestone
branch, not an accepted release or deployment to a shared database.

## Boundary and identity

The existing editorial login must call `access.verify_session` in the same
transaction before any preparation function. Preparation functions recheck an
active account and enabled actor. The source must already exist in
`sources.registry`; recording input here never makes its content available through
source catalogue tables. Source registration/admission is a separate ticket.

Only the owner and explicitly invited active people can read a workspace. There
is no implicit Admin access. Named grants are `read` or `edit`; only the owner
changes them. Editors can save cards, but cannot share the preparation. Revocation
is checked before reading history/input or replaying a saved request receipt.
Deactivating the owner freezes modifications, including those by invited editors;
it does not transfer ownership. The editorial role has schema USAGE and explicit
function EXECUTE, with no private table SELECT, INSERT, UPDATE, DELETE or TRUNCATE.

## Functions delivered

- `create_workspace(source,title,key)` returns a metadata envelope, empty items
  and job summaries. The title is 1–200 characters after trimming for validation.
- `list_workspaces(include_trash)` and `read_workspace(id)` return only authorized
  work. The latter includes current card payloads; raw original input is separate.
- `set_grant(id,actor,permission,expected,key)` is owner-only. NULL revokes;
  expected is the metadata counter. It returns a small revision/access receipt,
  without copying private card values into request logs.
- `put_input(id,expected,kind,bytes,attestation,key)` retains exact original UTF-8
  bytes and SHA-256. This first milestone accepts `text` only, up to 50,000 Unicode
  code points excluding an optional leading BOM. CSV requires the later milestone.
  Attestation is a JSON boolean (`true` means the operator declares a public source);
  it records the actor and does not itself establish AI eligibility or admission.
- `read_input(id,input)` returns metadata plus `original_base64`; decoding restores
  exact BOM, line endings and Unicode bytes. It cannot read another workspace's input.
- `create_items(id,input,NULL,[{"creation_key":"<uuid>"}],key)` creates a manual
  empty review card for the current input. Reusing the creation key returns the same
  logical card, even under a new request key. Job candidate selection arrives in
  the durable-job/result-application tickets; non-NULL job IDs currently fail closed.
- `read_item(id,item,version)` returns an authorized immutable version; NULL selects
  the current head. A foreign item/version cannot be joined into this preparation.
- `save_items(id,changes,key)` takes 1–1,000 unique
  `{item_id,expected_version,payload}` entries. It atomically validates/appends all
  versions or rolls the whole operation back. Successful results contain operation
  and before/after version IDs, with no raw input or card values in operation logs.

Payloads use approved `item.v1`: required `schema_version:1`, `service`, `location`,
`target`, `field_origins`, `evidence`, and `outcome` (`review`, `confirmed`, `trash`).
The service/location component key sets follow the frozen B3.1 aggregate grammar;
canonical `evidence` arrays are not accepted inside these private bodies. Missing
facts can be saved; preparation validity is not canonical/publication completeness.
Submission and acceptance provide the stricter checks in their own tickets.

A stated quote must equal its retained text slice exactly. Span offsets count
Unicode code points, start-inclusive/end-exclusive, after excluding the optional
leading BOM; CRLF is preserved. Foreign input IDs, wrong hashes/quotes, duplicate
evidence IDs and unknown JSON keys fail. Changing a field cannot carry forward the
same source citation unchanged; the operator must remove or explicitly reassess it.
No provider call, canonical save, source assertion or publication occurs here.

## Concurrency and retention seam

Workspace writes lock only their workspace row, not the global canonical-write
lock. Metadata counters and immutable card version UUIDs are distinct preconditions.
A stale expected value raises SQLSTATE `40001`; request-key reuse with a different
operation/body also conflicts. Identical retries replay the original receipt after
current authorization. Creation serializes just its actor/request-key pair before
there is a workspace row. SQL errors roll back their operation and receipt together.

Original inputs and card versions reject UPDATE/DELETE even by the schema owner.
The app has no way to disable these guards. History/undo and the guarded 30-day
trash purge are implemented by EGI-101, not by this migration. Migration revert
refuses while any preparation exists, rather than deleting user work.

## Verification record — 2026-11-26

Native PostgreSQL 18/PostGIS disposable checks exercised migration deploy,
structural privilege/search-path verification, contract `17-preparations.sql` and
revert/redeploy. The fixture covers role/session isolation, read/edit/revoke,
uninvited Admin, exact BOM/emoji/CRLF round trip, invalid UTF-8 and text limits,
manual card idempotency, request replay/conflict, immutable old versions,
cross-workspace IDs, atomic rollback, quote mismatches, stale edits and owner freeze.

The full regression result is recorded with the ticket commit. The installed
Sqitch executable references an absent Homebrew Perl interpreter, so native psql
executes the actual plan SQL in order: Sqitch CLI/registry compatibility remains
unverified. This does not claim a shared/production deployment or live-provider test.

Final EGI-100 check: all native SQL contracts `00`–`17`, canonical concurrency,
structural verification and full direct-psql revert/redeploy passed twice. Diff
self-review covered the approved access matrix, server-side identity, isolation,
CAS/replay and immutable evidence. The whole-set independent review remains at
the combined milestone boundary; the ticket is not user-accepted or Done.

## History and trash — 015 / EGI-101

`read_history(workspace,item,after,lim)` paginates immutable versions in ascending
version-number order, with associated operation receipts, next `after` and
`has_more`. Limits are 1–100; current access is required even for old versions.
`undo_operation(workspace,operation,key)` first checks every affected current head.
It appends compensating versions only if all still match; a later edit produces
`undo_head_conflict`. Undoing creation trashes the card. Undoing undo is another
compensation. No original input, version or submitted snapshot is rewritten.

`trash_workspace(workspace,expected,key)` and
`restore_workspace(workspace,expected,key)` are owner-only metadata-CAS operations.
Identical request receipts replay across the state change. Shared editors can
trash/restore individual cards through versioned `save_items`, but cannot trash
the whole workspace. Read-only access cannot mutate. Workspace trash blocks saves.
Restore is allowed strictly before `trashed_at + 30 days`; at or after that boundary
both item save/undo recovery and workspace recovery fail. Sharing is preserved on
restore but grants never bypass account/session activation checks.

`purge_trash()` is executable only by a separate login directly granted the existing
`egi_retention` role. It rechecks that login internally and locks eligible workspace
rows with SKIP LOCKED. The role receives no private table read/write privileges.
DELETE exceptions in the immutable-row trigger check the retention login, elapsed
trash window and absence of current-head/input dependents; UPDATE remains forbidden.

Whole-workspace purge clears current input and private items, all card versions,
original bytes, operations and grants. It leaves an inaccessible `purged` workspace
with a fixed `Deleted` title, original trash time and opaque request/digest receipts;
request result payloads are erased. Every preparation reader and mutation returns
not-found for that tombstone, so a retry/late result cannot recreate its content.
No access or ownership transfer occurs. Individual expired cards are removed while
active sibling cards/current unsent text keep their inputs. Old unreferenced inputs
may be deleted; inputs still referenced by any surviving item/version are retained.

There is no job table in 015. Its private no-op `purge_job_payloads` hook is replaced
by EGI-103's cancellation/payload-cleanup implementation before jobs can exist. That
ticket must verify late usage settlement without result resurrection. Immutable
editorial snapshots and billing tables introduced by later tickets must remain
independent of this private deletion path. No production backup-expiry guarantee
or installed scheduler is included.

Contract `18-preparation-history.sql` uses controlled owner fixture timestamps to
exercise compensation/replay/conflicts, pagination, reader/editor/owner permissions,
card and workspace restore, 29-day retention, 30-day refusal/purge, immutable-row
exceptions, input preservation and inaccessible workspace tombstones.

Final EGI-101 check: native SQL contracts `00`–`18`, canonical concurrency,
structural verification and complete direct-psql revert/redeploy passed twice.
The runner's summary string still says `00–17`; its enumerated files and lifecycle
include `18-preparation-history.sql` in both cycles. Sqitch CLI remains unavailable
for the interpreter reason above. Self-review covered locks, role isolation,
retention guards, idempotence, immutable history and deletion independence. Job
late-result integration remains explicitly assigned to EGI-103.
