# Standalone/worktree execution baseline

The workspace parent instructions remain authoritative when present. In an isolated
worktree or standalone clone, this baseline preserves the applicable rules from the
shared EGI workspace, updated 2026-11-25; explicit user decisions take precedence.

Read the database specification, approved plan/task mapping, context, standards,
workflow and planning guide before the corresponding work. Use English identifiers,
operational documentation and commits. Preserve unrelated changes and original
app/source references. Fetch `origin/dev` before a new task session, create an isolated
task branch from its verified commit, and record branch/worktree/base. On resume preserve
that work and assess material upstream changes.

Reuse authorization for approved scope. Return new dependencies, architecture/public
contracts, expanded scope or weakened criteria to the user. Verify each task with
concrete results, update affected docs and report limitations. Local and external
delivery are distinct; use the delivery grant in the Linear milestone description (the
issue, for an isolated issue) for commit/push/merge authorization. Branches reach dev
through a PR; promoting reviewed dev to master needs the user's
authorization. Keep histories intact and use ordinary fast-forward operations where valid.
Force push, discard/reset, deployment and destructive live-data work need their own
scope. Disposable test lifecycle is authorized only for the target created for it.

New work follows the EGI development cycle: exploration → grilling → specification →
tickets → implementation → final review, each phase closed by a user gate. The user
selects the mode once per milestone when approving its tickets: whole-set with one
final in-depth review by default, stepwise for large or risky sets. The Linear
milestone description (the issue, for an isolated issue) records branch, mode,
delivery grant and spec link. Track work in Linear team EGI, one repository per
issue. Branch as `ms/<milestone-slug>` (same name in every repository the milestone
touches) or `egi-<n>-<short-slug>`, and commit each verified task as
`EGI-<n>: <summary>`. Issue publication or implementation alone does not close an
issue. The #1–#10 grouped stepwise agreement is complete and historical.

A closed phase never opens the next. Whole-set mode continues through verified tickets
without review and stops only for a reserved decision or an unfixable failure; stepwise
mode pauses after each ticket. The specification is the Linear project document; Git
keeps code, contracts, `GLOSSARY.md` and ADRs. Approving a ticket breakdown authorizes
creating those issues; within an approved set the agent moves their states and adds
evidence comments; other Linear writes need the user's request.
