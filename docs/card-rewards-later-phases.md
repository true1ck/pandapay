# Card Rewards — Later Phases (2, 3, 4) in brief

**Date:** 2026-11-05 · Read after the [feature spec](card-rewards-intelligence-feature-spec-2026-11-05.md)
and the [Phase 1 plan](card-rewards-phase1-implementation-plan.md). Each phase gets
its own implementation doc when Phase 1 lands. This page keeps the intent,
dependencies and known facts, so nothing is lost in between.

## What Phase 1 hands over

- **Catalogue:**
  - rules v2: merchants, platforms, MCC, rounding, cap kinds, parent caps;
  - structured unlock rules;
  - fixed milestone anchors;
  - per-card `model_status`.
- **Feeds:** v2 feed (`/catalogue?schema=2`) plus the merchant/platform directory.
- **Engines:** both engines on C3 semantics.
- **Server:** records native-unit cap state for multiple caps per transaction.
- **App:** shows cap bars with 80% / 100% alerts.
- **Tests:** about 46 cards Verified against issuer worked examples.

## Facts to remember

- **Banks don't SMS reward points.** 12 months of the owner's real SMS had zero
  bank points messages. Confirmation must come from statements, screenshots or
  manual entry.
- The app parses the catalogue all-or-nothing (v1). Never add new enum values to
  the v1 feed.
- `user_cards.opened_on` / `anniversary_on` exist, but are rarely filled in.
  Milestone and fee-waiver windows are approximate until they are.
- Statement import already accepts a single `pointsPosted` number
  (`api/src/statement_import.js`).
- The research source is `CardPipeline` (sibling repo, schema v5). It holds
  redemption options, expiry, reversal policy and promotions that Phase 1 stores
  but doesn't use.

## Phase 2 — Ledger and progress ("what have I earned, how close am I")

**Features:** A1, A2, A3, A5, B2, B3, plus the Cards page redesign (feature spec §6–7).

| Work | Notes |
|---|---|
| Points ledger per card (A1/A2) | Estimated points and value on each transaction (already computed by WP8). Per-card totals: this cycle / pending / confirmed / year. `points_ledger` rows written as `earn` (estimated). |
| Statement points reader (A3) | Extend `statement_import` per issuer (top 10 first) to read the points summary (opening, earned, bonus, redeemed, expired, closing) and cashback posted. Reconcile per cycle; show the gap and the likely cause. Repeated gaps flag the card for catalogue review (F0.5). |
| "Snap your rewards page" (A3) | On-device OCR of a bank-app screenshot, reusing card-scan text recognition. The user confirms the number. |
| Card start month (B2) | Optional add-card question; infer from annual-fee SMS/statement when skipped. Fills `opened_on` / `anniversary_on`. |
| Milestone tracker (B2) | Progress, deadline, pace projection, "worth chasing?" after fees. Opt-in nudges. |
| Unlock progress (B3) | From `benefit_unlock_rules`: lounge next quarter, fee waiver, tier, welcome. Progress bars on the card tile. |
| Expiry (A5) | `points_expiry_months` plus a first-earned-first-expiring estimate; alerts at 60/30/7 days. |
| Cards page redesign | Tile: this cycle, top cap, next unlock, warning. Detail tabs: Earn / Progress / Rewards / Benefits. |

**Data to add:** statement points summary fields; screenshot snapshots (on
device); card start month.

**Risk:** statement formats vary by issuer. Build a format registry and record
parse failures (`parser_failures` exists).

## Phase 3 — Which card now (pay-time)

**Features:** C1, C2, C3, C4, plus F0.4, F0.5, F0.7.

| Work | Notes |
|---|---|
| Recommendation v2 (C1) | Merchant from QR/UPI ID, location, search or history via the directory. Channel and platform choices. State: caps, milestone distance, unlock distance, credit-limit use, float days, acceptance. Output: best card + backup, one-line why, ₹, what it uses up. "Pay via X for more" only for Verified rules. |
| Entry points (C2) | Merchant search with recents; quick tiles for top spends; "Ask" box answered only from engine and catalogue facts (minimal context, no raw SMS). |
| Coaching (C3) | After an SMS shows a weaker card was used: quiet digest. A tap sets an override. Respect the notification budget. |
| Monthly plan (C4) | At cycle start, which card for which spend, updated as caps fill. |
| Freshness (F0.4) | Monthly re-check of top cards, quarterly for the rest. Scraper page-change detection. User-facing change notes for cards they own. |
| Corrections (F0.5) | Reconciliation gaps and "report wrong data" go to the admin queue with evidence. |
| Missing cards (F0.7) | slice UPI, Stable Money / Suryoday, OneCard Metal, Scapia Federal — through the review gate. |

**Data to add:** platform/channel at pay time; SMS-side rail and platform
inference (so v2's conservative rules stop under-counting).

## Phase 4 — Value and Pro

**Features:** D1, D2, D3, B4, B5, A4, A6, then C5 and A7.

| Work | Notes |
|---|---|
| Monthly rewards report (D1) | Earned (estimated/confirmed), missed, best/worst card, effective return %, caps hit, milestones moved. Makes the existing `monthly_reports` columns real. |
| Portfolio audit and next card (D2) | 6–12 months of real spend; keep/cancel; new card with net-of-fee gain; disclosed referral links. |
| Renewal advisor (B5) | 30 days before the fee: value vs fee, waiver status, keep/ask/downgrade/close. |
| Balance and value (A4) | ₹ value by the user's preferred redemption style, from `redemption_options`. |
| Benefit usage (B4) | Lounge visits used/left (manual log plus suggested auto-detect from lounge validation charges); movie, golf, fuel waiver used. |
| Cashback matching (A6) | Statement cashback lines matched to cycle estimates. |
| Pro tier | Free vs Pro split and price decided here (feature spec §10). Uses the subscription-credits and referral plumbing. |
| Later | Redemption advisor / travel on points (D3), time-limited offers (C5), merchant loyalty wallet (A7). |

## Order and dependencies

```
Phase 1 (rules) ──► Phase 2 (ledger, progress) ──► Phase 4 (value, Pro)
         └────────► Phase 3 (pay-time) ───────────┘
```

Phase 3 can start in parallel with Phase 2 once Phase 1's v2 feed is live.
Phase 4 needs Phase 2's confirmed numbers to make credible ₹ claims.
