# Durable interpretation jobs and selected candidates

Changes 017–018 implement EGI-103's private job provider and complete the approved
job-to-card SQL boundary needed by the later app consumer. They add no provider
credentials, live configuration, external request, real worker login or deployment.
A selected candidate remains a private card; it is never a canonical service.

## Configuration and budget

The environment owner installs an immutable `ai_configurations` version only after
model, token bounds, current prices and data settings have been reviewed. Its
`provider_config` contains non-secret adapter configuration. Credentials belong to
the app environment, never this table. No version is seeded by deployment.
`ai_settings` selects one enabled version; without it requests fail `ai_not_configured`.
Changing the active configuration prevents older leased jobs from dispatching.
Neither editorial nor worker roles can edit configuration or the budget ledger.

Rates are integer micro-USD per million tokens. The maximum reservation is rounded
up from the frozen input/output token ceilings at the uncached rates. Under the
UTC calendar month's row lock, committed usage plus outstanding reservations plus
this ceiling must fit USD 10 (10,000,000 micro-USD). Token/configuration bounds must
be enforced by the app adapter too; this database does not tokenize prompts or
assert that an unevaluated model configuration is a safe real-provider bound.

Completion accepts nonnegative integer `input_tokens`, `output_tokens` and
`cached_input_tokens`, optional `reasoning_tokens` (already included in output)
and optional provider request ID metadata. Cached/reasoning counts cannot exceed
their parent totals. Reported tokens cannot exceed frozen bounds. Known cost is
rounded upward, moves from reserved to committed exactly once, and settles the
original reservation month even if completion is later. Invalid output still costs
its known usage. Missing/uncertain usage is not proof of zero charge: the entire
reservation remains held until attributable reconciliation. No Admin button can
release it by guessing. External account charges are outside this ledger.

## Human boundary

`request_interpretation(workspace,input,'extract_text',key)` checks edit access,
current immutable input and enabled configuration before making a durable job.
An identical active/successful eligible job is reused; uncertain, failed or cancelled
work requires an explicit new request key. Replaying an old HTTP request key never
creates another dispatch. `read_job` is authorized per preparation and exposes
only output/status/diagnostics and server candidate IDs, not lease or raw provider
exceptions. `read_workspace` includes resumable job summaries.

Only operator-attested public text can enter the queue. Restricted inputs remain
usable for manual cards. Attestation is not sufficient on its own: the private
payload builder applies the existing governance phone identity/hold rules to active
registered protections, current private canonical contacts and explicitly non-public
preparation contacts. It also removes exact private contact values. Unicode whitespace
is classified through the existing governance helper, while replacement preserves
original code-point positions. Both text and source metadata are filtered; source
codes/IDs are not needed in provider metadata. The exact redaction map is retained
with the assigned eligible payload. Unresolved global phone holds conservatively
remove phone-like spans because a new service has no established canonical scope.

The builder is private: workers cannot use it as an arbitrary original-input reader.
Dispatch and result application recompute eligibility; changed protections or input
prevent dispatch/application. Source reference URLs are metadata and never fetched.
Later Reviewer/app checks must reject evidence touching any redacted interval.

## Worker boundary and recovery

`egi_preparation_worker` is a NOLOGIN capability, without editorial/reader/writer
membership. A separate environment login directly receives it; privileged or mixed
editorial/writer/reader/sync/intake/retention/privacy logins are rejected. It has no
private-table SELECT or human-session/canonical mutation capability. Worker calls
require READ COMMITTED. Only job functions are granted.

- `claim_job(worker_uuid)` locks one queued job with SKIP LOCKED and returns its
  bounded eligible payload/configuration plus a one-time raw lease secret. The
  database retains only its hash, assigned login/process and 60-second expiry.
- `start_dispatch(job,lease)` locks workspace → job → budget period; checks active
  owner/requester/edit grant, current input, configuration and current eligibility;
  commits a unique dispatch ID and reservation before the app sends anything.
  Repetition cannot dispatch again.
- `heartbeat_job(job,lease,dispatch)` renews only a current matching lease/dispatch.
  The app heartbeat interval is 15 seconds. Cancellation, expiry or lost access
  returns false and never resurrects a job.
- An expired lease before dispatch is safely queued again. An expired dispatched
  job becomes uncertain with its reservation held; it is never automatically claimed.
- `fail_job` accepts catalogued error codes, checks actual dispatch state, and keeps
  post-dispatch cost uncertain. It does not store raw exception strings.
- `finish_job` checks login, lease and dispatch, settles known usage idempotently,
  validates the closed result envelope/body/quotes again, then stores output only
  while current access/input/eligibility allow it. An invalid/incomplete/refused
  result is not a successful candidate set. Provider-assigned canonical/component
  IDs and inferred public-contact permission are rejected.

Closing a browser/session does not revoke the persisted requester account/grant.
Revoking edit access or deactivating the owner does stop dispatch/application.
`cancel_job` and workspace trash record a durable cancellation marker. Failures,
lease expiry and late results cannot erase it. Restoring a workspace does not revive
old jobs. A fresh explicit request is needed.

Purge cancels jobs and clears input FKs, eligible text, metadata/redaction maps,
output and candidate-key maps before original inputs are deleted. Minimal dispatch,
usage, configuration and hashed lease/retry identity remain for billing. A late
completion can settle that usage, but cannot recreate any private content under the
purged workspace. Editorial snapshots are independent in their subsequent ticket.

## Explicit candidate creation/update

Successful results receive opaque server candidate UUIDs separate from the model's
local keys. `create_items(workspace,input,job,selections,key)` requires a current
succeeded job and explicit `{candidate_id,target_item_id?,expected_version?}`
selections. It never creates unselected candidates. Job/input/workspace ownership
and current eligibility are checked again. New cards get server component IDs.

A candidate application is unique per workspace/job/candidate. Repetition returns
the original card/version receipt without overwriting subsequent edits; the app
reads the current card after a receipt. Choosing another target for an already
applied candidate conflicts. Existing-target updates require its exact head.

Field-origin-aware merging preserves manual and deliberately cleared fields,
including nested manual edits within a collection. Such a collection stays intact
and returns a visible conflict path. Untouched/input/generated fields may update;
omitted provider fields never clear old data. Evidence follows only applied fields.
Canonical target/location reuse is never chosen or overwritten by the provider.
A complete selection is atomic; there is no silent partial bulk update.

## Verification — 2026-11-26

Synthetic native contracts 20 and 22 cover role isolation, public eligibility,
Unicode phone/email and source-metadata redaction, pre-dispatch recovery,
post-dispatch uncertainty, request coalescing, single dispatch, usage replay/conflict,
original-month settlement, revocation before/after dispatch, owner deactivation,
false quotes, cancellation/heartbeat recovery and late completion after private purge.
Candidate tests exercise explicit creation, repeat selection and updates that
preserve manual/cleared fields while applying untouched data.

Shell contract 21 uses two real transactions on independent workspaces competing
for the same month: one USD 6 reservation succeeds, the other is refused under the
USD 10 cap. This demonstrates concurrent ledger serialization, not a paid request.
Full-regression and lifecycle results are recorded with the ticket commit. Sqitch
CLI/registry remains unverified because its installed Perl interpreter is absent;
direct native psql executes the actual deploy/verify/revert scripts instead.

Real-provider performance, exact model/prompt/token bounds, reviewed corpus,
credentials and supervised worker installation remain later app/evaluation work.
The SQL fixtures' names/prices/token counts are synthetic and authorize no dispatch
outside their disposable database.

Final EGI-103 evidence: all SQL contracts through 22 (21 is the budget shell
contract), structural verification, both canonical/budget concurrency checks and
full native direct-SQL revert/redeploy passed twice on the final changed state.
Self-review covered worker role/lease authority, lock order, integer accounting,
privacy/redaction, immutable configuration, cancellation/retention and candidate
CAS/idempotence/manual-field preservation. Independent combined review and human
acceptance remain pending; no real OpenAI request was executed.

## Literal organization/category candidates — 024

The [v2 fact adapter](preparation-source-facts.md#jobcandidate-propagation--024--egi-114-provider-completion)
adds explicit interpretation_version configuration, matching result validation and
stable private fact materialization. Existing jobs/configurations default to1;
source facts survive v2/manual refresh and older v1 results. The persistent job,
one-dispatch lease, budget, redaction and candidate-selection operations are reused.
