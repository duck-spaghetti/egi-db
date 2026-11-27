# Private groups and partial application

Migration 033 stores private immutable `GroupRevision` values and mutable private
head pointers, with normal preparation ACLs and no worker table access. Group
versions and member source-fact/interpretation IDs are stable UUIDs. A group is an
editorial workspace aid; it never merges canonical terms, services or entities.

`get_group_context(workspace, territory, axis)` derives a current published adopted
catalog identity. The checked workbench configuration catalog identities are also
accepted after validating their actual current taxonomy content. Arbitrary caller
digests, mixed interpreted-member contexts and stale targets cannot authorize an
application. Unresolved proposed groups may retain an empty context and null
mapping for correction; accepting a group requires a checked existing target.

`save_group(workspace, expected_version, revision, request_key)` accepts the exact
approved GroupRevision shape. Creation uses null expected version. Every member
must resolve to an owned retained card/version and its category fact or explicitly
materialized interpretation. Accepted revisions require current member heads and
compatible context. Acceptance writes no cards. Competing accepted mappings for
the same basis must be resolved explicitly. A new version preserves history. An archival-only revision must copy the exact
owned expected head, change only version/state, and identify that head as its sole
parent. It can archive even when old members or catalog references have expired;
it authorizes no application or new mapping.

A split creates a new group with one checked parent version and an explicit subset
of its member identities. The parent remains visible until explicitly archived,
so a subset cannot silently discard unselected members. Combining two or more
checked current parents requires the complete union of their member identities,
compatible context, and archives those parent heads atomically. Parent versions
record lineage; none is rewritten.

AI proposal linkage is result-local `<packet UUID>:<proposal_key>`, checked against
a retained group result in the same workspace. Related, ambiguous or membership
issue proposals remain reviewable and cannot become accepted applicable groups.
A mapping linked to such a proposal must be one of its actual supplied catalog
choices. An editor may explicitly extend reviewed members; the revision retains
the proposal identity and selected member IDs rather than asserting every member
was model-inspected. Literal labels and description-only interpretations remain
separate basis kinds. The deterministic equivalence algorithm belongs to the
Reviewer profile; persistence never infers equivalence from canonical term sharing.

`apply_group(workspace, request)` accepts `{group_id, expected_group_version,
selection, request_key}`. It freezes the accepted context/target and 1–100 exact
members. Multiple selected bases on one card coalesce into one card transaction
and receipt. It processes at most 50 pending cards per call. The same request key
continues pending work and replays terminal outcomes; a changed body conflicts.
Receipt readers and retries require the original active editor plus current
preparation access. `read_group_operation(workspace, operation)` reconciles all
selected card outcomes, including pending work.

Each member has an independent savepoint. The operator-selected raw label may
carry manual origin on both source_value and value; an untouched value equal to
the immutable quoted source_value can receive an explicitly accepted group mapping.
A corrected manual value or cleared value remains protected. Rejected or
conflicting confirmed interpretations, existing confirmed fact decisions and
ineligible/stale heads are preserved with safe skipped/conflict receipts. Valid
members append ordinary private card versions in review, retaining unrelated
classification associations. No new source label is fabricated. An unexpected
infrastructure failure aborts the current bounded transaction; a later request
resumes from the last committed receipt. A true database serialization failure
is not converted into a semantic conflict.

`undo_group(workspace, application_operation, request_key)` freezes only applied
members and processes at most 50 unchanged produced heads per call. Compensation
appends review versions restoring the prior private payload, preserves intervening
history and conflicts on any later edit. Existing trigger guards handle historical
interpretation/reference decisions. Undo can remove an old mapping even after its
catalog expires; it does not authorize a new taxonomy choice. Generic bulk save
and generic undo retain their existing atomic behavior. Immutable submissions and
canonical publication remain independent and are never retracted.

`read_group(workspace, group, revision, offset, page_size)` returns metadata
without members plus a member page capped at 100, total and cursor. `save_group`
returns that first-page envelope while the stored GroupRevision remains exact.
`list_groups` paginates 1–100 summaries, excluding members and parent history.
`read_group_operation` similarly caps receipt pages at 100 and includes total,
cursor and a full durable outcome summary. Expired whole-preparation retention removes group receipts,
applications and revisions through the existing narrow retention hook before
private inputs are removed. Active history remains retained.

Native contract 37 exercises a 1,000-card preparation, a 100-card selected operation
in two bounded calls, replay, selective compensation, source protection outcomes,
lineage, ACL and immutable submission behavior. It reports elapsed fixture time.
No live provider calls or external taxonomy changes are part of the test.
