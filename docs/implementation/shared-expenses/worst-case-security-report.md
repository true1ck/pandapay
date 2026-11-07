# Shared Expenses / Split — Worst-Case Adversarial Security Pass (2026-11-07)

Scope: `api/src/shared_expenses/*` (routes.js, invitations.js, commands.js, validation.js, domain.js,
label.js, phone_crypto.js) exercised end-to-end against the local stack (API :4001, auth :3210,
Postgres `pp-split-labels-pg` :55437) with throwaway `SEC *` accounts. No product code was modified.
All attacker accounts, contexts, expenses, settlements and invitations created for this pass are
throwaway fixtures (`SEC SA`..`SEC SX`, `SEC V*` prefixed display names) and are safe to leave in the
local DB or drop.

Legend: PASS = defended correctly as attacked. FAIL = did not behave as the defender would want.
BUG = a defect was found but is not itself a cross-tenant/data-exposure vulnerability.
Severity: S1 = cross-tenant data exposure/IDOR, S2 = meaningful abuse/DoS/weak control, S3 = robustness/hygiene.

## S01 — Authorization matrix

Every GET route under `/shared-expenses/*` that takes a `:contextId` (totals, members, expenses,
expense, revisions, settlements, balances, activity, invitations, operations, groups/link) was called
against a real context (`T1`, owned by `SEC SA`, with members `SEC SB` and pending claimant `SEC SC`)
as:

| Caller | Result |
|---|---|
| Unrelated stranger (`SEC SG`, member of no related context) | `404 context_not_found` on all directly data-scoped routes; `403 context_not_authorized` on `/invitations` and `/groups/:id/link` (see oracle check below) |
| Unauthenticated (no `Authorization` header) | `401 session_invalid` uniformly |
| Expired JWT (`exp` in the past, otherwise valid claims/signature) | `401 session_invalid` uniformly |
| Forged JWT (correct claims, signed with a wrong secret) | `401 session_invalid` uniformly |
| Wrong-audience JWT (`aud` != `mobile-app`) | `401 session_invalid` uniformly |
| JWT for a `sub` that doesn't exist in the DB at all | `401 session_invalid` uniformly |
| Member of a **different** context (`SEC SE`, a member of T2 only) hitting T1's contextId | `404 context_not_found`, same as a total stranger |
| Cross-tenant owner (`SEC SD`, owner of T2) reading T1's expense by id | `404 context_not_found` (context check runs before expense lookup) |
| Owner of T1 (`SEC SA`) reading a truly nonexistent expense id inside T1 | `404 expense_not_found` |

**Oracle check** — does any route let a caller distinguish "exists, but you're forbidden" from
"doesn't exist"? Two routes (`GET /contexts/:id/invitations`, `GET /groups/:id/link`) return `403
context_not_authorized` for **both** a real-but-foreign context id and a fully random UUID — this is
uniform (no oracle), it is simply a different status code family (403 vs 404) than the other routes.
Verified directly: both a real T1 id and a random UUID returned identical `403 context_not_authorized`
for the same stranger caller, with no timing or body difference worth reporting.

Verdict: **PASS**. No IDOR, no existence oracle, uniform handling of unauthenticated/expired/forged/
wrong-audience/unknown-subject tokens, and member-of-another-context callers are treated exactly like
strangers.

| ID | Attack | Expected | Actual | Verdict | Sev |
|---|---|---|---|---|---|
| S01-a | Cross-tenant/stranger read of every context-scoped GET route | Uniform 403/404, no info leak | As above | PASS | — |
| S01-b | Unauthenticated / expired / forged / wrong-aud / unknown-sub tokens | 401 uniformly | 401 `session_invalid` uniformly | PASS | — |
| S01-c | Existence oracle on `/invitations`, `/groups/:id/link` | No distinguishable signal | Identical 403 for real-forbidden vs nonexistent | PASS | — |

## S02 — Input attacks

| ID | Attack | Expected | Actual | Verdict | Sev |
|---|---|---|---|---|---|
| S02-01 | SQL injection strings in `:contextId` path param | 400 invalid_input (fails UUID shape check before reaching SQL) | `400 invalid_input` for every variant (`' OR '1'='1`, `;DROP TABLE...--`, URL-encoded, trailing `--`, `../../etc/passwd`) | PASS | — |
| S02-02 | SQL-injection-looking text, giant string, NUL byte, bidi override, zero-width, NFD unicode, wrong types, null as a `displayName` | Either accepted as legitimate free text (parameterized storage) or rejected with 400 | SQL-looking text, bidi/zero-width/NFD: accepted (200, stored verbatim — correct, no injection since queries are parameterized). 100KB string: `413 payload_too_large` (JSON body limit, correct). Wrong types (object/number/null): `400 invalid_input`. **NUL byte (`\u0000nullbyte`): `500 internal_error`** instead of 400 | **FAIL (bug)** | S3 |
| S02-03 | Negative/huge/hex/float/exponent/whitespace/leading-zero `amountMinor` | 400 invalid_amount | All 10 variants rejected (`400`, mix of `invalid_settlement`/`invalid_amount` depending on which field failed first) | PASS | — |
| S02-04 | Mass assignment (extra fields `role`, `isAdmin` in a command payload) | 400, extra fields rejected | `400 invalid_input` (payload key allowlist enforced by `v.record`) | PASS | — |
| S02-05 | Prototype pollution via literal `"__proto__"` JSON key in payload | Rejected, no global pollution | `400 invalid_input` (payload still has only the allowed keys after `JSON.parse`/`canonicalJson` round-trip; `__proto__` as an **own property is dropped** because `v.record` uses `Object.getPrototypeOf(value)` checked against `Object.prototype`/`null` and then an allowlist of own keys) and `({}).polluted === undefined` confirmed after the call | PASS | — |
| S02-06 | Duplicate JSON keys (`"displayName":"First","displayName":"Second"`) | Standard JSON semantics (last wins), no special/double-processing | Parsed normally, last value wins, single row written | PASS | — |
| S02-07 | Huge query string (50 fake UUIDs as a query param) | 400 (route doesn't expect a query string at all) | `400 invalid_input field=query` | PASS | — |
| S02-08 | Deeply nested object (500 levels) as `displayName` | 400 (wrong type) | `400 invalid_input` | PASS | — |
| S02-09 | Request body > 100 KiB | 413 | `413 payload_too_large` | PASS | — |
| S02-10 | Content-Type confusion (`text/plain` / `application/xml` with a JSON body) | 400 invalid_json/unsupported | `400 invalid_input` (body parsed as empty/invalid since express.json only parses `application/json`) | PASS | — |
| S02-11 | CRLF / header-injection shaped string in the URL path | 400 (fails UUID validation) | `400 invalid_input` | PASS | — |
| S02-12 | Path traversal in `operationId` route param | 400 | `400 invalid_input` | PASS | — |
| S02-13 | 30 concurrent identical reads (small DoS shape) | All served correctly, no crash | 30/30 `200` in ~70ms total | PASS | — |

### S02 finding in detail — NUL byte crashes `member.rename` / `member.invite` to a 500

`commands.js`'s `memberName()` validator only checks `cleanLabel(value)` (which **does** strip control
characters, including NUL) is non-empty — it does not reject the **raw** value for containing control
characters the way the stricter `text()` validator (used for `context.create`'s `name` field) does.
The uncleaned raw string — e.g. `"\u0000nullbyte"` — is therefore forwarded verbatim as a JSON payload
to `shared_expenses.rename_member`/`invite_member`. PostgreSQL `text` cannot store a NUL byte at all,
so the query throws a Postgres error that is not one of the mapped `SQL_ERRORS`/`MISSING_SCHEMA` codes,
and `sendError()` falls through to a generic `500 internal_error`.

Verified not to leak anything: the request log only records `{level:"error", status:500, requestId,
method, path, durationMs}` — no stack trace, no SQL error detail, no payload — so this is a robustness
defect, not an information-disclosure one. Severity **S3** (crash/un-mapped-error path, not
cross-tenant or data exposure — a malicious or buggy client can force a 500 on this one endpoint per
request, which is a very mild denial-of-service nuisance at worst, bounded by normal auth + rate
limiting).

**Fix suggestion**: make `memberName()` use the same control-character rejection regex as `text()`
(`/[\u0000-\u001f\u007f]/`), or simply store `cleanLabel(value)` instead of the raw value, before it
is ever sent to Postgres. A regression test demonstrating current behavior is at
`api/test/shared_expenses_worst_security_input.test.js` (`SEC-INPUT-02`).

## S03 — Specific flows

| ID | Attack | Expected | Actual | Verdict | Sev |
|---|---|---|---|---|---|
| S03-01 | `reveal-phone` by cross-tenant owner (owns T2, not T1) on T1's pending invitation | 403 | `403 context_not_authorized` | PASS | — |
| S03-02 | `reveal-phone` by a regular (non-owner) T1 member | 403 | `403 context_not_authorized` | PASS | — |
| S03-03 | `reveal-phone` by the claimant themself (trying to read back their own shared number through the owner-only endpoint) | 403 | `403 context_not_authorized` | PASS | — |
| S03-04 | `reveal-phone` rate limit (sequential, same owner/invite) | Capped at a small N, then 429 | 5 succeed, 6th returns `429 reveal_rate_limited` (confirmed in earlier project fixtures `qc1.cjs`, re-confirmed live) | PASS | — |
| S03-05 | `reveal-phone` rate limit under **concurrency** (race condition check: fire N requests for distinct invites, then 10 concurrent requests for a single invite) | Cap holds exactly even under a race (no overshoot from a check-then-act race) | 3 sequential reveals (different invites) + 10 concurrent (same invite) ⇒ exactly 2 more succeeded before 429s, total 5 = the cap. No overshoot. | PASS | — |
| S03-06 | Key-ring tampering: move an invitation's encrypted phone ciphertext row-to-row (simulating a DB-level swap/replay attack) | Decrypt must fail (AAD/invitation-id binding), not silently return the wrong person's number | `409 phone_not_available` — the transaction (including the audit row) rolled back rather than ever returning the wrong plaintext | PASS | — |
| S03-07 | Replay of an old `operationId` by a **different actor** | Each (actor, operationId) pair is independent — not a global idempotency key, so this is not itself unsafe, but same-actor-same-opId-different-payload must still 409 | Different actor reusing the same opId got a completely independent, successful operation (expected: operationId is scoped per-actor). Re-verified explicitly: same actor + same opId + **different** payload ⇒ `409 operation_conflict`; same actor + same opId + **identical** payload ⇒ idempotent `200` replay with unchanged requestHash | PASS | — |
| S03-08 | Invitation token guessing/brute force (8 random well-formed-looking tokens against `/invitations/preview`) | 404 for all (no oracle), ideally rate-limited for sustained guessing | All 8 returned `404` cleanly; no distinguishing signal | PASS | — |
| S03-09 | Claim with a tampered (single-char-flipped) token derived from a real one | 404, not "close enough" | `404 invitation_unavailable` | PASS | — |
| S03-10 | Owner claims/joins their own group's invite link | Must not create a duplicate/self membership weirdness | `200 joined` against their own existing owner membership (idempotent, no duplicate row, no privilege change) | PASS | — |
| S03-11 | Group-link token reuse **after revoke** | 404/410, no join | `404 invitation_unavailable` | PASS | — |
| S03-12 | Forwarded link-only invite claimed by multiple independent strangers | Each becomes its own pending join request (`awaiting_owner`), no auto-join | Both strangers got `awaiting_owner`, no auto-admit | PASS | — |
| S03-13 | Accept a **phone-bound** invite with a **different verified phone** than the one it was bound to | Rejected (`invitation_phone_mismatch` or similar) | Setup for this check hit a pre-existing `409 invitation_conflict` from fixture reuse across repeated runs (the specific target already had a live invitation) — retested in isolation below | See note | — |
| S03-14 | Owner **after transferring ownership away** tries `reveal-phone` / `respond` on a new pending invite in that context | 403, no residual privilege | Both `403 context_not_authorized` | PASS | — |

Re-test of S03-13 in isolation (fresh phone number, fresh invitation) confirmed the intended behavior:
a phone-bound invitation created for one verified phone number is rejected when claimed by an account
verified with a **different** phone (`invitation_phone_mismatch` from the SQL layer, surfaced as `409`
by the route, or `409 phone_not_verified` if the claiming account has no verified phone at all) — this
matches the code path in `invitations.js`'s `claim` handler and is consistent with the dedicated
`shared_expenses_phone.test.js` and `shared_expenses_invitations.test.js` unit-test fixtures already in
the repo, which assert the same invariant directly against `claim_invitation`.

## S04 — Enumeration / privacy

| ID | Attack | Expected | Actual | Verdict | Sev |
|---|---|---|---|---|---|
| S04-01 | `lookup_phone` oracle: registered+discoverable number vs registered+`discoverable:false` number vs never-registered number | Non-discoverable and never-registered must look identical (`found:false`) | registered+discoverable → `found:true` with masked name; registered+non-discoverable → `found:false`; never-registered → `found:false` — indistinguishable | PASS | — |
| S04-02 | Scrape cap: 25 lookups in a row from one account | Rate-limited well before 25 | 22 succeeded, then `429 lookup_rate_limited` for the rest, and the very next lookup after the burst also 429'd (cap persists, doesn't reset) | PASS | — |
| S04-03 | Self-lookup (looking up your own verified number) | `self:true`, not a generic "found" | `{found:false, self:true}` | PASS | — |
| S04-04 | `discoverable:false` respected in the invitations inbox (a non-discoverable, phone-verified user has no inbox leakage beyond their own items) | Inbox shows only items addressed to this user | `{phoneVerified:true, items:[]}` for a user who is non-discoverable and has no pending invites — consistent | PASS | — |
| S04-05 | Roster `profileId` exposure to a regular (non-owner) member (E12) | — (no strict expectation in the code/docs; flagged for review) | A regular member **can** see every other active member's raw `profileId` (internal account UUID) via `GET /contexts/:id/members`, e.g. `{"displayName":"SEC SA","profileId":"3236b733-...","role":"owner"}` visible to a non-owner member `SEC SB` | **Flagged (by-design, worth confirming)** | S3 |
| S04-06 | Key-ring tamper cross-check (duplicate of S03-06, reconfirmed from the privacy angle) | Must not cross-leak another claimant's phone | `409 phone_not_available` | PASS | — |

### S04 finding in detail — `profileId` visible to any context member (E12)

Every member of a shared-expense context (not just the owner) can see every other member's raw
`profileId` through `GET /shared-expenses/contexts/:contextId/members`. `profileId` is the account's
internal UUID (the same value used as `sub`/`userId` in that user's own JWT and as the primary key of
`public.profiles`). This is not by itself an authentication or authorization bypass — nothing in the
codebase accepts a bare `profileId` as a capability or lets one account act "as" another via it, and
every protected route re-derives the actor from the caller's own verified session, never from a
client-supplied id — but it is an internal-identifier disclosure to co-members that is worth a product
decision: if there is ever a future endpoint that treats a `profileId` as semi-secret (e.g. an
enumeration surface, a cache key, a support lookup), member rosters already hand it out. Given the
docs for this feature explicitly engineer around *not* revealing more than a masked name/phone, this is
inconsistent with that stated privacy bar even though no concrete exploit chain was found. Severity
**S3** (info disclosure, no demonstrated path to higher impact).

## S05 — Account lifecycle

Target: throwaway account `SEC SW`, built up with real split data before erasure:
- Owned a group context (`SEC erase target`) with an active member (`SEC SV`) and a pending,
  phone-shared claimant (`SEC SX`, invitation never approved).
- Proposed and had approved one expense (`SEC erase expense`, 2000 minor, split 1000/1000).
- Had one settlement reported against them by the other member.
- Had a `phone_directory` row (registered + discoverable) and a `claimant_phone_enc` row from an
  earlier claim in a different test's context.

| Check | Before erase | After `POST /account/erase` | Verdict |
|---|---|---|---|
| HTTP result | — | `200 {erased:true}` | PASS |
| `shared_expenses.members` row with `profile_id = SW` | 1 | **0** — `profile_id` set to `NULL` via `ON DELETE SET NULL` FK (`members.profile_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL`), row itself (role=owner, state=active) retained | PASS (intended design — see below) |
| `shared_expenses.phone_directory` row for SW | 1 | 0 (removed by `pandapay.reset_account_data`, invoked internally by `execute_account_deletion`) | PASS |
| `shared_expenses.phone_reveals` (audit) referencing SW's invitations | 0 (none generated in this run) | 0 | N/A |
| Expense, settlement, member-state and balance history for the context | present | **fully preserved** — the expense, its approved revision, and the settlement remain exactly as before | PASS |
| Live member listing (`GET /contexts/:id/members`) label for SW's now-anonymized owner row | "SEC SW" (via live profile lookup) | **"Former member"** (via `shared_expenses._member_label`, which falls back to this exact string when both the stored label and the profile are gone) — this matches the explicit design comment in `20261114040000_shared_expense_owner_and_former.sql`: *"People whose account was deleted show as 'Former member' (history and balances stay)"* | PASS |
| Context ownership after an owner is erased | still has an "owner" row, now identity-less | `POST /shared-expenses/contexts/take-over` by the remaining active member (`SEC SV`) succeeded (`200 {status:"owner"}`), reassigning ownership cleanly | PASS |
| Full `shared_expenses.*` scan for every `uuid`-typed column still equal to SW's profile id | — | Several append-only/audit tables still carry the **opaque id** as a historical actor reference: `invitations.issuer_profile_id`, `expense_revisions.author_profile_id`, `contexts.created_by`, `expenses.created_by`, `revision_members.approver_profile_id`, `revision_approvals.actor_profile_id`, `operation_receipts.actor_profile_id`, `context_events.actor_profile_id`, `profile_events.profile_id`, `profile_stream_heads.profile_id`, `group_links.created_by` | **Flagged for review, not a FAIL** — these are append-only ledger/audit tables (operation receipts, event stream, profile event stream) that intentionally retain an opaque actor reference for financial/audit integrity even after the account is gone (exactly analogous to how a bank keeps "who authorized this transaction" after an account closes). None of them carry the person's *name*, *phone number*, or any other PII — only the UUID, which by itself resolves to nothing once the matching `profiles` row is deleted. This matches `pandapay.execute_account_deletion`'s own documented design (it only nulls *nullable FK columns to `profiles`*, explicitly skipping columns literally named `profile_id` which are handled by dedicated `ON DELETE SET NULL` FKs, and it never touches not-null append-only actor columns at all by design) |
| Erased account's still-cryptographically-valid JWT used against `/shared-expenses/contexts` | — | `403 membership_required` — the live membership check (`promotions.current_user_is_member()`) fails once the `profiles` row is gone, so the token is practically unusable for this feature immediately, with no need to wait for revocation | PASS |
| `POST /account/data-reset` on a live account (`SEC SV`, keeps login) | SV active member of several contexts | `{reset:true}` (200); SV's membership rows in those contexts were **not** deleted (data-reset intentionally keeps product "shape" per its own doc comment: *"erases personal product data but keeps login"* — shared-expense membership tied to other people's contexts is correctly treated as shared/joint data, not purely personal, and left intact) | PASS |

Re-registration-after-erasure (new account, same phone number, can it see/claim the old owner's data)
was **not** separately re-tested as its own throwaway flow in this pass beyond the above, because the
erased member row no longer carries a `profile_id` to re-bind to, and a brand-new signup gets a brand
new `profiles.id` — there is no code path that maps a reused phone number back onto a stale, now
`NULL`-profile member row. This is consistent with `_member_label`'s fallback already covering the
"profile gone" case and is a reasonable, low-risk design; flagged here only as something to keep in
mind if a future "merge my old data" feature is ever added for re-registering users.

## S06 — Log / leak grep

Grepped `scratchpad/logs/*.log` (the full local API/auth/build logs produced during this session,
including every attack above) for:
- Indian phone numbers (`+91[0-9]{10}`) — **none found**.
- JWT-shaped tokens (`eyJ...`) — **none found**.
- The literal words "secret", "stack trace", or Node stack-frame markers (`at Object`, `at async`) —
  **none found**.
- Postgres `DETAIL:`/`STATEMENT:` verbose error dumps — **none found**.

The structured request logger (`observability.js`'s `requestLogger`) only ever emits
`{level, ts, requestId, method, path, status, durationMs, authenticated}` — confirmed directly against
the 500-triggering NUL-byte request from S02: the log line for that request carries no body, no error
message, and no stack trace. **PASS**.

## S07 — Unauthenticated / flag-gated routes

| Route | Expected | Actual | Verdict |
|---|---|---|---|
| `GET /split/join/:token` (public landing page, no auth) | Public by design; must never touch the DB or reveal anything about the invite (per its own code comment) | Returns a static HTML page for any `TOKEN`-shaped (43-char base64url) value, `404 Not found` for a malformed one — confirmed both branches never query the database (read directly from source: the handler only regex-tests the token shape before building a static string) | PASS |
| Any `/shared-expenses/*` route with **no** `Authorization` header at all (not just an invalid one) | 401 | `401 session_invalid` | PASS |
| `/shared-expenses/invitations/reveal-phone`, `/check-phone` when the phone-sharing feature flag is on (this stack's configuration) | Reachable, gated correctly by ownership | Reachable and correctly gated (see S03) — could not be re-tested with the flag *off* without restarting the already-running stack, which the test brief explicitly disallowed | Not tested (flag is fixed for this stack) |

## Summary of findings, ranked

1. **S3 — `member.rename`/`member.invite` displayName crashes to `500 internal_error` on a NUL byte**
   (`api/src/shared_expenses/commands.js`, `memberName()`). No data exposure; no stack trace or
   sensitive detail leaks in logs. Minor DoS-shape nuisance only (an authenticated member of a context
   can make their own rename/invite request 500 instead of 400). **Fix**: validate the raw value with
   the same control-character regex `text()` uses (or persist `cleanLabel(value)`) before it reaches
   SQL. Regression test: `api/test/shared_expenses_worst_security_input.test.js` → `SEC-INPUT-02`.

2. **S3 — co-members can see each other's raw internal `profileId` in context rosters** (E12,
   `GET /shared-expenses/contexts/:contextId/members`). No demonstrated exploit path (every protected
   route re-derives the actor from the caller's own verified session, never from a client-supplied
   `profileId`), but it's an internal-identifier disclosure that is inconsistent with this feature's
   otherwise careful masked-name/masked-phone privacy posture, and worth a deliberate product decision
   rather than an incidental side effect of the current query shape.

3. Everything else tested — the full authorization matrix (S01), SQL injection/mass-assignment/
   prototype-pollution/body-size/content-type/path-traversal/parallel-DoS-shape input attacks (S02
   apart from the NUL byte), reveal-phone/check-phone/join-request authorization re-runs including
   under concurrency, key-ring/ciphertext-swap tampering, operation replay semantics, invitation token
   guessing, group-link revoke/reuse, phone-bound invite phone-mismatch, former-owner residual access,
   the `lookup_phone` enumeration oracle and scrape cap, `discoverable:false` enforcement, and the full
   account-erasure lifecycle including take-over-after-owner-erased — all **passed** as designed, with
   no cross-tenant data exposure (S1) and no meaningful abuse primitive (S2) found.

## Fixtures used

All test data uses `SEC `-prefixed display names / account labels and lives in the local
`pp-split-labels-pg` Postgres container only (`pandapay`/`pandapay_auth` databases). Scripts used to
drive this pass (throwaway, in the session scratchpad, not committed): `sec/users.cjs`,
`sec/setup.cjs`, `sec/resources.cjs`, `sec/s01_authz_matrix.cjs`, `sec/s01_oracle2.cjs`,
`sec/s02_input_attacks.cjs`, `sec/s03_flows.cjs`, `sec/s04_enum_privacy.cjs`, `sec/s05_lifecycle.cjs`.


---

# Follow-up: E7 erasure completeness and re-registration / number reuse (A13)

Same stack, same rules, no product code changes. Throwaway accounts `EZ` (erase target, name
"SEC Zed Erasable", +919500000030), `EV` (counterpart), `EP` (phone-bound invitee), `EQ`, `LA/LB/LO`.
Method: build the account, snapshot, `POST /account/erase` (200 `{erased:true}`), then a server-side
scan of every base table in every non-system schema (`row::text ILIKE`) for: the profile id, the name
fragment "Zed", the phone digits, the bank-reference marker "SECBANK", the email, and the phone HMAC.
Scripts (scratchpad, not committed): `sec/s05b_build.cjs`, `sec/scan.cjs`, `sec/s05c_rereg.cjs`.

Data built for EZ: `private_cost_facts` (approved 3000 expense, share 1500), two
`settlement_private_references` (one EZ-owned "HDFC-SECBANK-REF-9911", one EV-owned "UPI-SECBANK-REF-7788"),
an unsettled pair balance (EV owes EZ 1500), a pending proposal authored by EZ, an open phone-bound
invitation issued by EZ for EP's number, an active group link, a self-chosen member label ("Zed
Erasable Person"), and one `source_resources` row whose `private_snapshot` carries a merchant name, a
phone number and a bank marker. Note: `source_resources` was seeded by direct SQL because the API can
only admit a v2 SMS event with full ledger fixtures (legacy sources are "explicit review required"),
so this class is shown at table level, not via a real admission. No receipts/attachments tables
exist in `shared_expenses` (31 tables, none for files), so that class does not apply.

## E7 results: what survives `/account/erase`

| ID | Data class | After erase | Contains PII? | Verdict | Sev |
|---|---|---|---|---|---|
| E7-01 | `profiles` row, `phone_directory` row, EZ's own `notifications` (2 rows), `members.profile_id` | removed / nulled | n/a | PASS | |
| E7-02 | `settlement_private_references.reference` owned by EZ (bank/UPI reference) | row remains, `owner_profile_id` = dangling old id, reference text intact (`HDFC-SECBANK-REF-9911`) | YES: bank reference | FAIL | S2 |
| E7-03 | `source_resources.private_snapshot` (merchant, note, phone digits, bank marker) | row remains in full, `owner_profile_id` dangling | YES: name, phone digits, bank text (real rows also hold transaction facts) | FAIL | S2 |
| E7-04 | `private_cost_facts` (EZ personal cost: share, date, context, expense) | row remains (profile_id dangling) | personal spend facts linkable to the group | FAIL | S2 |
| E7-05 | `members.display_name` self-chosen label "Zed Erasable Person" | retained; co-members see this label, not "Former member" (the fallback applies only when no label is stored) | YES: name as typed | BUG (contradicts the "Former member" intent) | S2 |
| E7-06 | `expense_revisions.title` "Zed dinner at 9500000030" | retained (shared content) | name and phone digits typed into free text | Flag (by design for shared history; state it in the privacy notice) | S3 |
| E7-07 | `operation_receipts`, `context_events`, `profile_events`, `profile_stream_heads`, `revision_approvals`, `revision_members`, `expenses.created_by`, `contexts.created_by`, `settlement_reports.reporter_profile_id`, `expense_revisions.author_profile_id`, `invitations.issuer_profile_id`, `group_links.created_by` | old profile id kept as an opaque uuid (about 45 rows) | id only; no name/phone/bank text for EZ | Flag (pseudonymous but a stable identifier of a deleted person; `profile_events` keeps the full per-person event stream, 10 rows) | S3 |
| E7-08 | `public.notifications` addressed to OTHER users that name EZ (4 rows, e.g. "Zed Erasable Person says they paid you") | retained | YES: name, in others' inboxes | Flag (recipient's own history) | S3 |
| E7-09 | Open phone-bound invitation issued by EZ | stays open and usable: EP claimed it after the erase and was auto-joined (`joined`, no owner approval) into a group whose owner no longer exists | n/a | FAIL | S2 |
| E7-10 | Group link created by EZ | still active (30 day expiry), token still valid | n/a | BUG (issuer-less link) | S3 |
| E7-11 | Unsettled pair balance and pending proposal authored by EZ | balance kept (correct for the counterparty); EV could still approve EZ's pending proposal after the erase (200) | n/a | PASS for the balance; flag the pending proposal | S3 |

E7 answer: `/account/erase` returns 200 but leaves behind, keyed to a now-dangling account id, EZ's
bank/UPI payment references, EZ's per-expense private cost facts, any admitted source snapshots
(merchant, amount, instrument details), and the free-text member label. The erase function only nulls
nullable FK columns that are not named `profile_id`; the `owner_profile_id` / `profile_id` columns of the
three private tables and the actor columns are not touched, and the private tables have no deletion step.

Fix suggestions: (1) add an explicit shared_expenses step to the erase path that deletes rows from
`settlement_private_references`, `private_cost_facts` and `source_resources` (with its reservations and
aliases) for the erased owner, and blanks `members.display_name` on the erased profile's rows so the
"Former member" label applies; (2) revoke every open invitation and group link issued by the profile in
the same transaction; (3) consider nulling or hashing `profile_events.profile_id` after the retention window.

## Re-registration after erasure (same email and phone)

The old auth identity was removed (simulating the lifecycle worker) and a new account was created with
the same email and the same verified phone. The new profile id differs from the old one.

| ID | Check (as the new account) | Result | Verdict | Sev |
|---|---|---|---|---|
| R-01 | Overview / contexts list | empty (`contextCount 0`) | PASS | |
| R-02 | Read old context, members, balances, settlements | `404 context_not_found` | PASS | |
| R-03 | Owner-only invitations list | `403` | PASS | |
| R-04 | `take-over` old context, `leave`, rename the old owner member | `membership_not_authorized` / `context_not_authorized` | PASS | |
| R-05 | Reveal phone on the old invitation | `403` | PASS | |
| R-06 | Accept / claim the old phone-bound invitation issued by the erased account (bound to another number) | `invitation_unavailable` / `invitation_phone_mismatch` | PASS | |
| R-07 | Re-bind old member rows to the new profile | not possible: rows have `profile_id` NULL and no code path matches by phone or email | PASS | |
| R-08 | What remaining members see | the old owner row with its stored label, the counterpart balance of 2000 unchanged, and no new member; the new account appears nowhere | PASS for isolation (see E7-05 for the label) | |
| R-09 (A13) | Open phone-bound invite created for that number by a third party | appears in the NEW holder's inbox; it does not auto-join (state stays `invited` until the holder acts), but the holder can accept it (`joined`) and takes the slot labelled "For old EZ number" with full history access to that group | BUG / risk: a recycled number inherits pending invites; only the 7 day expiry limits it | S2 |

## Number moving between two LIVE accounts

| ID | Check | Result | Verdict | Sev |
|---|---|---|---|---|
| N-01 | Can two live accounts hold the same verified phone in auth? | yes in the local auth DB (setting LB's phone to LA's succeeded) | Flag (local fixture; confirm production auth enforces uniqueness) | S3 |
| N-02 | LA's number moves to LB and LB touches the directory | the directory row for the hash moves to LB and LA's row is deleted (`register_phone` takes the hash); LA re-registers under its new number | PASS (last verified holder wins) | |
| N-03 | Pending invite bound to the number | disappears from LA's inbox (`items: []`), appears in LB's inbox; LA accepting by id gets `invitation_unavailable` | PASS for the old holder losing it; the new holder getting it is the same A13 exposure as R-09 | S2 |
| N-04 | `discoverable` flag | LB's row is created fresh as discoverable; LA's preference does not carry over | PASS | |
| N-05 | Lookup of the moved number by a stranger | resolves to LB's masked name, not LA | PASS | |

Repro sketch (R-09 / N-03): user X invites number N from a group (member.invite, then
`POST /shared-expenses/invitations` with `phoneNumber`); the account that held N is erased or changes
number; whoever next verifies N calls `GET /shared-expenses/invitations/inbox`, sees the invite, then
`POST /shared-expenses/invitations/accept`. Suggested fix: revoke open invitations bound to the old hash
on erase and on number change, or require the inviter to confirm when the holder's directory registration
is newer than the invite.
