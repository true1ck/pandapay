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
| Leave / remove | Owner removes unjoined people with no expense; members leave only when settled (optional, groups persist across transactions) | PG |
| Owner transfer | Owner can hand the group to an active member, then leave | PG, widget |
| Deleted account | Shown as "Former member" with "history kept"; balances and expenses stay; if the owner is gone any active member can take over | PG, widget |
| Same friend added twice | Warns "You already split with X" with Open existing / Add anyway | code |
| Contact with several numbers | Short chooser before the number is used | code |
| Add friend when the invite call fails | "Try again" on the message retries with the number kept for that session | code |
| Not joined yet in expense pickers | Name shows "(not joined yet)" in paid-by and split lists | widget |
| Saved link on slow sign-up | Waits up to 30 minutes (link itself lasts a week) | code |
| Waiting invites outside Splits | Badge on You → Splits for invites and join requests | code |
| Inbox, members sheet owner/leave states | Widget tests with a fake runtime | widget |

## Open

| Gap | Why it matters | Proposed next step |
| --- | --- | --- |
| Recycled phone number | New holder of a number sees old invites for up to 7 days | Invites expire after 7 days; add a stronger rule only if abuse appears |
| Two accounts, same number | Auth enforces one active contact per number; no DB test across the two services | Add a cross-service test |
| Offline add keeps the number only for the session | Closing the app before retry loses the number | Persist with the queued command |
| Home screen dot | Badge is on You → Splits only | Add to the Home tab when the notification project lands |
| Push notifications | Invites are noticed on opening the app | Separate notification project |
