# Frozen workbench plans

Migration 031 persists immutable plan versions, shared contexts, packet manifests,
packet-to-existing-job links and append-only lifecycle events. It introduces no
second budget ledger. Migration 032 owns explicit start, queue dispatch and durable
result coverage. Existing extraction v1/v2 functions remain unchanged here.

An editor calls `preparation.preview_analysis_plan(workspace, selected_item_ids,
configuration_version, followup_limits, request_key)`. Selection accepts one to 100
unique current cards in one preparation and current publicly attested text input.
The configuration must be the currently enabled immutable configuration and contain
an actual effective published adopted classification catalog. Preview freezes the
selection, eligible-input projection, taxonomy, shared context and bounded packets;
it creates no job, reservation or provider request. Exact replay returns the same
plan. Reusing a request key after a selection/configuration/limit change fails.
Replanning uses a new visible plan identity and request key; prior plans remain
readable. Plans currently have version 1; no API mutates a frozen version.

Provider content is constructed inside the database. Only stated retained evidence
with the selected input, valid public source quote and span, and no protected
redaction overlap may contribute a basis. Category bases use original
`source_facts/*/source_value`; description bases use a quoted service description
or name. Manual/cleared fields, unquoted edits, interpreted evidence and notes do
not supply literal bases. An ineligible card remains in the frozen selection and a visible blocked event;
it contributes no required unit and cannot count as analyzed. Supports contain the owned decoded field,
its actual payload path and field-relative quote span. Full input and sibling
content are retained privately for eligibility rechecks and never enter packets.

Shared context uses fixed server instructions, eligible source registry metadata,
a validated configuration taxonomy and exact contextual label counts. Definitions
are null and aliases empty until those descriptions are maintained authoritatively.
One plan covers one territory/axis. Context identity includes the frozen selection
snapshot; its semantic scope digest is SHA256 of canonical JSON `{scope,
catalog_snapshot}`. Catalog slice, data and basis digests are distinct. A record
being analyzed in this scope does not imply completion in another axis.

The initial partition greedily packs independent records with the same source
and structure into bounded classification packets. Source identity alone does
not imply a dependency family. A dependent contextual-label comparison is declared and
budgeted when literal labels exist, then materialized after valid classification
results so its immutable request includes prior proposals. Identical labels coalesce only
within that scope, retaining each record/basis/support occurrence. Comparison
packets carry reference-only records and a separate required comparison unit.
Every packet declares required and reference units separately. The full request's
UTF-8 byte length plus 33,792 conservative framing tokens must fit its declared
input-token bound. The reserve covers up to 32,768 bytes of Reviewer instructions
and schema plus 1,024 framing tokens; this deliberately
conservative preflight may reject a large packet rather than silently truncate it.
Output preflight reserves 512 tokens per source basis or contextual label. Large
selections split into several classification packets; an individual record that
cannot fit requires explicit decomposition. An oversized comparison scope also
requires explicit decomposition rather than silently sampling its labels. Maximum packet count and sum
of worst-case configured exchange ceilings must fit
the preview limits. This ceiling is authorization, not a second reservation.

`preparation.read_analysis_plan(workspace, plan, version, offset, page_size)` reads
metadata and manifests with normal preparation authorization; page size is 1–100.
Raw private eligibility projections are excluded. Editors and workers have no
table access. `freeze_workbench_packet` is an ungranted internal persistence helper,
not an editorial API accepting arbitrary provider payloads. Migration 032 must
validate any derived later packet, enforce declared followup kinds/count/ceiling,
and project only assigned eligible packets through the existing worker lease.

Controlled native coverage is in `tests/contract/35-workbench-plans.sql`. It covers
no-dispatch preview, exact replay, key conflicts, owned selection, pagination,
source-field minimization, quote spans, immutability and function-only access.
Queue concurrency, start and uncertain dispatch accounting are tested by the
migration 032 execution fixtures. No test authorizes a real provider call.

Expired whole-preparation retention removes workbench payloads through the existing
retention hook before deleting inputs. Only the direct retention login and an
expired trash workspace permit these immutable-row deletions. Active plan history
retains its input foreign key; optional obsolete-input cleanup skips that retained
input. Normal editors and workers cannot delete or rewrite frozen plans.


Migration037 adds explicit task selection without changing existing callers.
preview_analysis_plan(workspace,selection,configuration,limits,key,tasks text[])
and amend_analysis_plan(workspace,plan,version,selection,configuration,limits,key,tasks text[])
accept exactly classify_cards, group_labels or both. The five-/seven-argument
interfaces retain both-task defaults. Tasks are canonicalized, immutable and bound
in request replay; irrelevant followup kinds are removed from the effective limits.
Changing tasks requires a new amendment identity, not reuse of a request key.

A grouping-only preview freezes one primary initial comparison request, using
literal contextual labels or explicitly materialized private interpretations and
original owned supports. Selected records are reference-only; no classification
packet, classification predecessor, implicit materialization or card edit is made.
The initial comparison consumes one request/cost ceiling and does not consume a
followup allowance. A scope with no eligible comparison labels is rejected with
grouping_scope_required. Classification-only plans declare no comparison request.
A later explicit continuation of an unfinished comparison remains bounded by the
same allowed cross_packet_comparison followup and cumulative request/cost limits.
