# Scoped proposal readers and recovery (EGI-148/149)

Migration 036 completes the private workbench read boundary. Every public function
rechecks the existing workspace authorization. Workers receive none of these
editorial readers or direct tables. Page sizes are 1–100; explicit null sizes and
offsets fail rather than removing LIMIT.

- read_workbench_proposals(workspace,job,item=null,offset=0,size=50): classify
  requires its selected card; group requires null item. Returns checked proposal
  and hypothesis pages, catalog_choices with human labels/targets, frozen context,
  relevant record references and at most 100 basis/support previews. basis_total,
  support_total and supports_complete expose preview omissions. Proposals remain
  the model DTO; materializations separately reports existing server IDs/states.
- read_workbench_supports(workspace,job,item,proposal_key,offset=0,size=50): pages
  owned context support. A group requires a retained proposal key; an optional item
  narrows its actual member records. No full input or unrelated record is returned.
- read_workbench_proposal_members(workspace,job,proposal_key,offset=0,size=50):
  resolves exact GroupMember rows from frozen owned occurrences. Literal members
  use the actual source-fact identity; interpretation:<UUID> uses that existing
  private interpretation. Unresolvable occurrences are counted explicitly.
- read_group retains its existing group/member envelope and adds linked_proposal:
  retained job/packet/local-key links, relation/reason, bounded membership issues
  with total/cursor, and human catalog choices. The stored GroupRevision is unchanged.
- list_group_operations(workspace,offset=0,size=50) lists only the current actor's
  apply/undo identities and bounded summaries. read_group_operation includes kind
  and resume_request: the exact original frozen apply body or original undo/key.
  Resume never invents a key or changes a pending selection. Older rows use a
  reconstructable header only if its digest matches; otherwise resume is unavailable.

AI-linked group revisions may contain only actual retained proposal members with
their frozen versions. Operator extensions use an explicit manual revision with
proposal_id=null and lineage. Existing workspace write authorization already locks
the workspace; save_group/apply_group rely on that lock to serialize expected-head
checks and updates. Native 42 races independent owner/editor sessions with a widened
write overlap and proves one successor plus one 40001 conflict.

Group choice support may use any supplied source/metadata support owned by actual
member-occurrence records. Other packet records cannot lend support. Known, fully
supplied contexts remain necessary for equivalent/applicable proposals. One
contextual label with multiple complete distinct occurrences can form a group.
Actual public delivery/access quotations enrich context only; they create no extra
classification bases. Manual/private, normalized-but-unquoted or protected fields
are withheld, with an explicit unsupported_field context limitation. Omission means
unknown rather than absence. No full source or private interpretation prose enters
the model packet.

Existing interpretation_identities now also binds job/item/kind/request-local key.
Selecting the same output with a new request key reuses its server identity and
keeps a current confirmed/rejected decision. The no-op receipt has items=[] and
already_materialized metadata; it does not append another card version. A removed
entry is not silently restored. Different kinds cannot borrow each other's IDs.
Human group confirmation preserves AI creation method/job and stamps the selection.

Comparison scheduling merges explicit materialized alternatives with validated
live/partial outcomes, retaining original source/metadata supports. Packet-local
keys are deterministically hashed into bounded unique prior keys. Explicit unknown
replacement revokes the old content's applicability while keeping its reservation
held; late actual usage can settle without applying stale content. Superseded
unknown predecessors do not block known residual work or comparison. Paid retries
consume total-packet/cost ceilings, not the residual/comparison followup quota.

Pre-dispatch budget refusal is waiting_budget with pending records, no invalid
model result and no new dispatch/reservation. Configuration/catalog changes are
stale; eligibility changes are ineligible. Honest incomplete output leaves known
unprocessed work pending. Comparison insufficient_context is exposed globally even
on the first record page; finished scoped analysis is distinct from semantic success.
Workspace legacy job summaries now identify task and contain only legacy jobs;
new workbench jobs use the bounded plan readers. Preview metadata includes the
explicit 100-record plan limit and supplied/complete/unknown vocabulary coverage.

Focused native acceptance: 40 hypothesis proof/upgrade undo/manual reconciliation;
41 exact supports, readers, membership attribution, stable human review, AI group
apply/undo, selected v3 canonical human observations and post-purge provenance;
43 budget/unknown/partial/comparison/late usage; 44 positive public access context;
42 concurrent verified sessions. Run via scripts/verify-workbench.py with a pinned
resource-owner checkout. Shell-check logs live outside ResourceRun's reserved
child registry. SQL/model transports are synthetic; no real AI call or credential
is used. Structural rollback is disposable-schema administration, not user undo.
