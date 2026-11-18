# Rewards page redesign and filters (Bug 16), 18 Nov 2026

**Status (18 Nov 2026):** built on `dev`, uncommitted, not on a phone yet. Unit and
widget tests pass; rendered in a test harness only. See section 5.

Route: `/insights/rewards` (Insights → Rewards). Before this change it was
`GroupedInsightScreen` with three old screens as tabs: This month
(`MonthlySavingsScreen`), Missed (`MissedOpportunitiesScreen`), By card
(`PortfolioAuditScreen`).

## 1. Product review: what was wrong

| # | Problem | Why it matters |
|---|---|---|
| 1 | No filters. "This month" was fixed to the current month, Missed to the last 90 days (card chips only), By card to all time. | "What did I earn in October?" or "what did my HDFC card earn on dining?" had no answer. |
| 2 | Each tab had its own period and its own data source (server monthly report, a 90-day snapshot, lifetime points × point value). | The three tabs never agreed with each other, or with the Insights hub donut for the same period. |
| 3 | The big number was "Panda saved me" (earned minus a best-single-card estimate). Plain "rewards earned" sat in a donut centre further down. | The first question ("how much did my cards earn?") was the hardest to read. |
| 4 | No list of the spends behind the number, and nothing about spends that earned nothing or have no reward yet. | People could not check the figure, and unpriced spends (card not in wallet, not worked out yet) were invisible. |
| 5 | Noise: an invite-a-friend prompt, a streak tile, "Total spend" that includes UPI and cash next to card rewards. | Not reward information; the spend total made the rate impossible to read. |
| 6 | By card made one network request per card for the card's entire history only to print a count. | Slow and costly; the count was all-time while the rest of the page was not. |

## 2. What the page answers now

One scope for the whole page, five questions, each answered once:

1. How much did my cards earn? (Summary hero)
2. Where did it come from? (Summary breakdown by card or category; tapping a row narrows the page to it)
3. Which spends earned what, and which earned nothing? (Transactions)
4. What did I leave on the table? (Missed)
5. Is each card worth keeping? (Cards: period figures plus the annual-fee check)

### Filters (apply to every tab, every number)

- **Date range**: the same sheet Spending uses (This month, Last month, Last 3
  months, This quarter, Year to date, Last 12 months, custom From/To). Default
  This month. The Insights hub passes its own period when it opens the page,
  so the hub's donut and this page show the same figure.
- **Cards**: any number of wallet cards (default all).
- **Categories**: any number of categories present in the range (default all).
- Active filters show as removable chips under the bar; Reset clears them.
- The sheet shows a live "N card spends · ≈ ₹X earned" before applying.

Filters live for the visit (not saved), like Spending's.

### Tabs

**Summary**
- Hero (shareable image): period, "Rewards earned ≈ ₹X", "on ₹Y paid by card ·
  Z% back · N spends". With two or more cards, one more line: "≈ ₹A more than
  using only your best single card" (both sides at base rate, so it is a like
  for like comparison). Share icon in the hero corner.
- One note when some spends are not counted: "N spends have no reward yet"
  (not worked out yet / card not in your wallet). Tap opens Transactions on
  "Not counted".
- Missed line when there is a missed value: "≈ ₹M more was possible on K
  spends", tap opens Missed.
- Breakdown panel: By card / By category toggle, donut and rows; a row tap
  applies that card or category as the filter.
- Month by month bars when the range covers two or more months.

**Transactions**: status chips with counts (All, Earned, No reward, Not
counted), sort (Newest, Highest reward, Largest amount), rows with merchant,
date, card, category, amount and the reward line the transaction screen uses.
Tap opens the transaction.

**Missed**: the spends where another wallet card would have earned more,
inside the filters. Total for the scope at the top. Needs two or more cards.

**Cards**: one panel per wallet card in scope, sorted by earned: earned, card
spend, rate and spend count for the range; annual fee against rewards since
the card was added (break-even). Cards with no spend in the range are listed
last as "No spends in this range". No extra network request per card.

### Removed on purpose

- Invite-a-friend prompt (it lives on the You tab), streak tile.
- The second, all-of-spending total.
- The 90-day fixed window and the Missed tab's own card chips (the page filter
  replaces both).

### Not in this change (ideas, not promised)

- "vs previous period" delta. A month in progress compared with a full month is
  misleading; doing it right needs month-to-date against the same days last
  month. The month-by-month bars cover trends for now.
- Points balance and expiry (already on the card screen and Points expiry).

## 3. Data rules (one place: `rewards_report.dart`)

- **In scope**: active spend rows, amount above zero, paid by credit card
  (`instrument == creditCard`), inside the date range, matching the card and
  category filters. Debit, UPI, wallet and cash never earn a card reward in the
  app, so they are not in any figure here.
- **Counted reward**: the same rule as the activity row chip
  (`countedRewardValue`): a wallet card, not a gift card / reward points / EMI /
  pay-later payment, a priced figure. The Insights overview uses the same rule
  now, so the hub donut and this page agree.
- **Status** of each row: Earned (counted reward above zero), No reward (priced
  at zero, or a payment method that earns nothing), Not counted (card not in
  the wallet, or not worked out yet).
- **Missed** and **best single card**: `compareToOwnedCards` /
  `baseRateValueFor`, base rate only, need two or more wallet cards, marked as
  estimates.
- **Card fee check**: unchanged maths (`totalPointsEarned × pointValueInr`
  against the annual fee or the user's override).

## 4. Engineering

- `features/insights/rewards/`: `rewards_filter.dart` (filter model, range
  maths, provider), `rewards_report.dart` (pure, no Flutter), `rewards_screen.dart`
  (scaffold, filter bar, tabs), `rewards_tabs.dart`, `rewards_filter_sheet.dart`.
- Loading and filtering are split: the range is loaded once (same source as the
  Insights overview: the SMS v2 ledger read model when reporting is on, else
  `loadTransactionsWithOfflineCache`); card/category changes only re-run the
  pure report, never a fetch.
- Cost: one pass over the range's card spends, plus `compareToOwnedCards` per
  spend when there are two or more cards (O(spends × cards)). Picking a card's
  rule built a key per catalogue rule on every call (about 245 ms per pass for
  3,000 spends × 6 cards); the new `BaseRateTable` (domain) picks it once per
  card and category: 15 ms warm for the same load in the test VM, identical
  figures (parity test). The Insights overview uses the same table now.
- `SpendPeriodSelector` gains an optional note for the date sheet so it can be
  reused here without Spending's "grouped by month" line.
- Routes: `/insights/rewards?tab=summary|transactions|missed|cards` plus
  `period=week|month|quarter|year` or `from`/`to`. The old standalone routes
  (savings report, portfolio audit, missed opportunities) redirect into the
  matching tab; Home's rewards figure opens this page.

## 5. What was built (18 Nov)

| Area | Files |
|---|---|
| Domain | `historical_comparison.dart`: `baseRatePerRupee`, `BaseRateTable`, optional `rates:` on `compareToOwnedCards` (same results, parity tests) |
| Shared rules | `app/lib/data/reward_counting.dart`: `isCardRewardSpend`, `countedRewardValue`, `lifetimeRewardValue`; used by the activity chip, the transaction reward line, the Insights overview and the card screen's points tile |
| Page | `app/lib/features/insights/rewards/` (filter, report, providers, screen, tabs, filter sheet) |
| Wiring | router (new page, old savings/portfolio/missed routes redirect to the matching tab), Insights hub passes its period, Home's rewards figure opens the page, `SpendPeriodSelector` gained `key`, `filterCount`, `rangeNote` |
| Removed | `monthly_savings_screen.dart`, `portfolio_audit_screen.dart`, `missed_opportunities_screen.dart` and their two tests |
| Tests | `test/features/insights/rewards/` (24), domain parity (2), `grouped_insight_screen_test.dart` rewritten for Payments/Limits |

Decisions made while building:

- The Insights hub's earned total now uses the counted rule, so a gift-card,
  reward-points, EMI or pay-later spend no longer adds to it (Activity already
  showed no reward for those). Its missed total counts credit-card purchases only.
- Cards tab: "Rewards to date" is the card screen's figure (a cashback card is
  ₹1 per unit; the old audit multiplied it by the point value), floored at what
  the card earned in the selected range, because a running total that lags the
  per-spend figures would otherwise read as less than one month.
- Status chips with no spends are hidden (except the one selected).

Not verified: on a phone, `scripts/perf_smoke_android.sh`, dark mode (the app
draws Insights in light), large text.

