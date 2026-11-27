# Community reference resolution

Changes025–026 implement EGI-117 within the approved entity/category amendment.
They keep payload/result v1 compatibility and canonical service/location grammar.
The whole-set review remains separate from these provider checks.

## Catalog boundary

`preparation.reference_catalog(workspace, query)` authorizes private read access;
`editorial.reference_catalog(contribution, query)` requires a verified active
editorial session and a submitted snapshot. Neither creates entities, evidence or
jobs. Both share one catalog query implementation. The closed query accepts kind
`organization`, `taxonomy_context` or `classification`, optional search (500 chars),
limit1–50 (default50), offset0–100000, territory_id, axis_id and adoption_id.
The result has entries, next_offset, complete and context. Complete describes this
filtered page sequence, not a claim that an unselected taxonomy axis was searched.

Organization entries contain the actual visible name, territories, published flag
and target `{kind:organization, organization_id, expected_work, expected_public}`.
Unpublished names require propose authority over their working scope. A published
organization with an unauthorized newer draft uses its public name/scope. Head
identifiers remain exact optimistic-concurrency metadata. No private organization
text is thereby eligible for a provider request.

Organization context is `{organization_name,catalog_digest}`. The digest binds the
current exact case-insensitive trimmed-name candidates and their heads. It warns
about newly appeared/changed same-name candidates; it imposes no name uniqueness or
identity merge. Creating another same-name organization is allowed after refreshing
and explicitly choosing creation. Existing targets can also use empty context,
since their exact working/public heads are independently checked.

Taxonomy-context pages list effective territorial adoptions, release version, axis
code/label and territory name. Classification queries require territory_id and
axis_id. Entries include label, broader parent IDs, effective dates and target
`{kind:classification, adoption_id,release_id,term_id,axis_id}`. Releases must be
sealed, terms active, and both adoption start/end dates effective. The closed
selection context is `{territory_id,axis_id}`; labels never substitute for identity.

## Private choices

V2 resolutions allow unresolved/ignored with empty context/candidates and no
selection; proposed with context and up to100 candidates; confirmed with selected.
Each candidate is `{target,rank,reason}`: integer rank1–100, reason1–1000 chars,
actual existing target only. New-organization candidates cannot be machine guesses.
Selection is `{target,role?}`. Organization role is a separate explicit1–100-char
canonical role_code; classification rejects role. A location category remains a
literal claim: canonical classifications currently belong to services.

New-organization target is `{kind:new_organization,body}`. Body requires name,
original_language and explicit territories (an empty array means global scope),
with optional description/organization_type/website. It contains no UUID, contacts,
evidence or arbitrary canonical properties. Context must match that proposed name
and current candidate digest. Propose authority and territory existence are checked.

The ordinary expected-version save confirms a choice. A BEFORE INSERT trigger
stamps confirmation `{actor_id,item_version,fact_value}` from the verified session
and actual item base, overwriting any supplied identity. Unchanged choices retain
their original stamp. Changing a fact cannot retain its old confirmed choice; the
client must invalidate it. References are revalidated on save and acceptance, so
stale heads/adoptions produce explicit conflicts instead of silently remapping.
Original spelling/quote and manually corrected value stay distinct.

## Explicit acceptance

`accept_community_item` additionally accepts schema_version2 with required
fact_actions; v1 rejects this extra key and behaves as before. Each action identifies
a fact from the selected immutable snapshot. `{fact_id,action:keep}` retains its
literal claim without canonical association. Select/create actions require context,
selected, note and reconcile (`retain` or `replace`). Select targets an existing
organization/classification; create targets a new_organization body. Nonblank note
is an explicit human relationship/role decision, never a claim that the name quote
proved an organization role or taxonomy identifier. A moderation decision can
confirm a previously unresolved/proposed fact; extraction alone cannot.

New organization draft, chosen location changes, service revision, source assertions
and immutable resolution receipts share the existing canonical operation/item locks
and one transaction. A later error rolls back every effect. Replaying the accepted
decision returns its original result; a different decision conflicts. Fact-resolution
rows attribute the actual accepting actor, snapshot version, current value and
selection. They survive private purge with the editorial snapshot. Later proposals
for the same item/fact reuse the recorded organization identity rather than creating
another draft; changed heads/selections require explicit reconciliation. Replace
removes only the association previously recorded for that fact; retain preserves it.
Unrelated roles/classifications and their proof remain in the canonical baseline.

Exact submitted fact quotes materialize their own literal assertion. Organization
name assertions have organization subject_kind. New draft name may cite the exact
literal only when it equals the uncorrected source claim; other/current corrected
fields use attributed editorial observations. Relationship IDs/roles and category
mappings use explicit editorial observations, not fabricated publisher claims.
Every used Community/manual assertion remains subject to Admin source admission.

`revision_body` now round-trips organization fields using the existing serializer.
No organization is auto-approved/published. A linked draft continues to yield
unpublished_organization; approve/publish the organization explicitly, then the
service, using existing exact-head governance operations. Unresolved names remain
permitted in the editorial snapshot under the existing publication minimum.

## Verification and rollback

Contract30 uses real sessions, v2 save/send, forged confirmer replacement, privacy,
exact source assertions, atomic failure/replay, separate source admission and
organization/service publication, same-name candidates, pagination, stale heads,
future adoption and same-label distinct axes. Contract31 uses two separate verified
sessions racing acceptance and checks one organization/service/resolution. Existing
SQL contracts and concurrency checks remain configured. The negative observation
subject in contract16 moves to taxonomy_term because organization is now supported.

Revert026 refuses retained editorial fact resolutions. Revert025 refuses proposed
or confirmed references in private history or editorial snapshots. No revert deletes
or downgrades user data. Structural triplets seed no entities/configurations. Native
psql can exercise their SQL independently; that does not establish Sqitch registry
execution when the local Sqitch/Perl prerequisite is unavailable.
