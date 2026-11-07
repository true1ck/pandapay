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

---

# Join identity: consented phone, unique names (migration 20261116100000)

Spec: `join-identity-spec.md`. Everything about phone numbers is behind `SHARED_EXPENSE_PHONE_SHARING_ENABLED` (default `false`).
With the flag off nothing is stored, shown or revealed and responses look as before (`claimantPhone` is removed from list
payloads, `invitationId`/`phoneShare` are not added to the claim reply, `reveal-phone` and `check-phone` return 404, preview gets no `phoneSharing`).

## Environment

| Variable | Meaning |
|---|---|
| `SHARED_EXPENSE_PHONE_SHARING_ENABLED` | `true` to turn the feature on (default off) |
| `SHARED_EXPENSE_PHONE_ENC_KEYS` | key ring JSON: `{"current":"k1","keys":{"k1":"<base64 of 32 random bytes>"}}` |

Generate a ring: `node -e "console.log(JSON.stringify({current:'k1',keys:{k1:require('crypto').randomBytes(32).toString('base64')}}))"`.
Rotate by adding `k2`, setting `current` to `k2`, and keeping `k1` until no pending request uses it (requests live at most 7 days).
Missing or malformed ring => no number is ever stored (the claim still works, consent is recorded as `not_asked`).
The ring is separate from `ENCRYPTION_KEY` and `SHARED_EXPENSE_INVITE_SECRET`.

## Endpoints

- `POST /shared-expenses/invitations/preview` (flag on) adds `phoneSharing` (flag on AND the server has a usable key ring),
  `ownPhoneMask` (the caller's OWN verified number masked, e.g. `+91 72••• •4821`; `null` without a verified phone) and, always,
  `ownerName` (cleaned label of whoever made the link/invite; names only). Absent `phoneSharing` = false = old behaviour.
- `POST /shared-expenses/invitations/claim` body `{token, operationId, sharePhone?: boolean}`. Reply (flag on) adds
  `invitationId` and `phoneShare` (`shared|declined|none|not_asked`). Rules: no verified phone => `none` (sharePhone ignored);
  `true` => number encrypted in Node and attached in the same transaction (`shared`); `false` => `declined`, nothing stored;
  missing => `not_asked` (old app), nothing stored. A repeated claim while pending re-applies the choice, refreshes the last 4 digits
  and does not extend the expiry; an EXPIRED pending request is revived (same member, expiry reset to 7 days).
- `GET /shared-expenses/invitations/requests[?withLookalikeFull=1]` items keep every old key and add `claimantPhone`
  (`v, source, consent, countryCode, last4, mask, available, unavailableReason, lookalike, duplicateOf, numberStatus, matchesTyped, capturedAt`).
  `fullNumber` (E.164) appears ONLY on items with `claimantPhone.lookalike === true` and only with `withLookalikeFull=1`.
  `mask` is null unless the number is available. `duplicateOf` = invitation ids (pending, same owner) or joined invitations of other accounts with
  the same number. `numberStatus`: `confirmed` (the directory holds this number for the same account), `moved` (for another account), `unknown`.
- `GET /shared-expenses/contexts/:id/invitations` items get the same `claimantPhone` and a live-name `claimantName`.
- `POST /shared-expenses/invitations/reveal-phone {invitationId, operationId}` => `{invitationId, e164, revealedAt}`, `Cache-Control: no-store`.
  `operationId` is validated but NOT used for replay (a replay would bypass the caps); nothing is written to the operation ledger.
  Errors: 403 `context_not_authorized` (not an active owner of that context, unknown invitation, claimant), 409 `phone_not_available`
  (not pending, expired, purged, consent not `shared`, ciphertext cannot be decrypted), 409 `owner_phone_required` (the owner has no verified phone),
  429 `reveal_rate_limited` (5 per hour, 30 per day per owner), 400 invalid input, 404 feature off. Each success is audited in `phone_reveals` (no number inside).
- `POST /shared-expenses/invitations/check-phone {invitationId, phoneNumber}` => `{matches: true|false|null, attemptsLeft}`. Compares a keyed hash;
  3 attempts per invitation; `matches:null` (and no attempt consumed) when the claimant did not share. 429 `check_attempts_exhausted`, 409 `phone_not_available`, 403 not owner.

## Names

- `member_name_taken` (409), `friend_name_taken` (409, body also has `existingContextId`), `member_name_reserved` (400), `invalid_member_name` (400).
  They come back as the HTTP error of `POST /shared-expenses/commands` (member.invite, member.rename, context.create for a direct split) and nothing is written.
- Uniqueness key = `label_key` (NFKD, lower, Cyrillic/Greek look-alikes folded to Latin, accents/punctuation/space/invisible removed); vectors in
  `contracts/shared_expenses/v1/label_key_vectors.json` (`labelKey` and `cleanLabel`, identical in SQL and Node).
- Compared against active/invited members of the same split by what people SEE (typed name, else live profile name). Renaming to your own current label
  (case/spacing/accents only) is always allowed; legacy duplicates are only checked when the label changes.
- Group-link placeholder names come from the live profile name, cleaned, and get ` (2)`, ` (3)` on a clash; a reserved or empty name becomes `PandaPay user`.
- A creator can have one active direct split per friend name (checked on `context.create`, `member.invite` into a direct split, and `member.rename`).
- Display names (join cards, audience, member labels) strip bidi, zero-width and control characters and are capped at 40 code points.
- This supersedes the earlier note above that two members may share a label: they may not any more.

## Decisions where the spec was ambiguous (safer choice taken)

1. The ciphertext is bound to the invitation id, which a group-link claim creates inside the database, so `claim_invitation` records only `declined/none/not_asked`
   and the API calls `attach_claimant_phone` (same transaction) to store a `shared` number. The SQL claim function therefore has one new optional parameter (`p_share`),
   not cc/hash/mask/enc/key. `claim_invitation_by_id` (phone-bound invites join immediately) is unchanged.
2. The hash and mask are stored only for `shared`. A `declined` claimant leaves no hash, so `check-phone`, `numberStatus`, look-alike and duplicate detection never apply to them.
3. The mask is cleared with the ciphertext on purge; only the last 4 digits (and the keyed hash, for joined people) remain. Account deletion also clears the hash, country code and `claimed_profile_id`, rejects a pending request and declines its placeholder member.
4. Purge happens: by trigger whenever a request leaves `awaiting_owner` (approve, decline, remove, leave, link replaced, any future path); lazily at expiry inside every list/reveal/check/claim; on link revoke (this also drops numbers of still-pending link requests, which stay approvable); hourly via `purge_expired_claimant_phones()` (scheduled only when pg_cron exists). The spec's "+24h" grace is not needed because expiry purges lazily. There is no claimant-cancel endpoint yet, so nothing to hook.
5. `reveal` returns JSON errors (`phone_not_available`, ...) instead of raising for conditions found after a lazy purge, so the purge commits.
6. Look-alike against existing members compares last 4 digits + country code of joined invitations (their full numbers are gone by design); against pending requests it compares the visible mask.
7. A failed uniqueness check rolls the whole command back, so a conflict is re-evaluated on replay rather than stored in the ledger.
8. `[[:alnum:]]`/`lower()` are locale dependent in Postgres, so `_label_key` uses explicit ASCII ranges and explicit letter maps; case folding of non-confusable Cyrillic/Greek letters depends on the database locale (UTF-8 locale assumed).
9. `phoneSharing` in preview is true when the flag is on and the key ring is usable even if the caller has no verified phone (then `ownPhoneMask` is null and the app shows its email-only notice).

## Tests

```
cd api && node --test test/shared_expenses_phone.test.js test/shared_expenses_notifications.test.js test/shared_expenses_commands.test.js
# Postgres (empty disposable database on loopback):
PANDAPAY_SHARED_EXPENSES_TEST_URL=postgres://postgres@127.0.0.1:55440/shared_expenses_test node --test db/tests/shared_expenses_postgres.test.js
PANDAPAY_SHARED_EXPENSES_NAMES_RACE_URL=postgres://postgres@127.0.0.1:55440/shared_expenses_names_race_test node --test db/tests/shared_expenses_names_race_postgres.test.js
```

---

# Join identity: security review fixes (supersede anything above that disagrees)

Applied in place to `20261116100000_shared_expense_join_identity.sql` (unshipped). Local undo: see "Local rollback" below.

- **Consent and replay.** `sharePhone` is part of the claim request hash, so a changed choice under the same `operationId` is `operation_conflict`.
  The SQL claim marks only a first (non-replayed) call with `fresh:true` (never stored in the ledger; the API strips it). The API attaches a number
  only when `fresh` is true, and `attach_claimant_phone` additionally requires that the request's `last_claim_op` is the same operation, that consent
  is still `not_asked` and nothing was captured yet. A replay, or a claim that a newer claim superseded, can never re-share.
- **"Ask without sharing" keeps no digits.** For `declined` and `none` the flat `verifiedPhoneSuffix` / `claimantPhoneSuffix` keys and
  `claimantPhone.last4` are `null`. `shared` keeps the last four (set by the attach), `not_asked` (old app) and phone-bound invites behave as before.
- **Friends list is private to its creator.** `friend_name_taken` (and `existingContextId`) is only produced when the caller is the creator acting on their own
  split (create, invite into a direct split, rename of the counterpart). The counterpart renaming their own row is never checked against the creator's list.
  A split only counts while its friend is still there: active, invited with a live invitation or none yet, or brand new (less than a day old with no counterpart).
  A removed/declined friend or an unanswered, expired invitation frees the name. The direct-split seat count ignores declined people.
- **Reveal budget.** Tap reveals and look-alike full numbers share 5 per hour and 30 per day per owner; look-alike disclosures also need the owner's verified phone
  and are charged once per request per hour. When the budget is spent the item stays `lookalike:true` but has no `fullNumber`; the list still succeeds.
  The API decrypts inside the reveal transaction and rolls it back (audit row included) when the ciphertext cannot be read, so a failed reveal costs nothing.
  `owner_phone_required` is its own 409 body.
- **check-phone** needs the owner's verified phone (`owner_phone_required`), is audited (`phone_reveals.via='check'`) and capped at 20 per owner per day (429 `check_rate_limited`), on top of 3 per request.
- **Caps before revival.** An expired group-link request is only revived when the hourly claim rate, the 20-pending cap and the member limit still allow it.
- **Pending only.** `numberStatus`, `lookalike` and `duplicateOf` are computed only while a request is pending; afterwards `unknown` / `false` / `[]`.
- **Names.** `label_key` now also folds Cyrillic ѕ ԁ ԛ һ ӏ ԝ ѵ and Greek ι ε κ υ τ β χ η ω γ μ, strips combining marks in every block (U+0300–036F, 1AB0–1AFF, 1DC0–1DFF, 20D0–20FF, FE20–FE2F) then recomposes,
  and drops symbols, emoji, punctuation and invisible characters (so emoji-only names are `invalid_member_name`). Reserved (`member_name_reserved`): exactly `you`, `me`, `myself`; anything starting
  with `owner`, `admin`, `support`, `someone`, `unknown`, `deleted`, `formermember`; anything containing `pandapay`. ("me" and "you" are exact-only on purpose: otherwise Meera, Mehul and Youssef would be refused.)
  Vectors (`labelKey`, `cleanLabel`, `reserved`) are in `contracts/shared_expenses/v1/label_key_vectors.json` and run against both SQL and Node.
- **Cleaning everywhere.** `_member_label`, preview `ownerName`/`contextName`, the context title, `maskName` and list names pass through the cleaner (bidi, zero-width, controls). Friend names are capped at 40 code points; group names keep their 120 limit
  (a 40 cap on group names would break existing ones) but lose invisible/bidi/control characters.
- **Purge.** The lazy purge is scoped to the rows being touched (the reader's own splits, or one request), uses `FOR UPDATE SKIP LOCKED` with a batch limit, and never fails a read: a read-only transaction or a lock problem just skips it.
  The hourly `purge_expired_claimant_phones()` does everything due (1000 per run) and is scheduled with pg_cron when that extension exists at migration time; without pg_cron, schedule it from the host.
  The hourly job does not know about the API flag: turning the feature off does not delete ciphertext already stored; it just stops being shown or revealed, and it is purged at resolution/expiry like any other.
- **Account deletion.** Indexed by `claimed_profile_id`. The `BEFORE DELETE` trigger on `public.profiles` also nulls `phone_reveals.owner_profile_id` and can never abort the deletion (any scrub error becomes a WARNING).
  `pandapay.execute_account_deletion` (shipped, not edited) ends in `delete from profiles`, so the same trigger covers it; data reset paths that delete the profile row are covered the same way.
- **Group-link requests notify the owner.** `invitation_audience(token)` also accepts the group-link token and resolves it to the caller's own request, so the owner gets one "<name> wants to join" row (deduped on replay, no phone data).
- **Config.** `docker-compose.prod.yml` and `.env.prod.example` carry `SHARED_EXPENSE_PHONE_SHARING_ENABLED` (default false) and `SHARED_EXPENSE_PHONE_ENC_KEYS` (no default); the API logs a key-free warning at startup when the flag is on and the ring is unusable.

## Local rollback (development databases only)

`docs/implementation/shared-expenses/rollback_join_identity_local.sql` removes everything this migration created (including the trigger on `public.profiles`, the table, the columns and every stored ciphertext) and restores the earlier definition of every function the migration replaced.
```
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -1 -f docs/implementation/shared-expenses/rollback_join_identity_local.sql
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -1 -f db/supabase/migrations/20261116100000_shared_expense_join_identity.sql
```
`db/tests/shared_expenses_rollback_postgres.test.js` (opt-in, `PANDAPAY_SHARED_EXPENSES_ROLLBACK_URL=postgres://.../shared_expenses_rollback_test`) proves the schema (functions with owners and grants, columns, indexes, triggers, constraints) is identical after rollback, that re-applying gives the same schema as the first application, and that it rolls back again.

## Corrected JSON

`claimantPhone` keeps its keys; `last4` is `null` for `declined` and `none`, and `numberStatus` is `unknown` (`lookalike:false`, `duplicateOf:[]`) once the request is resolved.
Claim reply (flag on): `{contextId, memberId, invitationId, status, phoneShare}` (the internal `fresh` marker never leaves the API). Reveal error bodies: `phone_not_available`, `owner_phone_required` (409), `reveal_rate_limited` (429).
