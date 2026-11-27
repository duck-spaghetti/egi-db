# Private interpretations (EGI-146)

Migration030 adds private item schema3. An explicit save upgrades a v1/v2 item by
retaining its existing fields, supplying source_facts/resolutions when absent and
adding interpreted_classifications and interpretation_hypotheses arrays. Immutable
earlier versions and submissions retain their original schema. Lower-schema writes
to a v3 item fail; compensating undo stays v3.

An interpretation basis identifies an exact historical version of the same card,
its JSON pointer, preparation.digest(value) and retained quotation IDs. These are
validated against the stored input-bound evidence rather than caller descriptions.
Classification candidates and hypothesis triggers are separate. The category body
association is appended atomically only by a deliberate confirmed private save;
the server stamps the current verified actor and time. Existing associations are
retained when a basis changes, is rejected or becomes stale. Editing/removing an
association remains an explicit operator reconciliation; it is never inferred
from the absence of a proposal. Multiple interpretations can support one association.

An abbreviation hypothesis starts unverified. Verification needs separate evidence
IDs; its own trigger quotation cannot verify the expansion. Server decision IDs,
actor and time replace caller attribution, including changes to verified content.
Basis edits stale both kinds of decision without converting an interpretation into
a source_fact. The existing v2 source identity and reference confirmation guards
also run for schema3.

Selected moderation snapshots retain the selected card's new arrays and
values.interpretation_support: the frozen bases and their selective historical
quotations. They copy no original input bytes, sibling card, plan or provider
context. This evidence remains available after private retention cleanup. Canonical
DTOs and explicit editorial acceptance operations remain unchanged.

Native check: scripts/verify-workbench.py accepts an explicit immutable resource
checkout and revision, validates its source bytes against Git, then uses its
ResourceRun/OwnedCluster lifecycle. EGI_PG_BIN, EGI_SQITCH and PERL5LIB select the
already installed native tools. The check runs Sqitch deploy/verify, specified SQL
contracts, revert to029, redeploy and verify, then validates owned teardown. No
existing database or process is adopted. tests/contract/34-interpretations.sql
exercises private saves and selected moderation with actual PostgreSQL sessions.

Rollback is structural and destructive to the new private identity registry:
revert030 only after preserving or explicitly retiring v3 private data and their
snapshots. Normal undo uses immutable compensating item versions, not Sqitch revert.
