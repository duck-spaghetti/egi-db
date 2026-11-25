# Visitor contributions — 011

EGI-82. Visitor reports, still-valid signals and new-service proposals live in the
private `editorial` schema. Contact and text are deleted on the agreed deadlines;
the row, its decisions and its outcome remain. Nothing here enters canonical
revisions or audit: a correction reaches the public only through a moderator's
publication, which the closed contribution then references.

## Roles and logins

| Role | May do |
| --- | --- |
| `egi_intake` | only `editorial.submit_contribution(...)`; reads nothing |
| `egi_editorial` | the moderation functions below, as the person of the verified session ([access](access.md)) |
| `egi_retention` | only `editorial.purge_expired_contributions()` |

No login is created by the migration. Per environment the owner creates one
`LOGIN IN ROLE egi_intake` for the public app and one `LOGIN IN ROLE egi_retention`
for the scheduled purge.

## Intake

`submit_contribution(kind, service, category, message, contact, contact_consent, proposals, trap)`
returns `stored`, `trapped` (honeypot filled; nothing kept), `limited` or `closed`.
Limits are global, without IPs: 30 per 10 minutes and 300 per day by default
(`editorial.intake_settings`, changed by the admin with `set_intake`). Kinds:

- `report` on a public service, with a category (`hours`, `contacts`, `address`,
  `closed`, `other`), optional text and optional proposals `[{"field","value"}]`;
- `still_valid` on a public service, carrying nothing else;
- `new_service`, with at least a `name` proposal.

A contact needs explicit consent. The public revision at submission is kept.

## Moderation

| Function | Effect |
| --- | --- |
| `list_contributions(include_closed)` | the queue, with claimant and counts |
| `read_contribution(id)` | text, contact, proposals and history |
| `list_moderators()` | active people a case can be handed to |
| `claim(id, action, assignee)` | `claim`, `take_over`, `reassign`, `release`; never a lock on the service |
| `set_waiting(id, reason)` | `evidence`, `submitter` (only with a contact), `admin`; `NULL` resumes |
| `decide_proposal(id, decision, decided_value, note)` | `accepted`, `amended` (with the moderator's value), `rejected` |
| `close_contribution(id, outcome, reason, publication)` | `published` needs a publication of the contribution's service; other outcomes need a reason; undecided proposals are recorded as rejected |
| `set_intake(open, window_limit, daily_limit)`, `read_intake()` | the admin's switch and limits |

Every step is in `editorial.events` with the person who took it; event details never
carry contact or text.

## Retention

`purge_expired_contributions()` deletes a contact at closure or after 90 days, and a
closed contribution's text, with its proposals' values, 30 days after closure. It
returns the counts. Waiting does not move the deadlines. Job definitions for the
system scheduler are in `scripts/retention/` (systemd unit and timer, launchd plist):
they are templates and are not installed by any script.

Revert refuses while contributions exist (`contributions_exist`).
