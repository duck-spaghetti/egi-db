# Literal source facts — 023 / EGI-114

The private item envelope now accepts version2 alongside version1. Canonical
service/location bodies and public directory contracts do not change. No migration
rewrites existing private versions or submitted snapshots. Only disposable native
verification is authorized/applied; this change installs no login, provider or job.

A v2 envelope adds required `source_facts` and `resolutions` arrays. Each fact has:

- `fact_id`: a UUID bound to one private item, retained across versions/reordering;
- `subject`: service or location;
- `kind`: organization_name or category_label;
- `source_value`: the retained literal spelling, immutable for this fact identity;
- `value`: the currently edited value; absent only with an explicit cleared origin.

Facts require exact retained-input evidence at `/source_facts/<index>/source_value`.
The existing original-input hash, Unicode code-point spans, BOM/CRLF behavior and
quote checks apply. The quote must include the literal claim. A changed value needs
an explicit manual origin at `/source_facts/<index>/value`; clearing needs cleared.
Original spelling/evidence remain separate and cannot be presented as proof of a
corrected value. Array positions in evidence/origins must follow reordered facts;
the save guard compares retained citations by fact identity, not old array position.

`fact_identities` is a private identity register, indexed by item and keyed by fact
UUID. It rejects reuse on another item/preparation or a different literal/kind/subject
without scanning every historical JSON payload. Its input reference keeps source
bytes available while private history needs them. It is removed with private-item
retention; editorial snapshots retain their independent selective copy. No editorial,
retention or worker login gets direct table access or helper execution.

EGI-114 provides resolution slots, not reference matching. At this stage a resolution
contains fact_id, state unresolved/ignored, empty context and empty candidates, with
no selected target. Each fact has at most one slot. Proposed/confirmed references
are refused (`reference_resolution_not_available`) until EGI-117 supplies contextual
reference validation and explicit canonical acceptance. No organization/category ID
can be smuggled into a literal fact. Existing canonical body reference validation
still applies on submission; saving literal facts writes no canonical entity.

## Versions, undo and submission

Saving schema_version2 appends a new private version. An empty upgrade contains empty
new arrays; it does not reconstruct source facts from canonical IDs or names. A v1
write against a v2 head fails `item_schema_downgrade`, even with a fresh expected
version. Stale versions retain the existing item_version_conflict response. Request
receipts and workspace row locks remain authoritative.

Undo appends a compensating version. Undoing an upgrade back to a pre-v2 state keeps
the v2 envelope with empty new arrays; it cannot silently re-enable destructive old
client writes. Existing v1 history and snapshots remain unchanged. Ordinary v1
workspaces continue to use the unchanged baseline validation.

Selective submission copies the current card's facts/origins/resolution slots and
its relevant evidence. It never copies original bytes, unsent siblings, jobs or
sharing history. Snapshot reads remain usable after private purge; the snapshot has
no FK to the private identity register or retained inputs. No canonical acceptance
of a literal unresolved fact is implied.

Reverting023 refuses `source_facts_in_use` if any retained private version or submitted
snapshot uses v2, including an empty upgraded version. Revert never deletes such
history. Once no v2 data remains under the normal authorized lifecycle, the triplet
restores the previous validator/save implementation and removes its private helpers.
There is no downgrade/purge tool or automatic rewrite of editorial history.

## Evidence on 2026-11-27

Direct native PostgreSQL18/PostGIS deployment and structural verification passed on
an isolated Unix-socket cluster. SQL contracts include v1 immutable snapshots, v2
upgrade/replay/reopen, manual-origin checks, exact quotation validation, immutable
fact identity, duplicate/foreign fact rejection, reorder, undo across the upgrade,
old-client/stale-write failures and selective snapshots surviving private purge.
The submission concurrency fixture now uses v2 and proves one snapshot/attribution,
then two editors racing on one fact version leave only the first correction.

The complete SQL contract set and existing canonical/budget/submission concurrency
checks passed. Actual revert refused a retained v2 editorial snapshot; after removing
only the disposable fixture snapshot, revert/redeploy and structural verify passed.
The Sqitch CLI/registry was not exercised by these direct-psql checks (the existing
local Sqitch runtime prerequisite remains unavailable). The configured disposable
runner includes contract28 in both deploy cycles.

A transaction-local synthetic measurement on the same cluster averaged0.243ms for
20 v1 saves and0.462ms for20 two-fact v2 saves; one1,000-fact save took592.64ms.
These are warm database-function timings, not HTTP latency, percentile guarantees or
production capacity. Reproduce the optional measurement with psql variable
`measure_facts=1` on contract28; fixture values are synthetic. `keep_facts=1` retains
test data only for the disposable rollback-refusal check. Do not use either option
on a populated database. Final integrated performance and independent review remain
part of the whole milestone.
