# Rewards "Missed" was always empty: cause and fix, 19 Nov 2026

**Status:** built on `dev`, uncommitted, not on a phone. Domain suite (2,692), the
rewards, hub and split-planner app tests pass; full app suite: see the end.

## 1. What the owner saw

Insights → Rewards → Missed said "No missed rewards: every spend went on your best
card for its category", for one month and for two years, with ten cards in the wallet.
It was not true. The tab could not have shown anything.

## 2. Root cause

`baseRatePerRupee` (domain `historical_comparison.dart`) picked each card's "base rate"
as the lowest-priority-number rule among all rules with **no category**. On the live v2
catalogue every card starts with priority-0 *exclusion* rows that have no category
("no rewards under ₹100", "no rewards on EMI"), at rate 0. So every wallet card
priced at **0.00% in every category**, `compareToOwnedCards` never found a better card,
and the page printed its reassurance.

Evidence: the app's own parser on the live `GET /catalogue?schema=2` (444 cards) gave 0.00%
for all seven wallet products in all 15 categories. The unit tests passed because they used
hand-built v1-shaped cards (one category rule plus one base rule), never the v2 shape.

Same bug, other places:

| Where | Effect |
|---|---|
| Rewards page: Missed tab, Summary "Missed" tile, Cards "Missed on this card" | always empty |
| Insights hub: "Left on the table" tile and the top-3 preview | always "No missed rewards" |
| Split planner (`baseRateValueFor`) | "best single card" baseline was ₹0, so the benefit of splitting was overstated |
| Rewards hero "More than only <card>" | never appeared (needs a non-zero base) |

## 3. The fix

**Domain** (`packages/pandapay_domain`)

- `baseRatePerRupee` now reads only general earning rules (role earn/base, no merchant,
  platform, MCC-list or rail condition), then the card's stated base rate; a category the card
  excludes pays 0. Used by the split planner.
- New `SpendComparer` (`spend_comparison.dart`) prices each spend on the other wallet
  cards with the **reward engine itself** (`RecommendationEngine.evaluateRewardV2`): merchant
  rows ("10% on Swiggy"), minimum spends, exclusions and rounding all apply. On the owner's
  1,173 spends the engine reproduced the server's stored reward for the card used on 1,160
  (99%); the other 13 are higher by a cap the server applied.
- Removed `compareToOwnedCards` and `BaseRateTable` (replaced).

**Rules that decide whether a card counts as "the better choice"**

| Rule | Why |
|---|---|
| Card must have been in hand: issue date if entered, else its first recorded use | Scapia's first spend is 15 Jan 2026; without this it was recommended for 2025 spends and made up 86% of the "gap" |
| Not the same product as the card used; held-twice products are one choice | |
| Credit cards only | |
| A spend known to be UPI only moves to UPI-linkable cards | |
| EMI, gift-card, reward-points, pay-later payments are skipped | they earn nothing on any card |
| In rent, wallet, fuel, insurance, government, education, EMI, bills the paying rule must name the category | catalogue entries are silent or MCC-only there (Kiwi's rent exclusion is an MCC list; a past spend has no MCC) |
| Gap of at least ₹5 | 580 rows at ₹1 are points rounding; ₹5 keeps 96% of the total in 147 rows |
| Rail "online" inferred only from gateway text in the merchant (`PYU*`, Razorpay…) | same rule as the server, so a spend is priced as it was when its reward was stored |

**App**

- `rewards_comparison.dart`: builds the request, runs `SpendComparer` (in an isolate above
  800 spends x cards, per the performance rulebook R1). `rewardsChecksProvider` computes it
  once per date range; card and category filters only re-slice the answers.
- The report takes the checks; "best single card" removed.
- **Missed tab:** each card's rate for the spend ("1% back → 10% back"), the catalogue's own
  line for the rule, a "card payment only, not UPI" note when the better card cannot take UPI,
  and a "Where it adds up" block (top card-to-card habits). Empty states no longer reassure
  unless spends were checked: "No clear misses" says how many were checked;
  "Nothing to compare yet" when no other card was in hand; "Could not check your cards" with
  Try again when the comparison failed.
- **Insights hub:** missed moved out of `insightsOverviewProvider` into `insightsMissedProvider`,
  which reads the Rewards report for the same dates (so hub and page cannot disagree). While it
  runs the tile shows a dash and "Checking your cards", never "No missed rewards".
  (A first attempt awaited the comparison inside the overview provider; the offline loader
  invalidates its owner when the store changes, which hung one-shot reads.)

## 4. The owner's real numbers (prod rows to 17 Nov 2026; upper estimates)

Replayed through the app's own report builder (`test/tool/rewards_private_replay_test.dart`):

| Period | Spends | Earned | Missed | On spends |
|---|---|---|---|---|
| Last 30 days | 21 | ₹93 | ₹309 | 4 |
| Last 3 months | 145 | ₹2,536 | ₹889 | 23 |
| Last 12 months | 614 | ₹10,196 | ₹5,065 | 92 |
| Two years | 1,172 | ₹16,396 | ₹6,911 | 145 |

Biggest: Kiwi spends that Scapia or Tata Neu would have paid more on (about ₹1,800 over two
years), Swiggy orders paid on Tata Neu / PhonePe SBI when the Swiggy HDFC card pays 10%
(₹277 and ₹221 in the last 90 days), Amazon spends on Sapphiro (₹828).

The server stores `recommended_card_id` / `followed_recommendation` per row but **none of the
1,173 rows has them set**, so "did I follow the app's suggestion" cannot be answered from data;
Missed answers the equivalent question against the best card in the wallet.

## 5. Limits (stated on the page)

- Caps and milestones as they stood on the day are not kept, so a card with a monthly cap can
  be over-credited. Of the cards that came out on top, Scapia and Amazon Pay ICICI have no caps
  in the catalogue; Swiggy HDFC and Tata Neu do.
- UPI-only shops and payments to people cannot move to every card; the rail is unknown for 99%
  of rows, so only spends known to be UPI are gated and the better card's "card only" note
  carries the rest.
- Catalogue quality: Scapia, Amazon Pay ICICI, Swiggy HDFC, Tata Neu and Sapphiro are `partial`
  models. Amazon Pay's Prime 5% is an info row, so 3% is used.
- Points are valued at the catalogue's ₹ per point.

## 6. Replaying real data

Public: `GET https://api.pandapath.live/catalogue?schema=2`, `GET .../categories`.
Owner files (read-only SQL via the backup container, see `prod-server-access` notes):
`owner_wallet.json` from `user_cards`; `owner_txn.json` from `transactions` joined to
`spend_categories` for active credit-card spends (`instrument='credit_card'`,
`entry_kind='spend'`, `amount_inr>0`) with `id, amount_inr, occurred_at, merchant_name,
merchant_vpa, category_id, category_name, category_slug, user_card_id, rail, payment_method,
expected_value_inr`.

```
REWARDS_REPLAY_DIR=/path/to/dir flutter test test/tool/rewards_private_replay_test.dart
```

## 7. Tests

Domain: `historical_comparison_test.dart` (v2 shape regression: confirmed it returns 0% under the
old code), `spend_comparison_test.dart` (each rule above). App: `rewards_report_test.dart`,
`rewards_screen_test.dart` (states and rows), `insights_dummy_data_test.dart` (hub = page).
A 3,000 spend x 6 card comparison takes about 0.5 s in the test VM, hence the isolate.

Not verified: on a phone, `scripts/perf_smoke_android.sh`, dark mode, large text.
