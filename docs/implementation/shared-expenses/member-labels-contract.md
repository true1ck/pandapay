# Shared-expense member labels: backend contract (for the app)

Migration: `db/supabase/migrations/20261116090000_shared_expense_member_labels.sql`

## Label rule (like phone contacts)

1. The name the inviter typed (`shared_expenses.members.display_name`) always wins.
2. Otherwise the LIVE `public.profiles.display_name` (never the stale `phone_directory` copy).
3. Otherwise `Former member` (account deleted, `profile_id` NULL). Push text uses `Someone`.

`shared_expenses._member_label(name, profile)` implements this and feeds the roster
(`displayName` on members in the read APIs), so a profile rename shows up on the next read.
It can return NULL when there is no typed name and the profile has no name; show your own
fallback ("Member"). Two members may have the same label.

## Command `member.rename`

Same envelope and pipeline as every other command (`schemaVersion: 1`, `operationId`, `kind`, `payload`,
idempotent per `operationId`, emits a sync event `member.renamed` with `{memberId}` so other
devices refetch; add it to the app's event-label map if you show event names).

```json
{ "schemaVersion": 1, "operationId": "<uuid>", "kind": "member.rename",
  "payload": { "contextId": "<uuid>", "memberId": "<uuid>", "displayName": "Rahul K" } }
```

- Closed payload: exactly `contextId`, `memberId`, `displayName` (string).
- Server normalises: control characters stripped, whitespace collapsed, trimmed, **capped at 40 characters**
  (extra text is cut, not rejected). Raw text over 400 chars is rejected. Do the same on the client so the
  field shows what will be saved.
- Result: `{ "status": "renamed", "memberId", "displayName" /* normalised */, "sequence" }`.
- Replay with the same `operationId` and payload returns the same result and emits nothing new.
  Same `operationId` with a different payload -> `operation_conflict` (409).
- Allowed: the context owner for any `active` or `invited` member; any active member for their OWN row.
  Owner may rename themselves too.
- Contract vector: `contracts/shared_expenses/v1/command_vectors.json` case `rename_member`
  (canonical JSON + sha256; `shared_store_test.dart` already iterates this file).

Errors (JSON `{ "error": "<code>" }`):

| code | HTTP | meaning |
|---|---|---|
| `invalid_input` (+`field`) | 400 | client-side validation: bad shape, empty after cleaning, not a string |
| `invalid_member_name` | 400 | server-side: empty after cleaning / bad shape |
| `member_not_found` | 400 | memberId is not in this context |
| `context_not_authorized` | 403 | caller is not an active member of the context (stranger) |
| `member_rename_not_authorized` | 403 | non-owner tried to rename someone else's row |
| `member_not_renamable` | 409 | declined / left / erased member, or a former member (account deleted); owner-only `invited` rows are fine |
| `context_not_active` | 409 | context closed |
| `operation_conflict` | 409 | operationId reused with different content |
| `feature_disabled` | 503 | shared expenses switched off |

## Join request JSON (owner's `list_join_requests`)

Existing keys unchanged: `invitationId, contextId, contextKind, contextName, memberName` (typed label),
`verifiedPhoneSuffix, claimantName, createdAt`. Changes and additions:

- `claimantName`: now the claimant's LIVE profile name (was the phone_directory copy); may be null.
- NEW `claimantProfileName`: same live profile name (explicit key for the owner join card).
- NEW `claimantPhoneSuffix`: last digits of the verified phone (same value as `verifiedPhoneSuffix`).

`list_invitations` items: `claimantName` is now the live profile name; `memberName` is the typed label (unchanged).

Server-side `invitation_audience` (used only for pushes): `claimantName` = typed name else live profile name else null,
plus `claimantProfileName` and `claimantPhoneSuffix`. The notifier never uses the last two in push text.

## Push titles

`invitation.requested`: `<label> wants to join`, else `Someone wants to join`.
`invitation.joined`: `<label> joined`, else `Invite accepted`. Label is sanitised (control chars stripped,
whitespace collapsed, 40 chars). Expense / settlement pushes now use `_member_label` names too.

## Direct split titles

For `kind = 'direct'` the split's `name` (Friends list, overview, activity, invitation preview, join requests, push "where" text)
is now the COUNTERPART's current label, per viewer: the creator sees the other member's typed name (so it changes after
`member.rename`), else their live profile name; the invited person sees the creator's typed label, else the creator's live profile
name. Fallback: the split's own typed name, then `PandaPay friend`. Group names are unchanged. Implemented by
`shared_expenses._context_label(kind, name, created_by, viewer, context_id)` (the 4-argument form still exists and keeps the old behaviour).
After `member.rename` the app should refetch the contexts list (the `member.renamed` event fires on the sync stream).

## Security note

`shared_expenses_owner` (the definer role) gets a SELECT policy on `public.profiles`
(`profiles_shared_expenses_read`) so labels can read other members' names. Only the SECURITY DEFINER
functions run as that role; `app_user` still sees only its own profile row.

## Running the tests

API (no database needed):

```
cd api
node --test test/shared_expenses_notifications.test.js test/shared_expenses_commands.test.js test/shared_expenses_canonical.test.js
```

Postgres (needs an EMPTY disposable loopback database named `shared_expenses_test`; e.g. a throwaway container):

```
docker run -d --rm --name pp_labels_pg -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1:55436:5432 postgres:16
docker exec pp_labels_pg psql -U postgres -c "CREATE DATABASE shared_expenses_test"
PANDAPAY_SHARED_EXPENSES_TEST_URL=postgres://postgres@127.0.0.1:55436/shared_expenses_test node --test db/tests/shared_expenses_postgres.test.js
```

Recreate the database before each additional PG test file (they require no existing tables).
App-side contract check: `flutter test app/test/features/shared_expenses/storage/shared_store_test.dart`.
