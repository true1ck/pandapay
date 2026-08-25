# Implementation status — spend tracking, cap correctness, Insights

Companion to [`spend-tracking-and-caps-plan.md`](spend-tracking-and-caps-plan.md),
which holds the original audit and the reasoning. This file is the map from
each planned item to what actually landed.

Everything in the plan is implemented. Nothing was silently descoped; the
two places where a deliberate judgement call was made are called out under
**Decisions taken** at the bottom.

## Verification

| Suite | Result |
|---|---|
| `packages/pandapay_domain` — `dart analyze` + `dart test` | clean, **206 passing** (was 158) |
| `api` — `npm test` (syntax check + node:test) | **174 passing** (was 107) |
| `app` — `flutter analyze` + `flutter test` | clean, **477 passing** (was 441) |

---

## Migrations added

| Migration | What it does |
|---|---|
| `0038_rule_constraints_and_exclusions.sql` | Makes `cap_rules.post_cap_rate` nullable so "unspecified" stops meaning zero; adds `card_products.excluded_categories` and `reward_rules.excluded_categories`; exposes both on the two catalogue export views. |
| `0039_import_card_matching_and_categorization.sql` | `user_cards.last4` (four digits, CHECK-enforced, never the full PAN) + index; `merchant_category_rules` reference table with ~60 seeded Indian merchants; adds `last4` to the sync engine's field allowlist. |
| `0040_budgets_instruments_recurring.sql` | `budgets` + `budget_periods`; `transactions.instrument` / `transactions.entry_kind` with a CHECK tying card-ness to instrument; `recurring_series`; two budget notification categories; RLS on all three new tables. |

## Modules added

**API** — `reward_math.js`, `import_resolvers.js`, `spend_reports.js`,
`recurring.js`, `monthly_report.js`, `csv.js`, `imap_client.js`,
`imap_poller.js`.

**App** — `data/spend_reports_repository.dart`,
`features/insights/spend_trends_screen.dart`,
`features/insights/budgets_screen.dart`,
`features/insights/subscriptions_screen.dart`,
`features/sms_import/sms_background_queue.dart`.

**Shared** — `db/fixtures/reward_parity_scenarios.json`, the cross-language
contract both reward engines are tested against.

---

## Workstream 1 — Capture

| Item | Status | Where |
|---|---|---|
| W1.1 `user_cards.last4` + resolver | Done | `0039`; `api/src/import_resolvers.js` `resolveUserCardForImport`; `userCardId` now optional on `/transactions/from-sms`, `/from-sms/batch`, `/inbound-emails/:id/create-transaction`; Edit Card gained a last-4 field; the SMS backup import pre-selects groups whose digits match a card. |
| W1.2 Email auto-creates a transaction | Done | `POST /inbound-emails/webhook` now runs `importParsedMessage` under `withUserClient(profile_id)` after the SECURITY DEFINER RPC returns the owner. |
| W1.3 Email transaction date | Done | `parseTransactionDate()` in `api/src/sms_parser.js` — day-first, rejects impossible and future dates, returns null rather than falling back to "today". 9 tests. |
| W1.4 IMAP poller | Done | `api/src/imap_client.js` (dependency-free IMAP subset, read-only `EXAMINE`) + `api/src/imap_poller.js` (advisory-locked interval, `last_poll_at` only advances on success). Off unless `IMAP_POLL_INTERVAL_MINUTES` is set. 13 tests. |
| W1.5 Background SMS | Done, dev/staging only | `smsBackgroundHandler` (`@pragma('vm:entry-point')`) queues to disk; `smsBackgroundFlushProvider` uploads on resume. Gated on `!Env.isProd` — prod strips the permission at the manifest level for Play policy. 10 tests. |
| W1.6 Merchant → category | Done | `resolveCategoryForImport` — user's own history, then crowdsourced VPA, then MCC, then the shipped `merchant_category_rules` table. |
| W1.7 Dedupe sharpening | Done | ±₹1 amount tolerance, normalized merchant comparison, and **auto-merge at 0.9** — the later row is reversed and marked `ignored`, recorded as `resolution='merged'`, reversible from Duplicate Review. |

## Workstream 2 — Ranking and reward correctness

| Item | Status | Notes |
|---|---|---|
| W2.1 Post-cap → base rate, not ₹0 | Done | `post_cap_rate` is now nullable; null resolves to the card's own base rate. A capped 10% card reads as the 1% card it is, and **sorts above genuinely worse cards** — it previously sorted below them. |
| W2.2 Server/client cap agreement | Done | `api/src/reward_math.js` mirrors the Dart engine. `category_id IS NULL` is no longer a wildcard, so a rent payment can't consume a grocery cap. Both sides are asserted against `db/fixtures/reward_parity_scenarios.json` — **21 shared scenarios, checked in both languages**. |
| W2.3 Recorded earnings ignore caps | Done | `expected_value_inr` and `expected_points` are now cap-blended, computed from cap state read *before* the insert. Points ledger uses the same figure rather than re-deriving it. |
| W2.4 Rule constraints enforced | Done | `RecommendationEngine.ruleApplies` now checks merchant pattern, rail, min-txn and validity window. `maxTxn` splits the transaction (bonus up to the ceiling, base rate above) rather than voiding the rule. |
| W2.5 Category exclusions | Done | Card-level (earns nothing, returned as an exclusion with a reason) and rule-level (falls through to base rate) are distinct. Card-level exclusions also stop milestone accrual. |
| W2.6 Surfacing it | Done | New `CapStatus` enum on the breakdown — a first-class field, not prose the UI keyword-matches. Home shows the rate the card **actually pays** and a "Cap spent — earning base rate" badge. |

## Workstream 3 — Insights

| Item | Status | Notes |
|---|---|---|
| W3.1 Spend Trends | Done | `GET /spend-report` in one round trip; week/month/quarter/year, previous-period comparison, 12-bucket chart, category/merchant/card breakdowns, pace projection. |
| W3.2 Per-card spend | Done | New **Spend** tab on Card Detail (second, right after Rewards) showing the card's *effective* rate and whether it beats its annual fee. Also the "Which card" section on Trends. |
| W3.3 Budgets | Done | Overall / per-category / per-card, weekly→yearly, anchored on the budget's own start day. Pace-aware: "ahead of pace" is a distinct state from "over", with a 5% margin so ordinary purchases don't trip it. Two notification categories. |
| W3.4 Cash, income, investments | Done | `instrument` + `entry_kind`; QuickAdd gained both selectors; non-card entries count toward spend and budgets but move **no** card state. Income/investment are reported on their own lines and never summed into spend. |
| W3.5 Subscriptions | Done | `api/src/recurring.js` — same merchant, ±10% amount, consistent cadence, ≥3 occurrences. 13 tests, most of them about what it must *not* claim. |
| W3.6 Real monthly report | Done | `api/src/monthly_report.js` replaces the stub note. Baseline, extra-earned, missed and top-5 misses, **with each hypothetical card's cap consumption simulated across the month** — without that, every alternative card looks freshly-uncapped and missed value is wildly overstated. |
| W3.7 Export | Done | `GET /export/transactions.csv`, shared from Trends via the platform share sheet. CSV escaping is its own tested module, including the spreadsheet formula-injection guard. |

---

## Decisions taken

The plan ended with four open questions. Three were implemented as
recommended; all four are recorded here because each is a judgement call
someone may want to revisit.

1. **IMAP: built, not removed.** Storing a decryptable app password for a
   feature that did nothing was the worst available state. The poller is
   read-only (`EXAMINE`, never `SELECT`), applies the sender filter
   server-side so only bank mail crosses the wire, and is **off by default**
   — a deployment must set `IMAP_POLL_INTERVAL_MINUTES` to enable it.

2. **Background SMS: dev/staging only.** Enabled via
   `onBackgroundMessage` when `!Env.isProd`. The prod flavor still strips
   `READ_SMS`/`RECEIVE_SMS` at the manifest level, so the Play Store
   position is unchanged.

3. **Duplicate auto-merge at 0.9: enabled.** Flagging alone left both copies
   `active` — and active means counted — so the exact double-count the queue
   exists to prevent happened anyway for as long as the queue went unread.
   0.6 matches still go to the queue.

4. **PandaPay does become a general spend tracker.** Cash, income and
   investments are recordable. The boundary held throughout: non-card
   entries never touch cap, milestone, points or fee-waiver state, and
   income and investments are never added into a spend total. This is a real
   widening of positioning and is worth a deliberate look before the store
   listing is written.

## Known limitations, stated plainly

- **Client-side triggers.** Budget and cap notifications fire on app
  resume and after a transaction sync, not via push. Same honest posture as
  the existing geofencing note — there is no push/cron backend and none was
  invented for this.
- **IMAP MIME handling is shallow.** Headers and a text body; no nested
  multipart, base64/quoted-printable decoding, or HTML-to-text. An
  unparseable message is treated as a normal miss, the same way the SMS
  path treats an unmatched template.
- **Reversal against a moved rule.** Reversing a transaction after the
  catalogue's rules changed mid-cycle may not cancel its original apply
  exactly. Pre-existing and previously documented; the cap-blending work
  narrows it but does not remove it.
- **Monthly "optimal" is greedy per transaction.** A true optimum would
  consider not using the best card early so its cap survives for a larger
  purchase later. Greedy is the figure the recommender would actually have
  produced in the moment, so it is the honest measure of following the app.
