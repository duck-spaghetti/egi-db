# Database planning and collaboration

Read the [shared planning and collaboration guide](../../../docs/agents/planning-and-collaboration.md)
for task records, workspace establishment, resume and contributor coordination.

## Current state (2026-11-25)

Issues #1–#10 are delivered: `dev` integrated them and PR #2 promoted them to
`master`. New work follows the workspace development cycle, is tracked in Linear
(`repo/database`) and branches from the fetched `origin/dev`. The sections below are
the historical record of the #1–#10 effort.

## Planning records (2026-10-05)

The maintained design is [canonical-database.md](../design/canonical-database.md).
The accompanying [API/data inventory](../design/api-and-data-inventory.md) records
facts rather than a specification. GitHub Issues is selected; [tracker configuration](issue-tracker.md) records the
repository destination, published task set and delivery boundaries. The local
[specification](../design/specification.md) and [action plan](../design/implementation-plan.md)
use the existing design directory while that setup remains pending. Plan units are
not created issues; link actual GitHub identities only after authorized publication.

The user has explicitly authorized this second agent-documentation pass and
database design discussion in the current new repository. It has no committed
local development history; origin is now configured. The original documentation bootstrap could not fetch/pull
or branch from remote `dev`. No remote freshness is claimed. Product implementation
requires a separately settled base/remote bootstrap and isolated task workspace,
as described by the shared guide.

Investigation of the original app/source collection is read-only. Preserve its
checkout and source files. Delegate fact discovery where the interview skill calls
for it; this does not authorize concurrent implementation or overlapping repository
edits. Review documentation changes against the user's supplied constraints and
retain pending choices as proposals.

## Specification/planning phase (historical)

The user accepts the structural proposal as sufficient and explicitly invoked
`to-spec` followed by `plan-with-docs`. The specification is synthesized; the action
plan r0.2 records the approved approach and environment/write-surface/verification
choices, confirmed by the user on 2026-10-05. The subsequent `to-tickets` request and approved breakdown published issues #1–#10
on the user-created GitHub repository; see the action plan mapping. No commit/push,
implementation, installation or DB connection occurred.

## Execution agreement, 2026-10-05

The user accepted the recommended grouped stepwise implementation, then explicitly
requested execute-reviewed-task. First authorized group: issues #1–#4; pause after
publication/restoration acceptance. Later groups #5–#9 and #10 require continuation.
The user selected dev as development base and master as completed integration target.
Preserve the remote initialization commit 87cc9d3d1b1637f59b4b26e570fa5b86e8a63369
(currently main). Create master at that base and publish the initial documentation
commit to dev. Keep main intact. Product work uses an isolated task branch/worktree
from verified origin/dev. Scope includes native Sqitch setup, approved SQL structure
and operations, dedicated disposable PostgreSQL/PostGIS verification and synthetic
checks. Existing server/data and original app/sources remain untouched.
Implementation delivery and final merge require verified reviewable results; the
current bootstrap push is specifically authorized. Do not advance past checkpoint #4.

If the shared parent guides are absent in a standalone clone/worktree, use the
[worktree baseline](worktree-baseline.md) and the Linear milestone record (the action plan
for #1–#10).

## Group continuation (historical)

The #1–#4 review was accepted and pushed to dev at e03f2f9. The user authorized
#5–#9 in the same grouped stepwise mode, on task/egi-database-05-09 from that base.
Pause after #9 for review and delivery authorization, before #10/master integration.
Use the current action-plan record; earlier phase records above are historical.

## Final integrated acceptance continuation (historical)

The user accepted #5–#9 and explicitly authorized push to dev plus #10 execution.
The reviewed group is delivered at 9d4013c; #10 uses task/egi-database-10 from that
fetched base. Pause at final review. Use the current plan for evidence/delivery;
master integration and production operations retain separate authorization.
