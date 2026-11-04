# Card Rewards Intelligence — Feature Spec

**Date:** 2026-11-05
**Status:** Approved 2026-11-05, with one change: every fix is **card-wide**.
Named cards (Swiggy HDFC, PhonePe SBI, Amex Platinum Travel, Kiwi) are only
illustrations of patterns that repeat across the catalogue. Phase 1 fixes the
pattern for every card, never one card at a time.
**Next docs:** [Phase 1 implementation plan](card-rewards-phase1-implementation-plan.md) ·
[Multi-agent plan](card-rewards-phase1-agent-plan.md) ·
[Later phases](card-rewards-later-phases.md) · [Status tracker](card-rewards-status.md)
**Scope:** reward estimation, points tracking and bank confirmation, caps,
milestones, benefit unlocks (lounge etc.), the Cards page, and "which card do I
pay with right now".

---

## 0. Summary

**Goal.** For every card a user holds, PandaPay should know — automatically and
correctly — what they have earned, what they are about to earn, what limit or
milestone they are close to, and which card to use for the next payment. Then it
should prove it against the bank's own numbers.

**What we found.** The screens and the ranking engine mostly exist. What makes
the app feel "not smart" is that **the card rules the engine runs on are wrong
for a large share of cards**, and **we have no way to confirm points** against
the bank. Across all research data, **176 of 500 bonus rules (on 104 cards)**
are dropped because their category can't be mapped. The cards below are
examples of each pattern, not the whole list:

- **66 of 74 co-brand cards** have no merchant rule. Swiggy HDFC only knows its
  1% rate — the 10% Swiggy and 5% online rules were in our research data but were
  dropped when they were loaded into the database. PhonePe SBI SELECT BLACK lost
  its 10x PhonePe rule the same way.
- **98 "select brands only" bonus rates on 74 cards apply to every purchase.**
  Amex Platinum Travel's 6 points/₹100 at Reward Multiplier brands is treated as
  its rate everywhere, so the app thinks it returns about 2.4% on all spends
  instead of about 0.8%.
- **238 of 641 caps (37%) are never enforced** — they aren't linked to any rule.
  Most of the rest switch the card to "earns nothing" after the cap, even where
  only the bonus stops and the base rate continues.
- **All 292 milestones** are tied to the card anniversary, including 46 quarterly
  and 6 monthly ones (a loading bug), and we usually don't know the anniversary.
- **124 lounge benefits on 105 cards unlock only after spending a set amount**,
  but that condition is stored as free text, so we can't show progress.
- **In 12 months of your real SMS (5,238 messages from banks and brands) there
  were no bank reward-point messages.** Banks don't text points. Estimates must
  come from our own maths. Confirmation must come from statements, the bank app,
  or the user.

**What we propose — five parts:**

| Part | One line |
|---|---|
| **0. Card rules you can trust** | Model real card terms (merchants, apps, portals, caps, tiers, rounding), load research data without losing anything, and test the top cards against worked examples. |
| **A. Rewards ledger** | Estimated points on every transaction, a per-card "earned this cycle", and reconciliation against statements. |
| **B. Progress** | Live caps, milestones and benefit unlocks (lounge, fee waiver, tiers) on the Cards page, with alerts. |
| **C. Which card now** | A recommendation that knows caps, milestones, unlocks, apps and portals. It shows a backup card, a one-line reason, and a monthly plan. |
| **D. Value** | A monthly rewards report, a portfolio audit, a next-card suggestion and a redemption advisor. This is the part worth paying for. |

Decisions needed from you are in **§13**.

---

## 1. The problem, in your words

From your brief, a user expects PandaPay to:

1. **Estimate points automatically** from the card spends we already read from
   SMS, per card. This includes cards with odd point units (Amex Membership Rewards,
   Axis EDGE, Kiwis, NeuCoins).
2. **Re-verify with the bank** when points actually post, and show the difference.
3. **Know card-specific perks**: Swiggy HDFC's 10% on Swiggy (including Dineout),
   PhonePe SBI's PhonePe-app bonus, and "only feature" co-brand cards.
4. **Track milestones**: Amex Platinum Travel's ₹1.9L / ₹4L / ₹7L rewards, and
   say how far away each is.
5. **Respect limits**: once PhonePe SBI's or Kiwi's monthly bonus is used up, stop
   recommending that card for that spend.
6. **Show unlocks**: lounge access and other benefits that only unlock after you
   spend a set amount, visible on the Cards page.
7. **Answer "which card?" at the counter** for the maximum reward, quickly.
8. Be **accurate, secure and worth paying for**.

---

## 2. What already exists (we build on this, not around it)

| Area | What's there today | Where |
|---|---|---|
| Card catalogue | 377 published cards. Research comes from the sibling `CardPipeline` project (392 rows, schema v5) and is loaded by `api/scripts/import_card_pipeline.js` with a review/publish gate. | `card_products`, `reward_rules`, `cap_rules`, `milestone_rules`, `fee_waiver_rules`, `card_benefits`, `redemption_options` |
| Ranking engine | Ranks cards per transaction. Handles 3 cap types (spend, reward value, transaction count), falls back to the base rate after a cap, and checks per-transaction min/max, rail (UPI/online/swipe), merchant text, dates, forex markup, fuel waiver and milestone proximity. A JS copy records earnings server-side; shared fixtures keep the two in step. | `packages/pandapay_domain/.../engine.dart`, `api/src/reward_math.js` |
| User state | Points balance (manual), points ledger, cap/milestone/fee-waiver state per period, lounge usage log, estimated vs confirmed points on each transaction. | `0004_user_domain.sql` |
| Screens | Cards, Card detail, Caps, Milestones, Fee waivers, Lounge access (manual log), Points & expiry (manual balance), Missed opportunities, Monthly savings, Portfolio audit, Benefits cheat sheet, Big-purchase calculator, Split planner, Travel mode, EMI advisor. | `app/lib/features/cards`, `.../insights`, `.../tools` |
| Pay-time entry points | UPI QR scan → recommend → hand off to a UPI app; home-screen widget; nearby-merchant alerts; quick add; card overrides ("always use X at Y"). | `features/scan`, `home_widget`, `geofence`, `overrides` |
| Data in | SMS (Android, plus iOS via Shortcuts), email forwarding, statement import (already accepts a `pointsPosted` number), and card discovery from SMS/email (suggests cards; the user confirms). | |

**So this spec is mostly about correctness, automation and presentation, not
new screens.**

---

## 3. Why it feels "not smart": audit findings

The method and raw numbers are in Appendix A. Worked examples showing today's
answer next to the correct one are in Appendix B.

### 3.1 The card rules are wrong for many cards (biggest problem)

| # | Finding | Size | Example | What the user sees |
|---|---|---|---|---|
| R1 | **Co-brand merchant rules missing** | 66 of 74 co-brand cards have no merchant rule | Swiggy HDFC: the 10% Swiggy rule (min ₹249; covers food, Instamart, Genie, Dineout) and the 5% online rule are in our research data, but the loader has no category for `swiggy_app` / `online_shopping`, so it dropped them. Amazon Pay ICICI, Flipkart, IndianOil, IRCTC and IndiGo cards also have no merchant rule. | The app never recommends a co-brand card at its own brand. |
| R2 | **Brand-only bonus applied everywhere** | 98 rules on 74 cards *(upper bound; each needs a look)* | Amex Platinum Travel "6 pts/₹100 at Reward Multiplier brands" has no restriction, so it's used on every spend. Axis ACE shows 4% on every spend (vs 1.5% base); Axis Magnus shows 3.5% (vs 1.2%). | Over-recommends some cards and over-states earnings. |
| R3 | **Caps not enforced** | 238 of 641 caps (37%) linked to nothing | PhonePe SBI SELECT BLACK's monthly PhonePe-bonus cap and overall cap; 6 of Infinia's 10 caps. | Keeps recommending a card whose bonus is already used up. |
| R4 | **"Bonus stops" treated as "everything stops"** | 428 caps have post-cap = 0 | Many are *bonus-point* caps: only the extra points stop and the base 1x continues. | After the cap, the card drops to the bottom instead of to its base rate. |
| R5 | **Wrong cap units / missing values in research** | Spot checks | Swiggy HDFC caps are ₹1,500 / ₹1,500 / ₹500 of **cashback** per cycle, but are stored as **spend** caps, so the card "earns nothing" after ₹500 of spend. PNB Kiwi's monthly cap has no value. | Wrong answers, both too high and too low. |
| R6 | **Milestones on the wrong clock** | All 292 | The loader sets every milestone to "card anniversary" (both branches of its choice return the same value), including quarterly and monthly ones. We rarely know a user's anniversary anyway. | Wrong progress and wrong deadlines. |
| R7 | **Spend-gated benefits are free text** | 124 of 408 lounge benefits, 105 cards | "Lounge visit if you spent ₹X last quarter" is stored under 10+ different key names. Axis Atlas tier lounges show as 6 separate benefits instead of one tiered benefit. | Can't show "₹12,400 more to unlock lounge". |
| R8 | **App / portal / programme conditions ignored** | Not counted | HDFC SmartBuy, Amex Reward Multiplier, "only in the PhonePe app", Swiggy's ₹249 minimum. The engine reads category, merchant text, rail, min/max and dates — never the `conditions` field. | Can't say "pay via SmartBuy for 10x". |
| R9 | **Point rounding not modelled** | All points cards | Most cards give points per ₹100/₹150/₹200 block, rounded down per transaction (₹199 → 1 point). We have block size and rounding in the research data but use a smooth rate. | Estimates run high for small UPI spends — exactly where users spend most often. |
| R10 | **Data is getting stale** | All 377 verified 29–30 Aug 2026 | Banks revise terms often (several cards changed on 1 Jul 2026), and nothing re-checks published cards. | Users catch us being wrong and stop trusting us. |
| R11 | **One ₹ value per point** | All points cards | Amex Platinum Travel redemptions range from ₹0.25 to ₹0.50 per point by channel; redemption options aren't in the app's catalogue feed. | ₹ value of points is a guess. |
| R12 | **Missing cards** | From 2026-10-07 audit | slice UPI, Stable Money (Suryoday) cards, OneCard Metal, Scapia Federal. | "My card isn't here." |

**Root cause:** the research data (CardPipeline v5) is richer than the database
it is loaded into. The loader flattens it, drops what doesn't fit, and sometimes
widens what it can't restrict. **Most fixes are model + loader + review, not
re-research.**

### 3.2 Points: we estimate loosely and confirm nothing

- The points balance is typed in by the user. The ledger table exists, but users
  don't see "this cycle you earned about 1,840 points on this card".
- **Banks don't SMS points.** Your real SMS for the last 12 months: 5,238
  messages from banks and brands, about 1,100 spend/debit alerts, and **zero**
  bank reward-point messages. The ~18 messages mentioning "points" were merchant
  loyalty (Haldiram's, Kushals) and promotions.
- So the only realistic confirmation sources are:
  1. the **monthly statement** (opening, earned, redeemed and closing points;
     cashback posted);
  2. a **screenshot of the bank app's rewards page**;
  3. **manual entry**;
  4. the occasional SMS or email.
  Statement import already takes one `pointsPosted` number. Turning that into a
  per-card reconciliation is the gap.

### 3.3 Pay-time answers lack inputs

- The merchant is often unknown at pay time. A QR code gives a UPI ID; online
  checkout gives nothing.
- Channel and platform aren't asked: in the Swiggy app vs the website,
  SmartBuy vs direct.
- Benefit unlocks (lounge) and the month's plan don't feature in the ranking.
  "Cap used up → switch to X" exists in the plan docs but isn't proactive
  everywhere.

---

## 4. Market check: SaveSage and others

Sources: public listings and the company site, not hands-on testing.

**SaveSage** (India; App Store 4.1 from ~8.8k ratings)
- **Data in:** connects Gmail / Outlook / Yahoo to read **statements**, plus
  manual card entry.
- **Rewards:** points balances across cards and 75+ loyalty programmes, expiry
  alerts, merchant loyalty (Flipkart SuperCoins).
- **Which card:** "Scan & Save" says the best way to pay just before a purchase;
  "Savvy" is an AI chat for card questions.
- **Travel:** "Travel on Points" compares points needed, taxes and value per
  point across programmes; also 1-on-1 expert consultations.
- **Money:** free app with paid tiers (Pro / Elite / Private); prices aren't on
  the official pages. Also loan referrals, gift cards, credit score, and IndiGo
  BluChips on bill payments.
- **Complaints visible in reviews:** generic AI answers, repeated
  "update your details" loops, pressure to connect email, refund disputes.
- **Not visible:** cap tracking, milestone tracking, spend-gated lounge
  tracking, or cap-aware recommendations.

**Others:** CRED (bill payments with rewards), Paisabazaar's reward calculator,
CCReward (checks a merchant's category code before you pay), CardGenius
(comparison and analysis).

**Where we win:** we are the only app that knows **where you stand on every cap,
milestone and unlock**, and **changes its answer the moment that changes**. We do
it **automatically from SMS**, **privately on the phone**, with **bank-confirmed
numbers**. SaveSage is strong on balances and travel redemption. We should match
that (A4, D3) but lead with live, correct pay-time decisions and progress.

---

## 5. Product principles

1. **Correct before clever.** Every number traces back to a rule with a source
   and a date. If we can't model a rule, we say "estimated" or stay quiet; we
   never widen it.
2. **Estimated vs confirmed, always visible.** Every estimate eventually meets
   the bank's number, and we show the gap.
3. **One-line why.** "10% Swiggy cashback — ₹420 of this cycle's cap left."
4. **Never push extra spending.** Milestone nudges are for spend the user would
   make anyway, and always show value after the annual fee.
5. **Private by default.** SMS, statements and screenshots are processed on the
   phone. We never need the card number, CVV, expiry, bank login or OTP.
6. **One answer at the counter.** Best card plus a backup in under a second,
   offline.

---

## 6. Features

Each feature has an ID so you can reply "F0.3 yes, C4 later" and so on.
P0 = must have for this initiative, P1 = next, P2 = later.

### Part 0 — Card rules you can trust (foundation)

**F0.1 Card rules v2 (P0).** Extend what a card rule can say, so real terms fit
without loss:
- **Where it applies:** merchant set with aliases (Swiggy = Swiggy, Instamart,
  Dineout, Genie, and its legal names on SMS such as "Bundl Technologies"); app or
  platform (in the PhonePe app, the Swiggy app); bank portal (SmartBuy, Amex Reward
  Multiplier, iShop); channel (online / in store / UPI QR / tap / EMI); category
  codes (MCC); min/max per transaction.
- **How points accrue:** block size (₹100/150/200), rounding (down per
  transaction), unit (points, miles, cashback, Kiwis, NeuCoins).
- **Caps:** what is capped (bonus points, total points, cashback, spend,
  transaction count); period and reset date; caps inside caps; what happens after
  (base rate / nothing / reduced rate).
- **Spend tiers:** Magnus above ₹1.5L/month; memberships and tiers (Atlas
  Silver/Gold/Platinum, Kiwi Neon, Swiggy One).
- **Dates:** valid from/to, so revisions sit side by side.

**F0.2 Lossless loading and a coverage report (P0).** Load everything CardPipeline
has. Any rule we can't yet express is **flagged, never dropped or widened**.
Each card gets a status:

| Status | Meaning |
|---|---|
| **Verified** | All earning rules, caps and milestones are modelled and pass the worked examples. |
| **Partial** | Base rate is right; some bonuses are shown as info only. |
| **Basic** | Fees and benefits only. |

The app shows Partial/Basic gently ("Some rewards on this card are estimated").

**F0.3 Worked-example tests for top cards (P0).** For about 50 cards (Appendix C),
write 10–20 plain-language checks each, for example: "₹1,000 Swiggy order on
Swiggy HDFC → ₹100 cashback, ₹1,400 of cap left." A card can't be marked Verified
until all its checks pass in both engines (app and server).

**F0.4 Freshness and change alerts (P1).** Re-check the top cards monthly and the
rest quarterly; the existing weekly scraper timer can flag page changes. When a
card a user holds changes, tell them in plain words ("From 1 Dec, HDFC caps
SmartBuy at …") and recompute everything that depends on it.

**F0.5 Corrections loop (P1).** "Report wrong data" already exists. Add an
automatic signal: when a user's statement points differ from our estimate by more
than a threshold for a card, that card goes to the review queue with the evidence.

**F0.6 Merchant directory (P0).** One canonical merchant with all its aliases: SMS
descriptors, UPI IDs, category code, and the co-brand cards that favour it. This
is what turns "BUNDL TECHNOLOGIES" on an SMS into "Swiggy → Swiggy HDFC 10%".

**F0.7 Fill catalogue gaps (P1).** Add slice UPI, the Stable Money / Suryoday
cards, OneCard Metal and Scapia Federal through the normal review gate.

### Part A — Rewards ledger ("what have I earned?")

**A1 Points estimate on every transaction (P0).** Every card spend (SMS, email,
statement or manual) gets estimated points or cashback using F0.1 rules, including
rounding, exclusions and the cap state at that moment. Transaction detail shows
"≈ 20 points (₹8) — 10x PhonePe bills; 260 bonus points left this month".

**A2 Card rewards summary (P0).** Per card: estimated this cycle, waiting to post,
confirmed at the last statement, total this year, and the ₹ value of each.

**A3 Bank confirmation and reconciliation (P0).** Ways to get the bank's number,
in priority order:
1. **Statement** (PDF import or forwarded email): read the points summary
   (opening, earned, bonus, redeemed, expired, closing) and cashback posted, per
   issuer format.
2. **"Snap your rewards page"**: a screenshot of the bank app, read on the phone
   (we already have on-device text recognition for card scanning).
3. **Manual entry**, one tap from the card.
4. **SMS/email** when a bank does send one.

Per cycle, we show:

```
Estimated 1,840  ·  Bank posted 1,710  ·  Gap −130 (−7%)
Likely reason: ₹2,600 at "BBPS*ELECTRICITY" — bank treated it as utilities (1x)
```

Repeated gaps feed F0.5. Confirmed numbers replace estimates.

**A4 Balance and value (P1).** Balance = last confirmed + estimated since. ₹ value
depends on how the user likes to redeem: statement credit, best voucher, or
airline/hotel transfer, chosen once in settings. "42,000 MR ≈ ₹16,800 as Taj
voucher, ₹10,500 as statement credit."

**A5 Expiry tracking (P1).** Per-card expiry rules from the catalogue (e.g. SBI
24 months). We estimate which points expire first and alert at 60/30/7 days.

**A6 Cashback credit matching (P1).** Match cashback lines on statements to the
cycle's estimate (Swiggy HDFC, Amazon Pay ICICI and so on).

**A7 Merchant loyalty wallet (P2).** Haldiram's, Kushals, Flipkart SuperCoins,
NeuCoins — these already reach us by SMS. Cheap to add later; SaveSage does
SuperCoins.

### Part B — Progress: caps, milestones, unlocks

**B1 Live cap tracker (P0).** For every cap on every card: used / left, reset
date, and what happens after.

```
PhonePe SBI SELECT BLACK
PhonePe bonus  ████████░░  1,240 / 1,500 pts   resets 1 Dec
After that: PhonePe bills earn 1 pt/₹100 → switch to <your next-best card for bills>
```

Alerts at 80% and 100%, with the switch suggestion. This directly covers PhonePe
SBI, Kiwi and Swiggy HDFC.

**B2 Milestone tracker (P0).** Each milestone on its correct window: card year,
calendar year, quarter or month. We ask for the card's start month once when
adding the card, or work it out from the annual-fee charge or the statement. We
show progress, deadline, pace and ₹ value:

```
Amex Platinum Travel — card year ends 14 Mar
₹1.9L  ✓ reached 2 Nov  (7,500 MR)
₹4L    ██████░░░░  ₹2.58L / ₹4L — ₹1.42L to go
       At your pace: 26 Feb ✓ (2 weeks to spare) · worth ≈ ₹4,000
₹7L    unlikely this year at your pace
```

"Worth chasing?" compares the milestone's value with simply using your best other
card, after fees.

**B3 Benefit unlocks (P0).** Anything that unlocks with spend, shown as progress:
- lounge for next quarter ("₹38,000 / ₹50,000 spent this quarter");
- annual fee waiver;
- tier upgrades (Atlas Silver → Gold);
- Kiwi Neon lounge passes at ₹50k / ₹1L / ₹1.5L;
- welcome bonuses ("₹15,000 in first 90 days").

Each unlock condition is stored in one structured shape in the catalogue (see R7).

**B4 Benefit usage and quotas (P1).** Lounge visits used / left this quarter or
year, movie offers, golf rounds, and fuel surcharge waiver used this month.
Lounge visits come from a quick manual log, plus a **suggested** auto-detect from
the small lounge validation charge some programmes put on the card (our data notes
a ₹2 charge that is later reversed on Infinia) and lounge-programme names on SMS.
We confirm with the user before counting.

**B5 Renewal advisor (P1).** 30 days before the renewal fee, we show: fee, waiver
status, value this card earned you this year, and a suggestion — keep, ask for a
waiver, downgrade, or close. Closing comes with a caution about credit-history
age.

### Part C — Which card now (pay-time)

**C1 Recommendation v2 (P0).**
- **Inputs:** merchant (QR/UPI ID, location, search, history); channel; amount;
  platform or app.
- **User state:** caps left, milestone distance, unlock distance, credit-limit
  use, days until statement (interest-free float), and where the card is accepted
  (Amex/Diners acceptance, RuPay for UPI).
- **Output:** best card plus a backup, a one-line why, ₹ value, and what it uses
  up ("uses ₹100 of your ₹1,500 Swiggy cap").
- **"Pay this way for more":** "Order in the Swiggy app, not the website" or
  "Book via SmartBuy: 5x → 10x" — only when the rule is Verified.

**C2 More ways to ask (P1).** Existing: QR scan, home widget, nearby merchants.
Add:
- merchant search with recents;
- quick tiles for the ten most common spends (Swiggy/Zomato, Amazon,
  Flipkart, fuel, groceries, bills, rent, travel, UPI-to-shop, international);
- an **"Ask"** box that answers in plain language **from the engine's numbers
  only**, never free-form AI guesses (SaveSage's users complain its AI answers
  are generic).

**C3 After-the-fact coaching (P1).** When an SMS shows a spend on a weaker card,
a quiet digest or notification, inside the existing notification limits: "Swiggy
on Millennia earned ₹21; Swiggy HDFC would have earned ₹68." A tap sets a rule
("always suggest Swiggy HDFC for Swiggy") through the existing overrides feature.

**C4 Monthly plan (P1).** At the start of each cycle, one card with the month's
plan, updated as caps fill:

```
This month
• Bills & recharges → PhonePe SBI in PhonePe app (until 1,500 bonus pts)
• Food delivery & Dineout → Swiggy HDFC (₹1,500 cashback cap)
• Everything else → Amex Platinum Travel (₹1.42L to the ₹4L milestone by 14 Mar)
• Fuel → IndianOil card (surcharge waiver ₹250 left)
```

**C5 Offers and card features (P2).** Separate **permanent card features** (Swiggy
HDFC covers Dineout; SmartBuy multipliers) from **time-limited offers** (20% at
Cleartrip; birthday week on Dineout), each with validity and an automatic expiry.
Only verified offers are shown. Time-limited offers need ongoing upkeep — see
decision §13.5.

### Part D — Value (what makes it worth paying for)

**D1 Monthly rewards report (P1).** Earned (estimated / confirmed), missed, best
and worst card, effective return % per card, caps hit, milestones moved. It
builds on the existing monthly report work.

**D2 Portfolio audit and next card (P1).** From 6–12 months of real spend: which
cards to keep, and which new card would add the most **after its fee**. Example:
"Swiggy HDFC would have added ₹4,800/yr net." This can carry clearly disclosed
referral links (product plan §22.2).

**D3 Redemption advisor (P2).** Best use of a balance across statement credit,
vouchers and transfer partners, in ₹. Later: compare flight/hotel bookings on
points, like SaveSage's "Travel on Points".

### Part E — Trust, security and privacy (requirements for every feature above)

| # | Requirement |
|---|---|
| E1 | SMS, statements and screenshots are processed **on the phone**. The server gets only what sync and backup need, encrypted as per the existing encryption work. |
| E2 | **Never collect:** full card number, CVV, expiry, bank login, OTP. Last 4 digits only. Statement PDF passwords are used once on the phone and never stored. |
| E3 | **Catalogue integrity:** the rules sent to phones are signed and versioned, so a tampered or half-published catalogue can't change anyone's advice. Publishing only goes through the review gate with an audit log, as today. (Implementation doc to confirm what signing already exists.) |
| E4 | **Gmail:** keep email forwarding and share-to-app as the main paths. Gmail API read access needs Google's restricted-scope security assessment (a recurring cost); do it only if usage justifies it. |
| E5 | **"Ask" assistant:** answers built from engine and catalogue facts; the least context possible is sent; raw SMS is never sent; merchant names are treated as untrusted text. |
| E6 | **Learning from users:** aggregate only, a minimum number of users before a correction is proposed, and admin approval before a published rule changes. |
| E7 | **Honest labels:** "estimated" until confirmed; a "not financial advice" note; the consent text names reward tracking as a purpose (India's DPDP Act). |
| E8 | **No spend pressure:** milestone chasing is opt-in; value is always shown after fees. |

---

## 7. Cards page and key screens

Numbers and card pairings in these mock-ups (and elsewhere in §6) are
illustrative, not verified card terms.

**Cards list: each card tile**

```
┌──────────────────────────────────────────────┐
│ [card art]  Swiggy HDFC  ••4821              │
│ This cycle  ₹612 cashback (est.)  ·  cycle ends 18 Nov
│ Swiggy 10%  ███████░░░  ₹1,050 / ₹1,500       │
│ Next unlock Fee waiver ₹1.62L / ₹2L by Mar   │
│ ⚠ Online 5% cap full → use SBI Cashback      │
└──────────────────────────────────────────────┘
```

Order: cards with something actionable first (cap nearly full, milestone close,
points expiring, statement due).

**Card detail: tabs, simplified to four**

| Tab | Contents |
|---|---|
| **Earn** | Where this card is best (merchants and categories), rates, exclusions, "pay this way for more". |
| **Progress** | Caps, milestones, unlocks, fee waiver, with pace. |
| **Rewards** | Estimated vs confirmed by cycle, balance, ₹ value, expiry, reconciliation gaps. |
| **Benefits** | Lounge and other quotas with usage, insurance, golf, movies. |

Fees and statement details move into a card info section. The card's
Verified / Partial / Basic status shows here.

**Pay-time answer sheet (QR scan, widget, search)**

```
Swiggy · ₹840
✅ Swiggy HDFC — ₹84 back (10%)
   Order in the Swiggy app · ₹1,416 cap left after this
↪ Backup: SBI Cashback — ₹42 (5% online)
   Why not Amex PT? ₹13 now; milestone is 9 weeks away at your pace
```

---

## 8. Data we need to collect

### 8.1 From the user (once, in the add-card flow; each question skippable)

| Data | Why | Sensitivity |
|---|---|---|
| Exact card variant and network (e.g. PhonePe SBI SELECT BLACK, RuPay) | Rules differ by variant; RuPay decides UPI eligibility | Low |
| Last 4 digits | Match SMS to card | Low (already collected) |
| Statement day | Cycle caps, cycle reports, float | Low |
| **Card start month** (or renewal month) | Milestones, fee waivers, card-year caps | Low |
| Current points balance (optional, or a screenshot) | Starting point for the ledger | Medium |
| Tier or membership (Atlas tier, Kiwi Neon, Swiggy One) | Tier rules and unlocks | Low |
| Preferred redemption style | ₹ value of points | Low |
| Milestone chasing on/off | Ethics (E8) | Low |

### 8.2 From SMS and email (on the phone)

- Already read: spends, refunds, reversals, card bill payments, limits, due dates.
- **Add:** cashback credits and reward-credit lines; annual fee charged or
  reversed (this dates the card year); lounge validation charges and lounge
  programme names; EMI conversions (often excluded from rewards); international
  spends (forex); merchant descriptors and UPI IDs, fed into the merchant
  directory (F0.6).

### 8.3 From statements (PDF or forwarded email)

Points summary (opening, earned, bonus, redeemed, expired, closing); cashback
posted; fees and waivers; per-line category codes where printed; statement
period. Parsed per issuer format, starting with the top 10 issuers.

### 8.4 In the catalogue (research and review)

Everything in F0.1, plus: structured unlock conditions; redemption options with
₹ per point by channel and transfer ratios; expiry policy; reversal policy;
change history (devaluations); source and verified-on date for each rule.

### 8.5 Learned over time (aggregate, anonymous, approved)

Estimated vs posted gaps by card and merchant, which catch a merchant coded
differently from what we assumed. Merchant descriptor → merchant mappings.
Acceptance (where Amex or Diners was declined).

---

## 9. Backend and architecture impact (feature level; detail in the implementation doc)

- **Catalogue model v2** and a lossless loader with a per-card coverage report;
  an admin console view for cards that are Partial or have unmodelled rules.
- **Two engines, one answer:** the phone engine (Dart) and the server copy (JS)
  both move to rules v2, with the F0.3 worked examples as shared tests. This
  pattern already exists for caps.
- **Rewards ledger on the phone** (local-first), synced. The server recomputes
  for reports and backup.
- **Statement points reader** per issuer, plus on-device screenshot reading.
- **Progress engine:** caps, milestones and unlocks per correct window, recomputed
  on every new transaction and on every catalogue version change.
- **Notification triggers:** cap 80% / 100%, milestone pace, unlock reached, points
  expiring, renewal coming. These sit inside the existing notification limits.
- **Merchant directory** service, with crowd-learned aliases behind approval.
- **Performance target:** pay-time answer in under 200 ms on the phone, offline.

---

## 10. Free vs paid (hypothesis to decide)

| Free | Pro |
|---|---|
| Best card at pay time | Live caps, milestones, unlocks with alerts |
| Up to 2 cards with progress | Unlimited cards |
| Estimated rewards | Statement reconciliation (estimated vs confirmed) |
| Basic monthly summary | Monthly plan, full report, renewal advisor, redemption advisor |

**Price hypothesis:** about ₹99/month or ₹799–999/year. The test: the monthly
report must show Pro earning **at least 5× its price** in extra or saved rewards
for a typical user. The existing subscription-credits and referral work can carry
trials and credits.

---

## 11. How we'll know it works

| Area | Target |
|---|---|
| **Accuracy** | Verified cards: estimate within ±5% of bank-posted points for 95% of card-cycles |
| **Catalogue** | 0 unreviewed "applies to everything" bonus rules; 100% of caps enforced or explicitly marked info-only; top 50 cards Verified |
| **Coverage** | ≥95% of card spend matched to a card; ≥90% of user spend on Verified cards |
| **Use** | Pay-time checks per weekly active user; share of tracked spend on the recommended card; missed ₹ trending down |
| **Value** | Extra ₹ earned per user per month vs using their single best card |
| **Business** | Pro conversion; 30/90-day retention |

---

## 12. Phasing

The implementation doc will size each phase and start with Phase 1, since every
later phase reads the numbers Phase 1 fixes.

| Phase | Contents | Visible win |
|---|---|---|
| **1 — Trust the rules** | F0.1, F0.2, F0.3 (top 50), F0.6. Fix R1–R9. B1 on corrected data. | Swiggy HDFC, PhonePe SBI and Amex PT give the right answers; caps work. |
| **2 — Ledger and progress** | A1, A2, A3 (statement points + screenshot), B2, B3, A5, Cards page redesign. | "Earned this cycle", milestones and lounge unlocks on the Cards page; bank-confirmed points. |
| **3 — Which card now** | C1, C3, C4, C2 (search, tiles, Ask), F0.4, F0.5, F0.7. | Smarter answers at the counter, a monthly plan, coaching. |
| **4 — Value and Pro** | D1, D2, B4, B5, A4, A6, Pro tier; later D3, C5, A7. | Paid tier with a clear ₹ value. |

---

## 13. Decisions

Work started on 2026-11-05 with these defaults. Any of them can be changed;
the [status tracker](card-rewards-status.md) records the current answer.

| # | Question | Default we are proceeding with |
|---|---|---|
| 1 | Verified-first scope | **All cards** get the model and loader fixes. About 50 cards (Appendix C) also get hand-checked worked examples first; the rest are labelled by what the loader could model. |
| 2 | Card start month | Ask once in the add-card flow (optional), and infer it from fee SMS/statements when skipped. *(Phase 2)* |
| 3 | Bank confirmation source | Statement forwarding/import plus screenshot first; Gmail API only if usage justifies the assessment. *(Phase 2)* |
| 4 | Milestone nudges | Opt-in only. |
| 5 | Offers | Permanent card features only in v1; time-limited offers later. |
| 6 | Free vs Pro | Decide in Phase 4; §10 stays a hypothesis. |
| 7 | Merchant loyalty points | Later (P2). |
| 8 | "Ask" box | Phase 3, engine-backed answers only. |
| 9 | Referral links on next-card suggestions | Yes, clearly disclosed. *(Phase 4)* |

---

## 14. Not in scope

Paying bills or moving money; storing card numbers; bank logins; applying for
cards inside the app (referral links only); investment advice; scraping
competitor apps.

---

## Appendix A — Audit method and numbers

- **Production catalogue:** `GET https://api.pandapath.site/catalogue` on
  2026-11-05 → 377 cards.
  - 641 caps: 442 reward-value, 185 spend, 14 transaction-count; 238 linked to
    no rule or category; 428 with post-cap 0; 211 with no post-cap value.
  - 292 milestones, all with the card-anniversary anchor (232 annual, 46 quarterly,
    6 monthly, 6 statement-cycle, 2 half-year).
  - 408 lounge benefits on 236 cards; 124 on 105 cards have a numeric spend
    condition in free text.
  - 2,509 earning/exclusion rules: only 20 have a merchant pattern; 1,312 are
    zero-rate exclusions.
  - 47 cards have network "unknown".
  - All `verified_at` dates are 2026-08-29/30.
- **Research source:** `CardPipeline/data/checklist.json` — 392 rows; 376
  published, 16 excluded. Per-card JSON (schema v5) contains accrual blocks and
  rounding, app/merchant conditions, caps inside caps, structured lounge
  conditions, redemption options and promotions.
- **Loader:** `api/scripts/import_card_pipeline.js`. It drops rules whose category
  has no mapping, flattens conditions, sets the milestone anchor to
  card-anniversary in both branches, and maps "zero accrual" caps to a 0 post-cap
  rate.
- **Engine:** `packages/pandapay_domain/lib/src/engine/engine.dart`. Rule matching
  uses category, merchant pattern, rail, min/max and dates; `conditions` is not
  read.
- **Real SMS sample:** your Messages history on this Mac, last 12 months,
  institutional senders only. 5,238 messages; about 1,100 spend alerts; ~18
  mention points, ~12 cashback, 1 lounge, 1 milestone; **none were bank
  reward-point messages**. Counts only — no message content was saved.

## Appendix B — Worked examples: today vs correct

Per our research data; these will be re-verified in F0.3. Each row is one
instance of a pattern that repeats across many cards (R1–R9). Phase 1 fixes the
pattern for every card.

| Spend | Card | Today | Should be |
|---|---|---|---|
| ₹1,000 Swiggy order | Swiggy HDFC | 1% = ₹10, and **₹0 after the first ₹500 of spend in the cycle** | 10% = ₹100 (min ₹249), counted against the ₹1,500 cashback cap for the cycle |
| ₹2,000 electricity bill in the PhonePe app | PhonePe SBI SELECT BLACK | 1 pt/₹100 = 20 pts (10x rule missing) | 10 pts/₹100 = 200 pts, until the monthly PhonePe bonus cap (value re-verified in F0.3) |
| ₹5,000 at a local restaurant | Amex Platinum Travel | 6 pts/₹100 = 300 pts (brand-only rate applied) | 2 pts/₹100 = 100 MR pts, plus ₹5,000 toward the ₹1.9L / ₹4L / ₹7L milestones |
| ₹149 UPI scan payment | SBI points card (₹100 blocks, rounded down) | 1.49 pts | 1 pt |
| Lounge on a card needing ₹50k last quarter | Any spend-gated card | Shown as available | "Locked — ₹12,400 more this quarter unlocks next quarter" |
| ₹3,000 Swiggy order after the ₹1,500 cap is used | Swiggy HDFC | Same 1% as any spend (the 10% rule is missing, so the cap never matters) | Ranked on its true post-cap rate per the card terms; the backup card is suggested |

## Appendix C — Proposed first 50 cards to verify (to adjust with real holdings)

- **HDFC:** Infinia, Diners Club Black, Regalia Gold, Millennia, Swiggy HDFC, Tata
  Neu Infinity, PhonePe Uno, PhonePe Ultimo, IndianOil, IRCTC
- **SBI Card:** Cashback, SimplyCLICK, PhonePe SELECT BLACK, PhonePe PURPLE, Tata Neu
  Infinity, Tata Neu Plus, BPCL Octane, Flipkart SBI, IRCTC Premier, AURUM
- **ICICI:** Amazon Pay, Sapphiro, Emeralde, HPCL Super Saver, MakeMyTrip Signature
- **Axis:** Atlas, Magnus, ACE, Flipkart Axis, Airtel Axis, IndianOil Axis
- **Amex:** Platinum Travel, Membership Rewards, Gold, SmartEarn, Platinum
- **IDFC FIRST:** Millennia, Wealth, Select, Power+
- **Others:** PNB Kiwi, YES Klick (Kiwi), AU Zenith, HSBC Live+, Kotak IndiGo, Tata
  Neu HDFC Plus, plus the four missing cards once added (slice, Stable Money,
  OneCard, Scapia)
