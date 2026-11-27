# Attributed Community submissions — 019 / EGI-105

`preparation.submit_item(workspace,item,expected_version,key)` sends one confirmed
private card into the existing editorial queue. It creates no canonical service,
location, revision, assertion or publication. Missing publication facts can be
completed later; canonical acceptance/publication remain separate operations.

## Submission and receipts

The existing editorial login must verify its session in the transaction. Current
edit access is checked under the workspace row lock before any replay/read receipt.
A reader or uninvited Admin cannot submit. The owner and invited editors can submit;
the first successful person's actor is recorded on both snapshot and submitted event.

The item must belong to the workspace, match its expected head, be confirmed and
not trashed, name a service, use closed known shapes/vocabularies and reference
existing canonical objects where real IDs are supplied. Missing mode/description/
evidence is diagnosed rather than defaulted. Unknown references, invalid component
domains, incompatible location schedules and invalid clock/coordinate values fail.
Further canonical ownership/save prerequisites remain the acceptance provider's job.

A request-key replay returns its original receipt. A different authorized submitter
sending the same already-submitted item/version gets the same contribution and
original attribution. Workspace serialization and a unique item-version snapshot
prevent duplicate submissions under concurrency. Subsequent private edits append
new versions; only an explicit later submit creates a linked update. They cannot
rewrite an earlier submission. Existing-target identity stays tied to the same item;
when the acceptance provider resolves a new-service lineage, later submissions can
freeze its canonical working/public heads as updates.

## What moderation receives

`editorial.community_snapshots` retains exactly the selected card's values, evidence
locators/quotes and registry source metadata, plus submitted actor/time and opaque
preparation/item/version lineage IDs. It never copies original input bytes, other
cards, job payloads, private history or an original-artifact retrieval link. The app
must show the actual values and supporting excerpts before the operator confirms
what to send; a chosen excerpt is an explicit disclosure, not permission to attach
an unseen full input. The database verifies its exact original slice but cannot
certify the semantic relevance of arbitrary human-selected passages.

Snapshots are immutable, with no FK to private preparations/items/versions. Their
source registry and contribution lineage are retained. There is no automatic
submitted-snapshot expiry in the approved first policy. The 30-day private trash
purge does not delete them. Existing visitor contact/text/proposal-value retention
is unchanged and does not erase these independent Community values/evidence.

`editorial.read_community_snapshot(contribution)` is for any active verified
moderator/Admin, as required for editorial work. It returns the submitted copy and
completeness diagnostics only. It does not dereference private origin IDs. An
uninvited moderator may read the submitted snapshot but still cannot use its opaque
preparation ID to fetch original input or unsent history. No worker/intake/retention
role receives snapshot retrieval or direct table privileges.

## Existing queue compatibility

The contribution author-kind constraint gains `community`; its default remains
`visitor`. New services still have a NULL `contributions.service_id`, including after
acceptance. Existing-target Community reports alone may reference an unpublished
service with a NULL public head; visitor public-target rules are unchanged.
Community writes bypass anonymous intake quotas, while the public intake function's
old counts exclude the new authenticated author-kind so staff submissions do not
consume visitor capacity. Existing non-Community counting/limits remain intact.

The authoritative generic `close_contribution` now delegates Community publication
checks before mutating proposals/contributions. Before the acceptance provider is
installed, closing Community as published fails `community_acceptance_required`;
reasoned rejected/no-change/duplicate closure still uses the existing rules. The
next provider supplies actual service-resolution/publication-identity validation.
It cannot be bypassed by calling the older generic function directly.

## Verification — 2026-11-26

Native contract 23 covers read/edit/outsider permissions, exact selective excerpts,
name-only diagnostics, invalid vocabulary/reference refusal, request replay,
first-submitter attribution, immutable copies after private edits, update lineage,
uninvited Admin denial for originals/history, generic-closure guarding, visitor quota
compatibility and snapshot survival through both retention paths.

Shell contract 24 runs two real verified people concurrently against one item/head:
exactly one contribution/snapshot/submitted event survives, attributed to the first
submitter; the other receives `already_submitted`. No canonical service is created.

Final whole-set review, canonical acceptance, real-provider evaluation and human
acceptance are still pending. Direct native psql exercises actual Sqitch plan SQL;
Sqitch CLI/registry is unverified because its installed Perl interpreter is absent.
Structural deployment seeds no source or contribution. Revert refuses while any
Community submission remains, preserving immutable editorial history.

Final EGI-105 evidence: all native SQL contracts through 24 (21/24 shell), structural
verification, canonical/budget/submission concurrency and full direct-SQL
revert/redeploy passed twice on the final changed state. Self-review covered
selective copying, immutable lifecycle independence, receipt authorization, stable
attribution/lineage, reference validation and visitor compatibility. Independent
combined milestone review and user acceptance remain pending.
