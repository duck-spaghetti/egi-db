# Community canonical acceptance

Change 020 implements EGI-106. `editorial.accept_community_item(contribution,
 decision, key)` accepts `acceptance.decision.v1` from an active verified moderator.
Acceptance creates or updates a canonical **draft**. Review, publication and closing
an editorial proposal remain distinct operations.

The canonical operation lock precedes the logical preparation-item lock. Exact
working/public heads are checked against the submitted target and current database.
An immutable resolution binds each accepted snapshot to its canonical service and
initial revision. Later submitted versions retain that identity. Identical decisions
return the first resolution; a changed decision conflicts. An unresolved predecessor
must first be resolved, unless it was rejected or closed without a change.

Service operations apply to the complete current `revision_body`; omitted components
and their proof survive. Closed aggregate validation, protected evidence/identity
paths and canonical ownership constraints prevent arbitrary patching. New services
require an explicit delivery mode. Every contact requires an explicit visibility
choice. Location creation or revision and service acceptance share one transaction:
a later failure rolls back both. Location reuse checks exact heads, without silently
editing the reused place.

Changed facts require selected submitted evidence for the same normalized path/value
and context, or an explicit observation with a recorded human method. Interpretation
is labelled uncertain. Exact excerpts become selective source captures/assertions
under the registered source, without copying private original inputs or sibling
cards. Correcting a value cannot reuse an unrelated quote. Explicit human checks use
the existing editorial observation source. Visibility is an editorial permission,
never evidence inferred from model output.

Complete private location bodies inherit trusted canonical proof by stable component
identity (or exact unchanged value). Changed decision containers replace their own
proof; unrelated containers survive. A newly accepted location relationship can
carry evidence materialized for that same location. Reusing another canonical place
still requires evidence or an explicit observation for the association.

The authoritative publication diagnostics inspect all Community-derived assertion
references, in every evidence role. A source needs a separate Admin admission before
publication, including when its assertion is reused or restored elsewhere. Generic
and Community-specific closure both require an actual publication of the resolved
service descended from that proposal's accepted revision. An unrelated or older
publication cannot close it as published.

Contract 25 covers acceptance replay/conflict, missing delivery mode, source admission,
separate publication/closure, location/service rollback on component ownership failure,
new-version identity, exact-head conflict, observation requirements and preservation
of untouched contacts/evidence. Structural verify checks privileges and the composite
revision/service reference. No provider calls or shared-database SQL are involved.
The installed Sqitch CLI remains unavailable (missing Perl interpreter); native psql
runs the actual deploy/revert/verify SQL on disposable PostgreSQL 18 clusters.

Verification on 2026-11-26: contract 25 and change 020 deploy/revert/verify passed
in the focused cluster. The full native runner then passed every SQL contract
through 25, all three existing concurrency checks, all structural checks and a
full reverse/redeploy cycle, repeating contracts after redeployment. The runner's
final label still says 'through 24'; its glob included the new contract 25.
Self-review covered private/immutable boundaries, source lineage, selected-fact
binding, canonical ownership and separate publication. Combined independent review
and integrated application/provider acceptance remain pending.

Integration correction, change 021 (EGI-106): complete-baseline evidence comparison
now aligns array components by their stable identity (weekday for day entries,
exact unchanged value otherwise). Removing/reordering a sibling preserves unchanged
components' proof without treating them as newly asserted facts. Changed values
still require submitted evidence or an explicit observation. The selective snapshot
reader also exposes its own immutable resolution, as required by the moderation
view; it never exposes private originals or siblings. Contract 26 tests shifted
proof preservation and changed-value rejection. All SQL contracts through 26,
structural checks, all three concurrency checks and full direct-SQL lifecycle passed
twice. The historical runner's success label still says through24; its glob includes
25/26. Sqitch CLI remains unavailable; no populated database was changed.

Change 022 (EGI-106) keeps scalar proof in its submitted component context. Contact
labels/numbers, scoped schedules, weekdays and interval pairs cannot borrow equal
values from another component to imply an unsupported combination. Explicitly moving
the same complete proposal is still allowed. Changed combinations need matching
submitted evidence or an explicit human observation. Contract27 covers mixed contact
labels and interval boundaries; all SQL contracts through27, concurrency and direct
SQL lifecycle passed twice. No public interface or table/grant was expanded.
