# Adding people, links and joining: scenario register

Status as of 5 November 2026 (local, uncommitted to any remote). "PG" = real PostgreSQL suite `db/tests/shared_expenses_postgres.test.js`; "API" = `api/test/shared_expenses_invitations.test.js`; "Dart" = `app/test/features/shared_expenses/data/shared_directory_test.dart`. Source: an independent read-only audit plus the build work below.

## Covered and tested

| Scenario | Behaviour | Evidence |
| --- | --- | --- |
| Add friend by name only | Saved on the phone, a shadow person; invite later | existing Quick Add test |
| Add friend by number / contact | Live "on PandaPay" check, masked name, in-app invite or share link | PG phone directory + inbox tests, emulator + phone run |
| Number belongs to the user | Blocked with a clear message (API and DB) | PG, API |
| Person already in the split / same number twice in one split | Refused | PG |
| Already split with them (direct) | "Open existing split" shortcut | PG lookup |
| Invite accepted / declined / expired / replaced | Inbox, owner statuses, decline pause 7 days | PG |
| Phone-less "Invite again" after a decline | Keeps the phone binding, so the pause cannot be bypassed | PG |
| Wrong person opens a phone-bound link | Rejected; unverified phone gets "verify your number" | PG, API |
| Opt out of discovery | Looks identical to unregistered | PG |
| Lookup abuse | 25 per day per person | PG |
| Forwarded link | Becomes a request; owner sees who opened it (PandaPay name, number ending) | PG |
| Group link | One per group, reset kills old link, revoke, expiry, 20 pending cap, 10 per hour, 7 day pause after decline, already-member and owner are no-ops, pending person cannot read the group | PG, API, Dart |
| Direct split naming | Each person sees the other, not themselves; owner/approved members use their PandaPay name | PG |
| Join before anything is allocated | Joining posts no money; every expense still needs their approval | PG |
| Invitee only sees revisions that involve them | | PG |
| Settle with someone who has not joined | Blocked with an explanation | Dart widget test |
| Preview offline | Saved invite kept; retry offered | manual |
| Groups up to 200 people | Roster reads 4 pages | code |

## Open (decision or larger build needed)

| Gap | Why it matters | Proposed next step |
| --- | --- | --- |
| No leave / remove member / transfer owner / archive | A declined or abandoned person stays allocated forever; a full direct split cannot be reused | Needs product rules for balances: allow leave only at zero balance, remove only unjoined members, owner transfer. Server functions + UI. |
| Deleted account leaves an active member with no profile | Pending approvals and settlement stall; if the owner is deleted nobody can invite | Part of account erasure design (README lists erasure as open) |
| Recycled phone number | New holder of a number sees old invites | Invites expire after 7 days; consider also tying to account age |
| Two accounts, same number | Auth enforces one active contact per number (migration 9001); no DB test across the two services | Add a cross-service test |
| Same person added twice as separate friends by name | Two direct splits with one person | Warn on same name; suggest existing |
| Add friend offline with a number | The number is not kept; invite step must be redone | Persist the number with the queued command |
| Resume of a saved link gives up after 60 s of slow sign-up | Link is lost on slow onboarding | Resume on first home screen instead of a timer |
| Editor pickers do not mark "not joined" | Expense stays pending without explanation | Add a "not joined yet" chip |
| Contacts picker uses the first number | Wrong number for multi-number contacts | Let the user choose |
| No widget tests for add-friend sheet, members sheet invite UI, inbox, join route | Regressions would be silent | Add widget tests with a fake runtime |
| Inbox only on Splits | Invites are noticed only when Splits opens | Home badge, later push |
