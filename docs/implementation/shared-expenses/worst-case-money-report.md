# Worst-case money-correctness report (split / shared expenses)

Branch `split-labels`. Everything below was executed against a real throwaway
PostgreSQL 16 with all `shared_expense*` migrations applied (foundation through
join-identity), calling the real SECURITY DEFINER functions as `app_user` under
RLS, one transaction per request. No product code was modified.

Run it:

```
docker run -d --name pp-worst-money-pg -e POSTGRES_PASSWORD=wm -p 127.0.0.1:55460:5432 postgres:16
PANDAPAY_WORST_MONEY_PG_URL=postgres://postgres:wm@127.0.0.1:55460/postgres \
  node --test db/tests/shared_expenses_worst_money_*.test.js
# extra random seeds: PANDAPAY_WORST_MONEY_EXTRA_SEEDS=11,12,13
```

Without the env var every suite is skipped. Each suite creates and drops its own
`wm_*` database.

## Verdict

* **The ledger arithmetic is sound.** In 1,000+ randomized mixed operations
  (propose, approve, reject, edit, void, settlement report/confirm/reject,
  join, name-only invite, late bind, rename, owner transfer, leave, remove) over
  contexts of 2, 4, 12 and 60 people, with 1..8 payers and 1..50 sharers, after
  EVERY step: member balances sum to 0, balances equal a from-scratch
  recomputation from the journal, pair balances equal the journal per pair,
  per-expense journal net equals (paid - share) of the accepted revision, no
  journal line exists for a revision lacking an approve from every required
  reviewer, and an independent in-JS model (applied only when the API says
  "accepted"/"confirmed") equals `member_balances`. Zero violations. Seven
  further ad-hoc seeds (11..17, 250 operations each, 3..16 people) also passed;
  seed 18 was cut off by the suite timeout (not a failure) so it is unverified.
* **No path was found that posts money without consent, double-posts, or
  rounds a paisa away.** Races (two confirms, confirm vs reject, three
  simultaneous last approvals, two competing edits) serialize correctly.
* **The weaknesses are "stuck money" / lifecycle gaps, not wrong arithmetic**:
  once a debt exists there are several ways it can become permanently
  unsettleable or an exit can strand it (B2-B6, B10). One S1/S2 class (B4) lets
  a person leave while pair debts still point at them.

## Scenario table

Legend: PASS = executed assertion holds and is now a regression test.
BUG = real defect; its test states the desired behaviour and is `{ todo }`
(shows as `# TODO` and fails today; flips to a normal pass when fixed).
Severity: S1 wrong or stuck money with no workaround, S2 stuck/blocked with
partial workaround, S3 hygiene / UX.

| ID | What was run | Result | Sev |
| --- | --- | --- | --- |
| M01 | 1, 100, 101, 9999 paise among 3/7/33/50 people, each of equal / shares (weights) / percentage / exact via the real `allocateExpense`, then posted and approved by all; per-member delta == paid-share, sum 0, equal-split spread <= 1 paisa | PASS (16 cases x 4 kinds) | - |
| M02 | payer not a participant; payer is sole participant (no edges); everyone pays exactly own share; 8 payers + 8 other sharers uneven | PASS | - |
| M03 | 50 sharers + 8 non-sharing payers (58 distinct, 57 edges) accepted; 51st sharer and 9th payer rejected | PASS | - |
| M03b | edit a 58-person expense into a disjoint 58-person expense (116 reviewers, 114 journal lines, line_no < 400, ordinal < 200) | PASS | - |
| M04 | zero, negative, fractional, `1e3`, unicode digits, leading zero/plus/space, 1e9+1, 2^63, 23-digit, hex, numeric-JSON instead of string, mismatched sums, duplicate member, unknown member, `-0` | PASS (all rejected, no row written) | - |
| M05 | exactly 1,000,000,000 paise posts exactly; `USD`/`inr`/`INR `/``/`EUR`, extra snapshot key, non-INR settlement all rejected | PASS | - |
| M05b/c | `"currency": null` in a snapshot or in a settlement report | BUG B8 (todo) | S3 |
| M06 | dates 0001-01-01 .. 9999-12-31 accepted; 2026-02-31, month 13, `26-11-05`, 5-digit year rejected | PASS (note: 9999-12-31 and 0001 are accepted; impossible dates surface as a raw `22008` error, see B9) | S3 |
| M07 | settlement amounts 0, -1, 1.5, > 1e9, `007`, numeric JSON; bad method/date/reference; payer == receiver | PASS (all rejected) | - |
| M08 | aggregate exposure: seeded pair at 2^53-1-5e8; +5e8 reaches exactly 2^53-1 and is allowed; +1 paisa raises `aggregate_limit_exceeded` and leaves state untouched | PASS | - |
| M09 | 2000 expenses in one context with an edit every 11th and a void every 97th, invariants every 250 steps and at end; `context_totals` count > 1800 | PASS | - |
| M10 | settlement partial / exact / overpay: report alone moves nothing; zero pair row deleted; overpay flips direction and is recorded as `pair_credit` | PASS | - |
| M11 | reject keeps balances; reject then confirm refused; payer cannot confirm own report; pending report never expires and never moves money | PASS (no expiry/cancel exists, see B9) | S3 |
| M12 | confirm the same settlement twice with different operation ids | PASS (1 journal line) | - |
| M13 | two sessions confirm the same settlement concurrently; confirm vs reject concurrently | PASS (exactly one terminal event) | - |
| M14 | two reports for the same debt both confirmed | PASS (debt flips to credit, no paisa lost) | - |
| M15 | settle in full, then void the expense | PASS (reverses into a 1000 credit, zero-sum) | - |
| M16 | third party (neither payer nor receiver) files "X paid Y" | BUG B7 (todo) | S3 |
| M16b | that third-party report cannot be confirmed by the reporter or the payer; only the named receiver; no money moves | PASS | - |
| M17 | receiver files and confirms "payer paid me" alone | PASS (can only move money in the payer's favour, i.e. only against the confirmer) | - |
| M20 | `a` owes `c` 100, `b` owes `a` 100: `a` nets to 0, leaves; pair debts now point at a departed person | BUG B4 (todo) | S1/S2 |
| M21 | member rejects a proposal, then tries to leave | BUG B2 (todo) | S2 |
| M21b | pending proposal blocks leaving; author re-proposing same expense without them unblocks | PASS (characterises the workaround) | - |
| M22 | void or edit an expense after one of its participants left | BUG B3 (todo) | S2 |
| M23 | payer leaves with a pending settlement report; receiver confirms later | BUG B5 (todo) | S2 |
| M24 | participant deletes their account (`profile_id` NULL) | PASS for integrity (history, balances intact, pending items post nothing, no settlement with them); see B6 for the consequence | - |
| M25 | debtor of a deleted account tries to leave | BUG B6 (todo) | S2 |
| M26 | owner transfer with balances outstanding | PASS (no money touched; old owner still bound by `settle_first`) | - |
| M27 | take-over after owner account deleted, including by a debtor | PASS (becomes owner, no power over balances; second take-over refused `owner_still_present`) | - |
| M28 | remove unjoined member with an expense; remove a joined member | PASS (refused `member_has_expenses` / `membership_conflict`); expense-free unjoined removal works | - |
| M29 | name-only person who never joins is on a proposal | BUG B10 (todo) | S2 |
| M30 | name-only participant: nothing posts before join; joining is not approval; old pending proposal becomes reviewable by the joiner; after their approval balances are exact | PASS | - |
| M31 | unjoined payer | PASS (nothing posts) | - |
| M32 | invited friend declines after being named | PASS (proposal pending forever, nothing posts) | - |
| M33 | direct split: friend leaves, owner tries to re-add | BUG B11 (todo) | S3 |
| M34 | group limit 200 counts left members | PASS (characterisation) | S3 |
| M40 | direct + group with the same two people: separate pair rows; `readOverview` owed/owing/net and `listContexts` per-context figures equal SQL; overview net == sum of member balances | PASS | - |
| M50 | replay same operation id (propose and respond), changed body with same id | PASS (stored result returned, `operation_conflict`, 1 journal line) | - |
| M51 | three last approvers approve simultaneously | PASS (posted once, 3 lines) | - |
| M52 | two competing edits of one head | PASS (loser fails `revision_head_conflict`, balances unchanged) | - |
| M53 | edit rejected / unanswered | PASS (old balances stand) | - |
| M60 | seeded random model check, 2 / 4 / 12 / 60 people, 1,060 operations, invariants + JS model after every step | PASS | - |
| M61 | mutation check: corrupt a member balance, a pair balance, delete approvals, tamper a journal line, drift a total; the invariant set flags each | PASS (proves M60 is not vacuous) | - |

## Bugs (minimal repros)

All repros use the harness helpers; the corresponding `todo` test in
`db/tests/shared_expenses_worst_money_flows.test.js` (or `_amounts`) is the
executable form.

* **B4 (S1/S2) leave with net zero but pair debts.** Group `{o,x,y}`. `x` pays 100 for
  `y` (y owes x) and `o` pays 100 for `x` (x owes o), so
  `member_balances[x]=0` while `pair(x,y)=100` and `pair(x,o)=-100`.
  `leave_context(x)` succeeds (it checks only `member_balances.balance_minor<>0`).
  Afterwards `y` and `o` carry a pair debt to/from a departed member; `report_settlement`
  requires both parties `active`, so it can never be settled or netted.
  Fix idea: refuse leave while ANY `pair_balances` row names the member.
* **B2 (S2) rejected proposal blocks leaving.** `a` proposes an expense naming
  `b`; `b` rejects; `leave_context(b)` -> `settle_first` forever (the expense has
  no accepted revision; a void needs an accepted head, so nobody can withdraw
  it). Only the author re-proposing the same `expenseId` without `b` frees `b`.
  Fix idea: count only revisions still awaiting that member; ignore rejected.
* **B3 (S2) void/edit after a participant left.** Expense with `a,b,c`; `b`
  settles and leaves; `a` proposes a void: `c` approves, status stays
  `awaiting_approval` because `b` is a required reviewer who can no longer call
  `respond_expense` (`_can_read_context` needs `active`). The wrong expense can
  never be voided. Fix idea: drop `left` members from `approval_required`
  for edits/voids, or let the owner stand in.
* **B5 (S2) pending settlement + leave.** `b` overpays (report 50 when net zero),
  leaves while the report is pending; `a` confirms later: the journal posts +50
  to the departed `b` and -50 to `a`, a balance with a member who cannot
  settle. Fix idea: block leave while an unresolved report names the member, or
  refuse confirm when either party is not `active`.
* **B6 (S2) debt to a deleted account.** `c` deletes the account
  (`members.profile_id` -> NULL). Debtor `b`: `report_settlement` ->
  `settlement_member_not_authorized`; `leave_context` -> `settle_first`; the
  debt row has no forgiveness / write-off path. Also any void/edit involving `c`
  waits forever (their approval can never arrive).
* **B10 (S2) unjoined person wedges a split.** Owner adds name-only "Ghost",
  `a` proposes an expense with Ghost; Ghost never joins. The proposal stays
  `awaiting_approval`; `remove_member(Ghost)` -> `member_has_expenses` (counts
  pending revisions); the author cannot void it (needs an accepted head); every
  other participant is blocked from leaving (`settle_first`).
* **B7 (S3) third-party settlement report.** `report_settlement` requires only
  that the caller is an active member and both named parties are active. Any
  member can file "X paid Y"; Y gets a confirm prompt. No money moves without
  Y; only noise / social-engineering.
* **B8 (S3) `"currency": null`.** `p_snapshot->>'currency'<>'INR'` and the
  settlement equivalent are NULL for a JSON null, so the guard never fires; the
  row is stored with the constant `INR`. Harmless today (everything is stored as
  INR) but a validation hole; coalesce or use `IS DISTINCT FROM`.
* **B9 (S3) no expiry / cancel for pending settlement reports; raw PG errors for
  impossible dates.** A report waits forever and the reporter cannot withdraw
  it. `occurredOn: "2026-02-31"` surfaces a raw `22008` instead of a domain
  error (the API layer should validate); years 0001 and 9999 are accepted.
* **B11 (S3) direct split slot.** The direct-limit (2) counts `left` members and
  a left person can never be re-invited (`UNIQUE(context_id, profile_id)`), so
  that direct split is dead; the workaround is a brand-new direct split with the
  same friend (which then makes two direct contexts for one pair).

## New regression tests committed

* `db/tests/shared_expenses_worst_money_common.test.js` (harness + invariants,
  no tests of its own)
* `db/tests/shared_expenses_worst_money_amounts.test.js` (M01-M09, M05b/c todo)
* `db/tests/shared_expenses_worst_money_flows.test.js` (M10-M53, todos for
  B2, B3, B4, B5, B6, B7, B10, B11)
* `db/tests/shared_expenses_worst_money_random.test.js` (M60, M61)
