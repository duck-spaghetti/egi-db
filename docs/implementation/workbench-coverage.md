# Workbench execution and coverage (EGI-148)

The workbench uses the existing preparation.jobs queue, worker role, leases,
dispatch identity, monthly budget_periods and budget_reservations. There is no
second spending ledger. start_analysis_plan(workspace,plan,version,request_key)
is an explicit idempotent start of the frozen bounded plan. Every packet becomes
one job; reservation happens only at start_dispatch, under the existing workspace
and budget locks plus the plan's cumulative reserved ceiling. Unknown previous
reservations remain charged against that ceiling.

claim_job preserves the legacy envelope. For classify_cards/group_labels only,
eligible_payload is the immutable workbench.request.v1 body and locator_map is
null. The full source eligibility view stays private in the existing job row for
policy rechecks. No arbitrary editorial packet writer is exposed. Claim, dispatch,
finish and explicit materialization recheck relevant access/input/policy, source
ownership, current adopted catalog and frozen card basis. Existing extract_text
and map_csv interfaces keep their previous behavior.

finish_job accepts the workbench.result.v1 envelope and settles actual usage even
when content is rejected. Wrong outer shape/task/request digest rejects all content.
Within a correctly bound parseable envelope, duplicate IDs never choose a first
winner; foreign units, unbound supports and invalid choices earn no coverage. A
known basis lacking its explicit proposal outcome moves back to unresolved while
independently valid outcomes remain. Every processed classification basis needs
exactly one proposed/no_supplied_match/insufficient_context outcome. Proposal keys
are local to their packet. Group comparison prior alternatives are rekeyed with
packet UUIDs and preserve original bases, supports and alternatives.

Diagnostics are closed code arrays shared with Reviewer. Reasons and hypothesis
statements are bounded to300 characters. Abbreviation hypotheses remain unverified;
their trigger supports alone cannot justify a classification choice. Group choices
can cite only compared label occurrences. Unknown/mixed context or unsampled
occurrences require visible membership issues and prevent equivalent/mapping
application. No worker result confirms a private classification or a hypothesis.

read_analysis_coverage(workspace,plan,version,offset=0,size=50) returns a bounded
record page with whole-plan totals. Selected records reconcile into validated,
insufficient_context, partial, pending, blocked or stale disjoint summary buckets.
Queued/running records are pending; refused/invalid_result/uncertain/ineligible/
cancelled are blocked. Validated means all declared bases received checked scoped
outcomes, including explicit no-match; it does not claim semantic correctness.
References never satisfy required primary analysis. Current stale applicability
does not erase immutable historical outcomes or their accepted result links.

Comparison coverage is separate: selected contextual label identities, completed
and pending comparison scope keys, references, omissions and limitations. It does
not imply global pairwise comparison. A comparison is frozen only after cumulative
classification basis coverage is complete and no dispatch is pending/uncertain;
valid alternatives from incomplete predecessors remain available. Initial plans
with no contextual labels have no declared label-comparison scope. Materialized
interpretations can participate in the subsequently previewed contextual workbench.

continue_analysis_plan(workspace,plan,version,key) appends only unresolved bases,
preserving the original bounded partition and filtering absent-record supports.
The frozen allowed followup kinds/count/total packet/cost ceilings still apply.
retry_uncertain_analysis_packet(workspace,packet,key) is a separate deliberate paid
retry with a new visible packet identity; the old uncertain reservation stays held.
amend_analysis_plan(workspace,plan,version,selection,configuration,limits,key)
creates a new preview identity and an audit link; it never rewrites old plans.
cancel_analysis_plan stops outstanding work without releasing uncertain spend or
changing sent editorial snapshots. Cancelled plans cannot be continued.

select_workbench_proposals(workspace,job,item,expected_version,proposal_keys,key)
and select_workbench_hypotheses with the same arguments deliberately materialize
only that card's checked result. The server generates persistent IDs, anchors the
original same-card source version and retains existing edits. New interpretations
are proposed, hypotheses unverified; there is no body classification association
until a later human confirmation. Selecting one card does not prevent selecting
unchanged source bases on another card from the same packet. Source metadata stays
weak context, never a fabricated literal fact.

For reload, read_workspace includes latest_analysis_plan (safe identity only).
read_analysis_plan pages frozen manifests with a parallel packet_jobs link page,
safe configuration/rate/cap metadata and at most100 events. read_analysis_events
provides an explicit event-ID cursor; read_analysis_record_results provides bounded
accepted unit/result pages. Record coverage includes context digest, last event ID
and at most100 accepted packet/job/unit links with a total count. Existing read_job
returns the retained sanitized output for an authorized operator.

Native tests36 and38 exercise actual PostgreSQL workers, settlement, replay,
independent recovery, basis-level abstention, pagination, comparison dependencies,
model proposal materialization, explicit unknown retry, amendment and cancellation.
Legacy worker and category matching fixtures remain regression checks. Run them
through scripts/verify-workbench.py with the pinned resource owner, installed
PostgreSQL/Sqitch and bounded owned fixture lifecycle. No model call or credentials
are required. Structural rollback is for disposable schemas: normal user undo is
versioned compensation. Expired preparation retention removes unit results before
the plan/packet hook; selected immutable editorial evidence remains independent.


Migration037 derives classification unit states from their retained attributable
basis outcomes: no processed bases means not_analyzed; any explicit
insufficient_context proposal means insufficient_context; other explicit inspected
outcomes mean analyzed. Missing bases remain unresolved. Reconciliation normalizes
before recovery and again after independently valid bases are retained. The final
persistence validator rejects inconsistent state/diagnostic combinations; coverage
also reads proposal outcomes for previously retained units. A proposed choice with
incomplete_catalog alone is not turned into an abstention.

Coverage exposes analysis_requested, comparison_requested and selected_record_count.
For grouping-only plans, each reference record has state:null and
reason:analysis_not_requested, and every classification summary count is zero;
selected_record_count and the comparison scope retain the actual selected denominator.
Classification-only records expose comparison_state:not_requested. Progress derives
from the latest non-revoked job attempt for every declared task/unit, so queued or
running comparisons keep running, unknown comparisons wait for explicit retry, and
pre-dispatch comparison budget failures expose waiting_budget. Historical revoked
unknowns retain their spend reservation without blocking a successful replacement.
Terminal comparison abstention remains visible even when the supplied scope finishes.

Native contract45 verifies task replay/amendment, primary grouping with zero
followups, absence of hidden classification, zero unrequested analysis credit,
classification-only scope, false analyzed state over explicit abstentions,
queued/running/unknown comparison lifecycle, explicit retry, monthly budget refusal,
explicit continuation and final abstention. The owned run through037 passed the
full Sqitch deploy/verify/revert029/redeploy/reverify cycle and teardown; native43
also passed unchanged. Evidence: /private/tmp/egi-cw1-db-037-workflow.log and
/private/tmp/egi-cw1-db-037-first.log. These are synthetic PostgreSQL tests with no
real provider transport, credentials, semantic pilot approval or deployment.
