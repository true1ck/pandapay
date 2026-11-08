# Split / shared expenses: worst-case concurrency, idempotency and flag-transition report

Branch `split-labels`, 7 November 2026. Product code was not modified.
Method: real independent PostgreSQL 16 sessions (one throwaway container, loopback only, database created and dropped by the test),
every command run exactly as the API does it (`BEGIN; SET LOCAL ROLE app_user; set_config('app.user_id'); SELECT shared_expenses.fn(..); COMMIT`),
plus a no-database API layer test. Deadlock timeout was lowered to 200 ms in the container only to make cycles show up fast.

Run it:

```
docker run -d --name pp-worst-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:55461:5432 postgres:16
PANDAPAY_SHARED_EXPENSES_WORST_URL=postgres://postgres:pw@127.0.0.1:55461/shared_expenses_worst_concurrency_test \
  node --test db/tests/shared_expenses_worst_concurrency_postgres.test.js
node --test api/test/shared_expenses_worst_replay_api.test.js      # no database
```

Result of the last run (3 consecutive runs, identical outcome): DB suite 66 results (including the two top-level tests), 51 pass, 0 fail, 15 `todo` (each todo asserts the CORRECT behaviour and currently fails = a recorded defect);
API suite 9 tests, 6 pass, 3 todo. Todo tests turn green by themselves when the defect is fixed.

## Findings (bugs), most serious first

| Bug | Sev | What happens | Minimal repro | Regression test (todo) |
| --- | --- | --- | --- | --- |
| B15 | S1 | The changes feed silently skips events. `PROJECTION_FEED_SQL` ends with `SELECT profile_sequence::text ... ORDER BY profile_sequence`; the output alias (text) wins over the column, so `"10" < "2"`. A page filled with sequences 10.. is cut before 2..9, the cursor becomes (10,..) and events 2..9 are never delivered. Same at 99/100, 999/1000. | Reader at profile sequence 7, 12 accepted expenses in the stream, `limit=30`: sequences 8 and 9 never arrive (`E05`). Page size 3 from the start loses profile sequences 2..9 (`E02`, `E03`). | `E02`, `E03`, `E05` (control `E04` passes while the stream stays below 10) |
| B10 | S2 | `POST /shared-expenses/invitations/decline` binds 5 parameters but its SQL references only `$1,$2,$4,$5`; PostgreSQL rejects it with 42P18, so declining an invitation always returns 500. | `SELECT shared_expenses.decline_invitation($1::uuid,$2::text,$4::uuid,$5::text)` with 5 params. | DB `P02`, API `every parameter bound ... is referenced` |
| B01 | S2 | Authorization is checked before the context lock. A second `transfer_owner` by the ex-owner, already queued behind the first, still runs: two active owners. | Hold `transfer_owner(a->b)` open, start `transfer_owner(a->c)`, commit the first: owners afterwards = 2. | `B01` |
| B02 | S2 | Same root cause: an ex-owner's `invite_member` queued behind a transfer succeeds. | Same shape, `invite_member` as `a`. | `B02` |
| B03 | S2 | `leave_context` reads the member row (role/state) before the context lock and never re-reads it. A member promoted to owner while their leave is queued leaves; the active split has no owner. | Hold `transfer_owner(a->b)`, queue `leave(b)`, commit: active owners = 0. | `B03` |
| B05 | S2 | `submit_proposal` authorizes with `_can_read_context` before the context lock: a member whose leave has just committed still adds an expense. | Hold `leave(b)` open, queue `submit_proposal` as `b`, commit. | `B05` |
| B04 | S3 | Three parallel `leave_context` calls with different operation ids all pass (stale `m.state`): three `membership.left` events. | `Promise.all` of 3 leaves. | `B04` |
| B08 | S3 (privacy) | `reveal_claimant_phone` reads the invitation before `pg_advisory_xact_lock('reveal:owner')` and never re-reads it. A reveal waiting behind another reveal of the same owner returns (and audits) the ciphertext of a request that was rejected and purged while it waited. | Session 1 reveals request X and holds the lock; session 2 reveals Y (reads Y, waits); reject Y (trigger purges); commit session 1: session 2 returns Y's `enc`. | `L01` (`L02` shows check-phone does this correctly: row lock first) |
| B09 | S3 | Reply-lost retry of a COMMITTED `leave_context` or `transfer_owner` is answered 403 (`membership_not_authorized` / `context_not_authorized`) instead of the stored result, because the actor check precedes the idempotency lookup. The app reports an error although the leave/transfer happened. | Leave, then repeat with the same operation id. | `B09` |
| B06 | S3 | The "10 group-link requests per hour per claimant" cap is a count without a per-claimant lock; claims into different groups released together all pass. | 16 claims, 16 groups, one claimant, held at the context locks then released: 16 requests. | `C36` (control `C56`: sequential claims stop at 10) |
| B07 | S3 | Same for the "50 invitations per hour per issuer" cap across different splits. | 72 parallel `create_invitation` over 6 splits: 54 pass. | `C55` |
| B11 | S3 | `revoke_group_link` takes no context lock; a claim that already read the link survives the revoke and creates a request (and its number is not purged by the revoke). | Hold the context lock, queue a claim, revoke, release: request exists. | `B11` |
| B12 | S3 (liveness) | A member can leave while a pending EDIT of an already-accepted expense needs their approval (only never-accepted expenses block leaving). The edit can never be approved and there is no withdraw. | Accepted expense, full settlement, edit proposed, `b` leaves. | `B12` |
| B14 | S3 | `/invitations/claim` derives the request hash from the CURRENT phone-sharing flag. A lost-reply retry after a config flip carries a different hash for the same operation id and gets `operation_conflict`. | Claim with the flag on, flip off, retry. | API `lost-reply retry after the phone-sharing flag was flipped` |
| B13 | S4 | `/invitations/respond` hashes `JSON.stringify(body)` in arrival order (unlike `/commands`, which canonicalises). A retry with reordered keys becomes `operation_conflict`. | Two POSTs, keys reordered. | API `JSON keys arrive in another order` |

Note on B03: `take_over_ownership` works when no active owner with a profile exists, so an ownerless split can in principle be recovered by an active member; the defect is that the state can be reached at all.

Documented lock cycles (not bugs of correctness, both surface as `40P01` -> HTTP 409 `retryable_conflict`, both are real inversions):

| ID | Cycle | Test |
| --- | --- | --- |
| L03 | `claim_invitation` takes invitation row locks in its lazy phone purge (expired request with a stored number) BEFORE the context lock; `respond_invitation` takes context -> invitation row. Deterministic deadlock with one victim. | `L03` (passes: asserts exactly one 40P01 and HTTP 409) |
| L04 | `register_phone`: two users swapping phone hashes (DELETE of the other row, then upsert of the own row) deadlock. | `L04` (passes; 0-2 victims per 6 rounds) |

## Scenario table

PASS = executed assertions held. BUG = a todo regression test above. IDs match the test names.

| ID | Scenario | Method | Result | Sev |
| --- | --- | --- | --- | --- |
| C01/C01b | `context.create` (group and direct, friend-name lock path) x10 parallel + late retry | real sessions | PASS: 1 context, 1 member, 1 event, 1 receipt, identical result | - |
| C02-C08 | invite, rename, membership.respond, propose, respond (journal posted once, balance 500 once, 2 cost facts), settlement.report, settlement.respond (1 terminal event, 1 journal line) x10 parallel + late retry | real sessions | PASS | - |
| C09-C14 | invitation.create (op id = invitation id), link claim, invitation.respond (1 binding), group-link create, group-link claim (1 request, 1 placeholder member), claim-by-id x10 | real sessions | PASS | - |
| C15, C15c, C15d | leave / transfer x10 (one effect, losers stored result or clean 403), remove_member x10, take_over x10 | real sessions | PASS (late retry of leave/transfer: B09) | S3 |
| C20 | same operation id + different body / different kind / other context -> `operation_conflict`; same body replays; other actor may reuse the id; two different bodies racing on one new id: exactly one wins | real sessions | PASS | - |
| C21 | replay after member left (403, nothing re-applied), link revoked (404 `invitation_unavailable`, stored result NOT returned, no request resurrected), approved by someone else, proposals flag off/on | real sessions | PASS | - |
| C22 | number purged then claim replayed / `attach_claimant_phone` replayed: exactly one of 8 parallel attaches lands, none after purge, superseded operation cannot attach | real sessions | PASS | - |
| C30 | two approvals of one revision by two approvers + a repeat: applied once (`head_version`=1, 2 journal lines); approve vs reject by different people never accepts; same person approve vs reject -> `approval_conflict` | real sessions | PASS | - |
| C31 | approve vs leave; two revisions sharing one expected head (void vs edit): exactly one becomes head, other `revision_head_conflict` | real sessions | PASS | - |
| C32 | 3 settlement reports + 5 racing confirm/reject: <=1 terminal event each; settle vs expense edit; invariants hold | real sessions | PASS | - |
| C33 | transfer x2 + remove + leave x2 + take_over racing: exactly one active owner | real sessions | PASS (this interleaving; the queued-behind-the-lock variants are B01-B04) | - |
| C34 | rename vs rename vs remove, same name from three members, invite same name twice (label-key uniqueness invariant) | real sessions | PASS | - |
| C35 | two owners respond to one join request (1 winner, 3 `invitation_conflict`); approve vs revoke vs expiry | real sessions | PASS | - |
| C36b, C37, C38 | same user claims one group x12 (1 request, 1 event); same phone invited twice (1 open); friend created x8 from two spellings (exactly 1, others `friend_name_taken`); same context id from two devices | real sessions | PASS | - |
| C50 | 20-pending cap, 50 parallel claimants | real sessions | PASS exactly 20 pass, 30 `join_requests_full` | - |
| C51 | member cap 200: 20 parallel invites (exactly 4 pass), 15 parallel link claims (exactly 3 pass) | real sessions | PASS | - |
| C52 | reveal cap: 20 parallel reveals on 20 requests -> exactly 5 ciphertexts, 5 audit rows; 12 on one request -> 5; daily cap 30 | real sessions | PASS | - |
| C53 | check-phone: 12 parallel on one request -> exactly 3 counted attempts; 20/day per owner under 24 parallel | real sessions | PASS | - |
| C54 | directory lookup 25/day under 40 parallel | real sessions | PASS exactly 25 | - |
| C36 / C55 | 10/hour claim cap and 50/hour invitation cap across different splits | barrier + real sessions | BUG B06 / B07 | S3 |
| B01-B05 | stale authorization after a queued lock wait | held lock + queued session | BUG | S2/S3 |
| B08, L01/L02 | reveal vs resolve; check-phone vs resolve | held advisory/row lock | B08 BUG / L02 PASS | S3 |
| L03, L04 | lock inversion cycles | pinned receipt slot; swap loop | documented 40P01 -> 409 | S3 |
| L10, L11 | mixed random workload (16 workers x 700 ops, 20 workers x 900 ops; propose, respond with 20% immediate replays, settle, rename, invite, direct-friend creation with colliding names, link claim/approve, leave, transfer, relink, remove, flag flips, register) | seeded PRNG (20261107, 7) | PASS: no error maps to HTTP 500, 0 unabsorbed deadlocks, all invariants hold afterwards (journal = pair balances = member balances = 0 sum, gapless context and profile sequences, no receipt without result, label/profile uniqueness, an owner everywhere) | - |
| L12 | 14 workers, 420 ops on direct splits (create/invite/rename, 5 colliding names, 3 creators) | seeded PRNG | PASS: 0 deadlocks, one live split per friend name per creator | - |
| F01 | accepted_writes off: approval parks as `awaiting_activation` (event stays `expense.responded`), nothing posted. **F5 answer: turning the flag on does NOT re-evaluate parked revisions**; replaying the old approval returns the stale parked answer; a NEW respond_expense by an approver or the author re-evaluates and accepts exactly once | real sessions | PASS (behaviour pinned) | - |
| F02 | flag flips while a command is queued: accepted_writes and settlements are read AFTER the lock (parked / `feature_disabled`, refused confirm leaves no event or receipt; reject still allowed while settlements off) | held context lock | PASS | - |
| F03 | reads off or proposals off: EVERY command, including leave, remove, transfer, take-over, link revoke, create, lookup, answers `feature_disabled` and writes nothing | real sessions | PASS | - |
| F04 | accepted_writes flipped 12 times while 6 approvals run: stored head always equals the reported status | real sessions | PASS | - |
| E01 | each committed command emits exactly its events (failures none); per-split events consecutive on every member stream | real sessions | PASS | - |
| E04 | control: feed below sequence 10 pages with no loss at page size 1, 2, 3, 50 | real sessions | PASS | - |
| E02/E03/E05 | feed paged while writers run / mixed events / deterministic | real sessions | BUG B15 | S1 |
| P01 | lazy purge (list_join_requests, list_invitations), hourly purge x4, reveal x6, approve x3 all in parallel | real sessions | PASS: no resolved/expired request keeps a ciphertext, no live request loses its number | - |
| API | every `RAISE EXCEPTION` code in the shared-expense migrations (61) maps to a non-500 status; 40P01/40001 -> 409 retryable; 23505 -> 409; command hash is key-order independent and body-unique; 20 parallel identical POSTs bind one (operation, hash); phone flag off -> reveal/check 404 with zero queries and no consent stored | fake client | PASS | - |

## Lock ordering (every lock, per function)

Convention seen in code: `receipt -> (friends/lookup advisory) -> context row -> member/invitation/expense rows -> (advisory per split / per creator / per owner) -> profile heads in ascending profile id (inside _emit, last)`.

| Function | Locks, in order |
| --- | --- |
| every command via `_operation` | receipt insert (unique-index wait on the same actor+operation), receipt row FOR UPDATE |
| create_context (direct) | advisory `friends:<actor>`, new context row, heads (asc) |
| create_context (group), membership.respond, report/respond_settlement, create_invitation, create_group_link, take_over | context row |
| invite_member | context row -> advisory `hashtext(ctx)` -> (direct, creator) advisory `friends:<creator>` |
| rename_member | context row -> member row -> (name changes) advisory `hashtext(ctx)` -> (direct, creator) advisory `friends:<creator>` |
| submit_proposal, respond_expense | context row -> expense row |
| remove_member, transfer_owner | context row -> member row |
| leave_context | unlocked member read -> context row (B03/B04/B09) |
| claim_invitation (token) | lazy purge: invitation rows FOR UPDATE SKIP LOCKED (updates them) -> context row -> invitation row (L03 inversion) |
| claim group link | context row -> advisory `hashtext(ctx)` -> pending invitation row; link read is unlocked (B11) |
| respond_invitation, claim_invitation_by_id | context row -> invitation row -> member rows (bind) |
| decline_invitation | invitation row only |
| revoke_group_link | none (B11) |
| reveal_claimant_phone | purge (SKIP LOCKED) -> advisory `reveal:<owner>`; invitation read is unlocked (B08) |
| check_claimant_phone | purge -> invitation row FOR UPDATE -> advisory `reveal:<owner>` |
| list_join_requests_enc | purge -> advisory `reveal:<owner>` |
| attach_claimant_phone | invitation row |
| lookup_phone | advisory `shared_lookup:<actor>` |
| register_phone | other user's directory row (DELETE) -> own row (upsert) (L04) |
| `_emit` (all events) | context row update, then `profile_stream_heads` rows in ascending profile id; only one `_emit` per transaction, so heads cannot cycle |
| hourly purge | invitation rows SKIP LOCKED (never waits) |

Cycles: two found and demonstrated (L03, L04). All other pairs are acyclic by construction (context row always before row locks; advisory keys always acquired after the context row, `friends:` always last) and survived 3 x ~1,700 mixed operations at 16-20 workers plus 420 friend-name operations without a single unabsorbed deadlock. Caveat: all advisory keys are 32-bit `hashtext()` values in one key space (`friends:`, `reveal:`, context ids); a collision would only add contention, but it could in theory create a cycle the table above does not show.

## Not covered / honest limits

- Source funding commands (`inspect_source`, `admit_source`, bill metadata beyond one proposal path) and the account-deletion trigger `_scrub_profile_phone` were not raced.
- Post-commit push notifications were checked only for their dedupe key shape (`split:<operation>:<recipient>`), not against the real `notifications` table.
- pg_cron scheduling of the hourly purge was not exercised; the purge function itself was run concurrently (P01).
- Timing: the container ran with `fsync=off` and a 200 ms deadlock timeout; absolute latencies are not representative.
- `lock_timeout` is not set by `withUserClient`; a command stuck behind a lock ends as `57014` statement timeout, which `sendError` maps to a bare 500 (pinned in the API test as current behaviour).
