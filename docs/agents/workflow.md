# Database planning workflow

Follow the [shared task workflow](../../../docs/agents/workflow.md) for approved
implementation, execution mode, evidence and delivery. The current session adds
authorized design discussion and documentation, and remains planning only.

1. Inspect local repositories, API/model drafts and representative source data.
2. Verify relevant HSDS and tool facts with authoritative documentation.
3. Interview in rounds: ask prerequisite-independent decisions in ordinary chat,
   give recommendations, and wait for answers. Record user decisions and recompute
   the next round. Investigate discoverable facts rather than asking the user for them.
4. Refine the single [design](../design/canonical-database.md), its HSDS mapping,
   entity relationships, provenance, spatial/export boundaries and acceptance scenarios.
5. Confirm shared understanding with the user, then review the specification when
   stable. Record findings and unresolved correctness decisions.
6. Convert the reviewed specification into an implementation action plan and tasks
   only when requested. Choose the tracker, map tasks to records and obtain plan
   approval plus whole-set/stepwise mode before implementation.

This phase produces no DDL, Sqitch scripts, bootstrap or export implementation.
The named `repo-context`, `design-change` and `review-spec` skills from the supplied
brief were not found in the current skill library. The equivalent investigation,
design and review procedures can be performed with available tools/skills; never
report an unavailable skill as run. `init-agent-docs`, `grilling`, `domain-modeling`
and `writing-for-agents` support the current documentation/interview work.

Keep readiness explicit in the design: interview in progress, proposed design,
review-ready, reviewed, approved for implementation. Suggested implementation
phases are not approved tickets or an execution plan.

## Active execution agreement

The user authorized execute-reviewed-task in grouped stepwise mode: #1–#4,
#5–#9, then #10. The first checkpoint was reviewed and pushed to dev; current checkpoint is #10 integrated acceptance. The development base is dev; master
is the completed integration target. Use the action plan’s execution record for
actual branch/worktree, acceptance evidence and delivery state. Earlier design-only
notes describe the initialization phase, not current authorization.

If the shared parent guides are absent in a standalone clone/worktree, use the
[worktree baseline](worktree-baseline.md) and the database-specific execution record.
