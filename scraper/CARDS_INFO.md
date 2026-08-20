# Card data collection template — India (schema-scoped, no data filled in)

Every field below is `TBD` on purpose. This is a data-entry template, not a
data doc: it exists to enumerate exactly what PandaPay's schema needs per
card, scoped one card at a time as requested, so real data can be dropped
in once there's a verified source to drop it from.

## Why no numbers are filled in

The prior pass (`CARDS_BY_ISSUER_INDIA.md`) found that this session's web
tools sit behind a sandboxed/mocked network — official bank URLs silently
redirect to look-alike domains, and repeated fetches of the same page
returned inconsistent results. Reward rates, caps, and conversion ratios
are exactly the kind of figures where a wrong number is actively harmful
in a payments app (wrong "best card for this purchase" advice), so none are
populated here from that channel. Card **names** and **issuers** are
carried forward from `CARDS_BY_ISSUER_INDIA.md`, which is itself flagged
non-exhaustive and unverified — treat those as provisional too.

Filling in the `TBD`s for real requires one of:
- The scraper pipeline (`CANDIDATE_SOURCES.md` + `db/scripts/review_source.py`)
  once a source is ToS-cleared, which is the only path in this repo that
  produces `verified_at` / `source_url`-backed data per `card_products`'s
  `card_published_needs_verification` constraint (nothing can be marked
  `published` without a `verified_at` timestamp).
- Manual entry by someone reading the issuer's actual current terms page
  and citing it in `source_url`.

## Source URL guesses (added in a later pass)

Every card's `source_url` field now carries an **issuer-level page guess**,
e.g. `TBD -- issuer-page guess, unverified: https://...`. These come from
`CANDIDATE_SOURCES.md`'s issuer domains (real, known bank domains —
independent of this session's unreliable fetch tools) — not from a
per-card deep link. Guessing an exact per-card URL slug (e.g.
`/regalia-gold-credit-card`) would be a much lower-confidence guess likely
to 404, so this deliberately stops at "here's the issuer's card section,
go find this specific card on it" rather than pretending to know the exact
path. Deutsche Bank and Citibank cards point at their successor issuers'
pages (IndusInd Bank and Axis Bank respectively) since neither issuer is
still live in India. The `TBD` is left in place because a guessed URL is
still not a verified source — someone still needs to open it and confirm.

## Field glossary (maps 1:1 to `database.sql`)

| Field | Source table.column | Notes |
|---|---|---|
| network | `card_products.network` | rupay / visa / mastercard / amex / diners |
| card_type | `card_products.card_type` | credit / debit / prepaid / forex |
| joining_fee_inr / annual_fee_inr | `card_products` | plus `fee_gst_applicable` |
| is_upi_linkable | `card_products.is_upi_linkable` | RuPay credit only |
| base_reward_unit / base_reward_rate | `card_products` | fallback "all other spends" rate |
| point_value_inr / point_value_basis | `card_products` | our own valuation + how we derived it |
| category_reward_rules | `reward_rules` | per category/merchant/rail: unit, rate, min/max txn, priority |
| cap_rules | `cap_rules` | the "killer feature" — spend caps, post-cap rate, reset day |
| milestone_rules | `milestone_rules` | spend-threshold bonuses, repeatable or not |
| fee_waiver_rules | `fee_waiver_rules` | annual-fee waiver threshold, excluded categories |
| benefits | `card_benefits` | lounge/golf/concierge/insurance/dining/movie/fuel/roadside, quota + program |
| forex_markup_percent | `forex_rules` | + GST-on-markup flag, waiver notes |
| fuel_surcharge | `fuel_surcharge_rules` | surcharge %, waiver %, min/max txn, monthly cap |
| billing_cycle_grace_days | `billing_cycle_rules` | float-optimizer default |
| redemption_options | `redemption_options` | program, method, ₹ value per point, min points |
| source_url / verified_at / verified_by | `card_products` | required before `status = 'published'` |

## Per-card template (copy this block per card)

```
#### <Card Name>
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD
- verified_at: TBD
- verified_by: TBD
```

---

## ⚠ Network reliability warning (found during a follow-up pass)

## Public sector banks

### State Bank of India (SBI Card)

> Numerous co-branded variants issued jointly with regional/PSU banks (see "co-branded via SBI Card" note under each of those banks below)

#### SBI Card ELITE
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### SBI Card PRIME
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### SimplySave
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### SimplyClick
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### Cashback SBI Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### BPCL SBI Card Octane
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### Air India SBI Signature
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD

#### IRCTC SBI Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sbicard.com/en/personal/credit-cards.page
- verified_at: TBD
- verified_by: TBD


### Bank of Baroda (via BOBCARD Ltd.)

#### BOBCARD Eterna
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BOBCARD Premier
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BOBCARD IRCTC
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BOBCARD Snapdeal
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BOBCARD Defence Personnel Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BOBCARD Corporate
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bobcard.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD


### Punjab National Bank

#### PNB RuPay Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB RuPay Millennial
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB SALARY RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB LUXURA RuPay Metal
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB Kiwi Credit Card
_fintech co-brand, lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB Patanjali RuPay Select
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### PNB EMT RuPay Platinum
_EaseMyTrip co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.pnbindia.in/credit-card.html
- verified_at: TBD
- verified_by: TBD


### Canara Bank

#### Canara Visa Classic / MasterCard Standard Global
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara Visa Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara RuPay Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara MasterCard World
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara Visa Signature Travel
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara Visa Signature Business
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara Select Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD

#### Canara Travel Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://canarabank.com/user_pages/Credit-Cards
- verified_at: TBD
- verified_by: TBD


### Union Bank of India

#### Union Bank RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD

#### Union Bank RuPay Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD

#### Visa Signature / Visa Gold / Visa Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD

#### Divaā Credit Card
_women-focused_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD

#### Union JCB Wellness Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD

#### PM SVANidhi RuPay Credit Card
_street vendors_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.unionbankofindia.co.in/english/credit-card.aspx
- verified_at: TBD
- verified_by: TBD


### Bank of India

#### BOI RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://bankofindia.co.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### BOI Celestia RuPay Ekaa
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://bankofindia.co.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### BOI Navy Classic
_Indian Navy personnel_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://bankofindia.co.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### BOI Visa Platinum International
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://bankofindia.co.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### BOI RuPay Swadhan Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://bankofindia.co.in/credit-card
- verified_at: TBD
- verified_by: TBD


### Indian Bank

> Otherwise reported to lean on co-branded SBI Card partnership products (not independently confirmed in this pass)

#### Indian Bank Bharat Credit Card
_own-issued, free, low limit_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indianbank.in/personal-banking/credit-card/
- verified_at: TBD
- verified_by: TBD


### Central Bank of India

#### Central Bank of India Prime Card
_co-branded with SBI Card_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.centralbankofindia.co.in/en/credit-card
- verified_at: TBD
- verified_by: TBD

#### Central Bank of India Aspire Credit Card
_FD-backed, against Cent Aspire term deposit_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.centralbankofindia.co.in/en/credit-card
- verified_at: TBD
- verified_by: TBD


### Indian Overseas Bank

#### IOB Gold
_Visa_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.iob.in/Credit_Card
- verified_at: TBD
- verified_by: TBD

#### IOB Classic
_Visa_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.iob.in/Credit_Card
- verified_at: TBD
- verified_by: TBD

#### IOB RuPay Classic
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.iob.in/Credit_Card
- verified_at: TBD
- verified_by: TBD

#### IOB RuPay Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.iob.in/Credit_Card
- verified_at: TBD
- verified_by: TBD


### UCO Bank

> UCO Bank credit cards issued in partnership with SBI Card; aggregators cite ~3 variants, plus sector-specific cards for artisans, fishermen, handloom weavers, auto-rickshaw owners, and SHGs. Exact current retail variant names weren't resolved in this pass — check uco.bank.in directly.


### Punjab & Sind Bank

#### PSB SBI Card ELITE
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.punjabandsindbank.co.in/en/credit-card/
- verified_at: TBD
- verified_by: TBD

#### PSB SBI Card PRIME
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.punjabandsindbank.co.in/en/credit-card/
- verified_at: TBD
- verified_by: TBD

#### PSB SimplySAVE SBI Card
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.punjabandsindbank.co.in/en/credit-card/
- verified_at: TBD
- verified_by: TBD

#### RuPay Kisan Credit Card
_farmer-focused, distinct product line_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.punjabandsindbank.co.in/en/credit-card/
- verified_at: TBD
- verified_by: TBD


## Private sector banks

### HDFC Bank

#### Infinia
_invite-only, top-tier_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Diners Club Black
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Regalia Gold
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Regalia First
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Diners Club Privilege
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Diners Club Miles
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Millennia
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### MoneyBack+
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Freedom
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Pixel Go
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Pixel Play
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Tata Neu Infinity
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Tata Neu Plus
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Shoppers Stop
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Shoppers Stop Black
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Paytm HDFC Bank Credit Card
_co-brand, multiple variants_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hdfcbank.com/personal/pay/cards/credit-cards
- verified_at: TBD
- verified_by: TBD


### ICICI Bank

#### Emeralde Private Metal
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Emeralde
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Sapphiro
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Rubyx
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Coral
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Amazon Pay ICICI Bank Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### HPCL Super Saver
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Chennai Super Kings ICICI Bank Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Emirates Skywards ICICI Bank
_variants_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### InterMiles ICICI Bank
_variants_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Parakram
_variants_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.icicibank.com/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD


### Axis Bank

#### Magnus
_super-premium_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Reserve
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### ACE
_flat-rate cashback_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### MyZone
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Rewards
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Neo
_RuPay, lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### LIC Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### LIC Signature
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Flipkart Axis Bank Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Samsung Axis Bank Signature Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Vistara Axis Bank
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### SpiceJet Axis Bank
_co-brands_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Axis Bank REWARDS
_ex-Citi Rewards, post-migration_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Axis Horizon
_ex-Citi PremierMiles, post-migration_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Axis Cashback
_ex-Citi Cashback, post-migration_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### INDIANOIL AXIS BANK PREMIUM
_ex-IndianOil Citi, post-migration_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.axisbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD


### Kotak Mahindra Bank

#### White Reserve
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### Royale Signature
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### Zen Signature
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### Kotak 811
_entry-level_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### Myntra Kotak Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### IndiGo Kotak 6E Rewards XL
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### IndiGo Kotak 6E Rewards
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD

#### IndianOil Kotak Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.kotak.com/en/personal-banking/cards/credit-cards.html
- verified_at: TBD
- verified_by: TBD


### IndusInd Bank

#### Pinnacle World
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Pioneer Heritage
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Pioneer Legacy
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Celesta
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Crest
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Indulge
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Legend
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Avios Visa Infinite
_Qatar Airways / British Airways_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Club Vistara IndusInd Bank Explorer
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Iconia Visa
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Iconia Amex
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Signature Visa
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Platinum Aura Edge
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Platinum Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### EazyDiner IndusInd Bank Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Duo Plus
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Intermiles Voyage Visa
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Payback
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD

#### Nexxt
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.indusind.com/in/en/personal/cards/credit-card.html
- verified_at: TBD
- verified_by: TBD


### Yes Bank

#### Yes Private
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Yes Private Prime
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Marquee
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### YES Premia
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### YES First Preferred
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### YES First Exclusive
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Wellness
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Wellness Plus
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Klick RuPay
_with Kiwi, lifetime-free, fully digital_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### BYOC
_Build Your Own Card_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD

#### EMI Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.yesbank.in/personal-banking/yes-premia/credit-cards
- verified_at: TBD
- verified_by: TBD


### IDFC FIRST Bank

#### FIRST Private
_top tier_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Gaj
_invite-only, ₹12,500_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Mayura
_₹5,999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Ashva
_₹2,999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Wealth
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Select
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Classic
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Millennia
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Click
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Power+ / HPCL Power
_fuel_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### SWYP
_youth-focused_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### LIC Classic
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### LIC Select
_co-branded_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### WOW!
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### WOW! Black
_FD-backed_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### EARN
_FD-backed_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idfcfirstbank.com/credit-card
- verified_at: TBD
- verified_by: TBD


### RBL Bank

#### Platinum Maxima
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Platinum Delight
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Titanium Delight
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### IndianOil RBL Bank Credit Card
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Zomato
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Practo
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### TVS Credit
_co-brands_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Numerous additional fintech co-branded programs
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.rblbank.com/personal-banking/cards/credit-cards
- verified_at: TBD
- verified_by: TBD


### Federal Bank

#### Federal Celesta
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.federalbank.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Federal Scapia
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.federalbank.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Federal Signet
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.federalbank.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Federal Visa Signature
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.federalbank.co.in/credit-cards
- verified_at: TBD
- verified_by: TBD


### South Indian Bank

#### South Indian Bank OneCard
_fintech co-brand, lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.southindianbank.com/content/credit-cards/70/108
- verified_at: TBD
- verified_by: TBD

#### Co-branded SBI Card variants
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.southindianbank.com/content/credit-cards/70/108
- verified_at: TBD
- verified_by: TBD

#### RuPay credit cards
_UPI-linked_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.southindianbank.com/content/credit-cards/70/108
- verified_at: TBD
- verified_by: TBD


### IDBI Bank

#### Royale Signature
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idbibank.in/credit-cards.aspx
- verified_at: TBD
- verified_by: TBD

#### Aspire Platinum
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idbibank.in/credit-cards.aspx
- verified_at: TBD
- verified_by: TBD

#### Euphoria World
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idbibank.in/credit-cards.aspx
- verified_at: TBD
- verified_by: TBD

#### Imperium Platinum
_FD-backed/secured, Visa_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idbibank.in/credit-cards.aspx
- verified_at: TBD
- verified_by: TBD

#### Winnings
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.idbibank.in/credit-cards.aspx
- verified_at: TBD
- verified_by: TBD


### Bandhan Bank

> (Standard Chartered Bandhan Bank co-branded cards existed but are no longer accepting new applications)

#### One
_₹299 annual fee_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bandhanbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Plus
_₹699 annual fee_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bandhanbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Xclusive
_₹2,999 annual fee_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bandhanbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD


### CSB Bank

#### Edge+ CSB Bank RuPay Credit Card
_with Jupiter_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.csb.co.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### Edge CSB Bank RuPay Credit Card
_with Jupiter_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.csb.co.in/credit-card
- verified_at: TBD
- verified_by: TBD


### DCB Bank

#### DCB PayLess
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.dcbbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### DCB Niyo
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.dcbbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### DCB Novio
_RuPay, FD-backed_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.dcbbank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD


### Tamilnad Mercantile Bank (TMB)

#### TMB Wings RuPay Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### TMB Phoenix RuPay Credit Card
_business_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### TMB Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### TMB Titanium
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### TMB General Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD

#### TMB India Card Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.tmb.in/credit-card
- verified_at: TBD
- verified_by: TBD


### Karnataka Bank

#### Karnataka Bank SimplySAVE SBI Card
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://karnatakabank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Karnataka Bank SBI Card Prime / Platinum SBI Card
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://karnatakabank.com/personal/cards/credit-card
- verified_at: TBD
- verified_by: TBD


### City Union Bank

#### City Union Bank SBI SimplySave
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### City Union Bank SBI Prime Card
_co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### Dhi CUB Visa Signature
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### Platinum
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### Master
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### RuPay
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD

#### CUB SalarySe Level Up Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.cityunionbank.com/personal-credit-card
- verified_at: TBD
- verified_by: TBD


## Small finance banks

### AU Small Finance Bank

#### Zenith+
_₹4,999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Vetta
_₹2,999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Altura Plus
_₹499_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Altura
_₹199_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### ixigo
_lifetime-free, travel co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### LIT
_lifetime-free, customizable feature packs_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### Spont
_invite-only_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.aubank.in/personal/cards/credit-cards
- verified_at: TBD
- verified_by: TBD


### Equitas Small Finance Bank

#### Selfe
_digital-first_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.equitasbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### PowerMiles
_premium travel_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.equitasbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Tiga
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.equitasbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Excite
_HDFC Bank co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.equitasbank.com/credit-card
- verified_at: TBD
- verified_by: TBD

#### Elegance
_HDFC Bank co-brand, higher limit tier_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.equitasbank.com/credit-card
- verified_at: TBD
- verified_by: TBD


### Ujjivan Small Finance Bank

#### USFB Elite
_BOBCARD co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.ujjivansfb.in/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### USFB Platinum
_BOBCARD co-brand_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.ujjivansfb.in/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD

#### Credit Card Against FD
_secured_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.ujjivansfb.in/personal-banking/cards/credit-card
- verified_at: TBD
- verified_by: TBD


## Foreign banks (India operations)

### American Express India

> Note: Amex India has periodically paused new consumer card applications.

#### Platinum Charge
_invite-only / highest tier_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.americanexpress.com/en-in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Gold Charge
_no preset spending limit_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.americanexpress.com/en-in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Platinum Travel Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.americanexpress.com/en-in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Membership Rewards Credit Card
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.americanexpress.com/en-in/credit-cards/
- verified_at: TBD
- verified_by: TBD


### Standard Chartered

#### Ultimate
_₹5,000_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Emirates World
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Manhattan Platinum
_₹999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### EaseMyTrip
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### DigiSmart
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Platinum Rewards
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.sc.com/in/credit-cards/
- verified_at: TBD
- verified_by: TBD


### HSBC

#### TravelOne
_₹4,999_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Visa Platinum
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### RuPay Platinum
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### RuPay Cashback
_lifetime-free_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Live+
_₹999, upgraded to Visa Infinite mid-2026_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Premier Metal
_₹20,000, invite-only, Premier banking tier_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD

#### Taj co-branded card
_luxury-hotel specialist, sits outside the main lineup_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.hsbc.co.in/credit-cards/
- verified_at: TBD
- verified_by: TBD


### DBS Bank

> DBS SuperX / DBS SuperX Plus (successor cards for migrated Bajaj Finserv DBS SuperCard holders — see Bajaj Finserv note below)

#### DBS Vantage
_premium/travel_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.dbs.com/in/treasures/cards/credit-cards
- verified_at: TBD
- verified_by: TBD

#### DBS Spark
_Spark5 / Spark10 / Spark20 variants_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.dbs.com/in/treasures/cards/credit-cards
- verified_at: TBD
- verified_by: TBD


## NBFCs / fintech co-branded issuers

### OneCard (FPL Technologies)

> OneCard Lite (FD-backed, via SBM Bank India; also branded "South Indian Bank OneCard" and similar bank-specific co-brands)

#### OneCard Metal
_unsecured, plastic/metal card_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.getonecard.app
- verified_at: TBD
- verified_by: TBD


### Slice

> Slice Super Card / Slice UPI Credit Card (RuPay, lifetime-free, issued via Slice Small Finance Bank following its bank license/merger)


### Bajaj Finserv (co-branded — winding down)

> Bajaj Finserv DBS Bank SuperCard — discontinued for new issuance since 23 Nov 2024; existing holders migrated to DBS SuperX / SuperX Plus, effective 1 Aug 2026

#### Bajaj Finserv RBL Bank SuperCard / Platinum Plus SuperCard — partnership ended
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.bajajfinserv.in/cards
- verified_at: TBD
- verified_by: TBD


### LazyPay / PayU

#### LazyCard
_credit line-backed card issued via SBM Bank India, with an FD-backed "Booster" variant_
- network: TBD
- card_type: TBD
- joining_fee_inr: TBD
- annual_fee_inr: TBD
- fee_gst_applicable: TBD
- is_upi_linkable: TBD
- base_reward_unit: TBD
- base_reward_rate: TBD
- point_value_inr: TBD
- point_value_basis: TBD
- category_reward_rules: TBD
- cap_rules: TBD
- milestone_rules: TBD
- fee_waiver_rules: TBD
- benefits: TBD
- forex_markup_percent: TBD
- fuel_surcharge: TBD
- billing_cycle_grace_days: TBD
- redemption_options: TBD
- source_url: TBD -- issuer-page guess, unverified: https://www.lazypay.in
- verified_at: TBD
- verified_by: TBD

## Confidence notes / known gaps

- 235 card entries generated from `CARDS_BY_ISSUER_INDIA.md`; every one is a
  template shell, none carry real reward/fee/benefit data.
- Several entries are ambiguous multi-card bullets from the source doc kept
  as a single template (e.g. "Canara Visa Classic / MasterCard Standard
  Global", "Visa Signature / Visa Gold / Visa Platinum" under Union Bank) —
  these may actually be 2-3 distinct `card_products` rows once real data is
  entered; split them at that point if the issuer's site treats them as
  separate products.
- Blockquoted notes under some issuers (Indian Bank, UCO Bank, Amex, Slice,
  Bajaj Finserv, OneCard, DBS) are carried-over context from
  `CARDS_BY_ISSUER_INDIA.md`, not additional cards.
- Nothing here should be bulk-imported into `card_products` as-is — every
  `TBD` needs a real value and a `source_url` before `status` can legally
  move past `draft` (`card_published_needs_verification` constraint).
