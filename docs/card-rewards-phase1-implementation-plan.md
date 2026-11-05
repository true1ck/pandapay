# Card Rewards — Phase 1 Implementation Plan ("Trust the rules")

**Date:** 2026-11-05 · **Branch:** `card-rewards/phase1` (integration) ·
**Feature spec:** [card-rewards-intelligence-feature-spec-2026-11-05.md](card-rewards-intelligence-feature-spec-2026-11-05.md) ·
**Agent plan:** [card-rewards-phase1-agent-plan.md](card-rewards-phase1-agent-plan.md) ·
**Status:** [card-rewards-status.md](card-rewards-status.md) ·
**Later phases:** [card-rewards-later-phases.md](card-rewards-later-phases.md)

---

## 1. Goal

Every card in the catalogue earns, caps and unlocks in PandaPay the way it does
at the bank. This is fixed **as patterns for all cards**, not per card. At the
end of Phase 1:

1. No bonus rule is dropped or widened. Anything we can't model is shown as
   information and never ranked.
2. Merchant, app/portal, MCC, rounding and cap semantics are modelled the same
   way in the phone engine (Dart) and the server engine (JS).
3. Caps work: bonus-only vs total, caps inside caps, native units (points,
   ₹ cashback, spend, count), and the right post-cap behaviour.
4. Milestones run on the right clock.
5. Spend-gated benefits (lounge etc.) are structured data. Showing progress is
   Phase 2.
6. Each card carries a model status (Verified / Partial / Basic). About 50 cards
   are Verified against worked examples from issuer documents.
7. The Cards page shows live cap bars in native units, with 80% / 100% alerts (B1).
8. Old app installs keep working.

**Out of Phase 1:** points ledger UI, statement reconciliation, milestone and
unlock progress UI, monthly plan, "Ask". See [later phases](card-rewards-later-phases.md).

## 2. Hard constraints (read before writing code)

| # | Constraint | Why |
|---|---|---|
| H1 | **The v1 feed (`GET /catalogue`) keeps its exact shape and enum values.** Installed apps parse the whole catalogue in one go (`catalogueProvider` → `CardProductJson.fromJson`); one unknown enum value (unit, measure, period, rail, network, benefit kind) makes the whole feed fail and the app falls back to 9 bundled cards. New semantics ship only in the v2 feed (`GET /catalogue?schema=2`). | Old installs |
| H2 | **Never widen.** A rule whose restriction we can't express becomes `rule_role = 'info'` (shown, never ranked) and is excluded from v1. Hiding a bonus (under-recommend) is acceptable; applying it everywhere (over-recommend) is not. | Trust |
| H3 | **Additive database changes only.** New columns are nullable or defaulted; no column is dropped or renamed. Old server code must keep working against the new schema during rollout. | Zero-downtime deploy |
| H4 | **Engines stay in step.** Dart (`packages/pandapay_domain`) and JS (`api/src/reward_math_v2.js`) must pass the same scenario files in `db/fixtures/reward_v2_scenarios/`. v1-shaped cards (no v2 fields) must give exactly today's answers; all existing tests pass unchanged. | Parity |
| H5 | **No production actions by agents.** No deploys, no prod DB, no publishing, no pushes. Rollout (§9) is done by the owner. | Safety |
| H6 | **Privacy.** No real SMS content, account numbers or personal data in fixtures or commits. Research quotes from issuer pages stay under 25 words. | DPDP, copyright |
| H7 | **Batch heavy checks.** Each work package runs its own targeted tests. Full suites and app builds run at integration checkpoints only. | Owner preference |

## 3. Architecture (Phase 1)

```
CardPipeline JSON (v5, sibling repo)
   │  api/scripts/import_card_pipeline.js  →  catalogue_v2/transform.js (pure)
   │      + catalogue_overrides/<slug>.json (reviewed research fixes)
   │      + db/fixtures/merchant_directory.json (merchant + platform slugs)
   ▼
Postgres catalogue (additive v2 columns + new tables)          coverage report
   │                                                           (.staging/*.json/md)
   ├─ v_card_catalogue_export      → GET /catalogue            (v1, filtered, unchanged shape)
   └─ v_card_catalogue_export_v2   → GET /catalogue?schema=2   (v2 + merchants + platforms)
                                         │
              ┌──────────────────────────┴───────────────────────────┐
              ▼                                                      ▼
   Phone: CardProductJson v2 (tolerant)                  Server: reward_math_v2.js
          RecommendationEngine v2                                applyTransactionState v2
          Cards page cap bars (B1)                               cap_states (native units, multi-cap)
              ▲                                                      ▲
              └────────── db/fixtures/reward_v2_scenarios/*.json ────┘  (shared contract tests)
                          db/fixtures/card_worked_examples/*.json       (issuer-verified examples)
```

## 4. Contracts

These are the interfaces between work packages. Agents must implement to them
exactly. A change to a contract is made by the lead in this file first, then
announced to affected work packages.

### C1 — Database schema v2

Migration file: `db/supabase/migrations/20261105120000_card_rules_v2.sql`. All
new child tables get the existing `pandapay.bump_card_data_version()` trigger.
Mirror the existing RLS pattern (published-or-admin read, admin write) on every
new table.

**`card_products`** (add)

| Column | Type | Notes |
|---|---|---|
| `accrual_block_inr` | `int` null | Default points block (100/125/150/200/500) |
| `accrual_rounding` | `text` null, check in (`floor`,`round`,`none`) | Per-transaction rounding of blocks |
| `points_expiry_months` | `int` null | |
| `model_status` | `text not null default 'basic'`, check in (`verified`,`partial`,`basic`) | |
| `model_coverage` | `jsonb not null default '{}'` | Shape in C7.10 |

**`reward_rules`** (add)

| Column | Type | Notes |
|---|---|---|
| `rule_role` | `text not null default 'earn'`, check in (`base`,`earn`,`exclusion`,`info`) | `info` = never ranked |
| `merchant_slugs` | `text[] not null default '{}'` | Any-of; slugs from `merchant_brands` |
| `platform_slugs` | `text[] not null default '{}'` | Any-of; slugs from `payment_platforms` |
| `mcc_include` | `text[] not null default '{}'` | 4-digit strings |
| `mcc_exclude` | `text[] not null default '{}'` | |
| `block_inr` | `int` null | Overrides the unit's block; `rate` = points per `block_inr` |
| `min_engine_version` | `int not null default 1`, check between 1 and 2 | 2 ⇒ hidden from the v1 feed |
| `source_local_id` | `text` null | CardPipeline rule id |
| `display_note` | `text` null | Plain-language rule text for the UI |

**`cap_rules`** (add)

| Column | Type | Notes |
|---|---|---|
| `cap_kind` | `text` null, check in (`bonus_points`,`total_points`,`bonus_cashback`,`total_cashback`,`eligible_spend`,`txn_count`) | null = legacy row (see C3.6) |
| `cap_amount` | `numeric(14,2)` null | **Native units:** points, ₹ cashback, ₹ spend, or a count |
| `scope` | `text not null default 'targets'`, check in (`targets`,`card`) | `card` = applies to all earning on the card |
| `parent_cap_id` | `uuid` null → `cap_rules(id)` on delete set null | Cap inside a cap |
| `post_cap_behavior` | `text` null, check in (`base_rate`,`zero`,`custom_rate`) | Used by `eligible_spend` / `txn_count` |
| `anchor` | `text` null, same values as `milestone_rules.anchor` | For card-year caps |
| `min_engine_version` | `int not null default 1` | |
| `source_local_id` | `text` null | |

**`cap_rule_targets`** (new): `cap_rule_id uuid → cap_rules on delete cascade`,
`reward_rule_id uuid → reward_rules on delete cascade`, primary key (both).

**`milestone_rules`** (add): `reward_points numeric(14,2)` null; `reward_kind text`
null, check in (`points`,`voucher`,`cashback`,`fee_waiver`,`benefit`,`other`);
`excluded_category_ids uuid[] not null default '{}'`; `window_days int` null
(e.g. welcome "₹15,000 in 90 days"); `source_local_id text` null.

**`benefit_unlock_rules`** (new)

| Column | Type |
|---|---|
| `id` | `uuid pk default gen_random_uuid()` |
| `card_product_id` | `uuid not null → card_products on delete cascade` |
| `card_benefit_id` | `uuid` null → `card_benefits on delete cascade` |
| `kind` | `text not null`, check in (`lounge_domestic`,`lounge_international`,`lounge_railway`,`fee_waiver`,`tier`,`welcome`,`membership`,`other`) |
| `label` | `text not null` |
| `spend_threshold_inr` | `numeric(14,2) not null` |
| `spend_window` | `text not null`, check in (`previous_calendar_quarter`,`current_calendar_quarter`,`previous_calendar_month`,`calendar_month`,`card_year`,`calendar_year`,`first_days_after_issue`,`rolling_days`) |
| `window_days` | `int` null |
| `unlocks_quota` | `int` null |
| `unlocks_period` | `cap_period` null |
| `tier_label` | `text` null |
| `excluded_category_ids` | `uuid[] not null default '{}'` |
| `notes` | `text` null |
| `source_local_id` | `text` null |
| `created_at` | `timestamptz not null default now()` |

**`merchant_brands`** (new, public read): `slug text pk`, `name text not null`,
`parent_slug text null → merchant_brands(slug)`, `category_slug text` null,
`aliases text[] not null default '{}'`, `vpa_prefixes text[] not null default '{}'`,
`mcc text[] not null default '{}'`, `is_active boolean not null default true`,
`updated_at timestamptz not null default now()`.

**`payment_platforms`** (new, public read): `slug text pk`, `name text not null`,
`kind text not null` check in (`payment_app`,`bank_portal`,`merchant_app`,`network_program`),
`issuer_slug text` null, `aliases text[] not null default '{}'`, `notes text` null,
`is_active boolean not null default true`.

These are seeded from `db/fixtures/merchant_directory.json` by
`api/scripts/seed_merchant_directory.js` (idempotent upsert).

### C2 — Catalogue feeds

**v1 — `GET /catalogue` (unchanged contract).** `v_card_catalogue_export` is
redefined to:
- include `reward_rules` only where `min_engine_version = 1 and rule_role <> 'info'`;
- include `cap_rules` only where `min_engine_version = 1`;
- keep every existing key, type and enum domain.

New columns appear inside rule objects (because of `to_jsonb`); v1 clients
ignore unknown keys. That's acceptable, but the v1 `measure`, `unit`, `period`
and `rail` values must stay within today's enums.

**v2 — `GET /catalogue?schema=2`.** `v_card_catalogue_export_v2` plus the
directory. Response:

```json
{
  "schema": 2,
  "cards": [ { "...all v1 card keys...": "...",
    "accrual_block_inr": 100, "accrual_rounding": "floor", "points_expiry_months": 24,
    "model_status": "partial", "model_coverage": { },
    "reward_rules": [ { "...v1 keys...": "...", "rule_role": "earn", "merchant_slugs": [], "platform_slugs": ["phonepe_app"],
                        "mcc_include": [], "mcc_exclude": [], "block_inr": null, "min_engine_version": 2,
                        "source_local_id": "phonepe-10x", "display_note": "10 pts/₹100 on eligible PhonePe-app spends" } ],
    "cap_rules": [ { "...v1 keys...": "...", "cap_kind": "bonus_points", "cap_amount": 1500, "scope": "targets",
                     "targets": ["<reward_rule uuid>"], "parent_cap_id": null, "post_cap_behavior": null,
                     "anchor": null, "min_engine_version": 2, "source_local_id": "phonepe-other-monthly" } ],
    "milestone_rules": [ { "...v1 keys...": "...", "reward_points": 10000, "reward_kind": "points",
                           "excluded_category_ids": [], "window_days": null } ],
    "unlock_rules": [ { "id": "...", "kind": "lounge_domestic", "label": "...", "spend_threshold_inr": 50000,
                        "spend_window": "previous_calendar_quarter", "unlocks_quota": 2, "unlocks_period": "quarter" } ],
    "redemption_options": [ { "program_name": "...", "method": "statement_credit", "value_per_point_inr": 0.25, "min_points": null } ]
  } ],
  "merchants": [ { "slug": "swiggy", "name": "Swiggy", "parent_slug": null, "category_slug": "dining",
                   "aliases": ["swiggy", "bundl technologies"], "vpa_prefixes": ["swiggy"], "mcc": ["5814"] } ],
  "platforms": [ { "slug": "phonepe_app", "name": "PhonePe app", "kind": "payment_app", "aliases": ["phonepe"] } ]
}
```

The v2 view publishes **all** rules (all roles and engine versions). Rule `id`s
are the same in both feeds. Route code lives in a new `api/src/catalogue_route.js`;
`index.js` only registers it.

### C3 — Reward engine v2 semantics (both engines)

**C3.1 Context**

| Field | Notes |
|---|---|
| `amount` | ₹ > 0 |
| `occurred` | date/time |
| `category_id` / `category_slug` | |
| `mcc` | 4-digit string or null |
| `merchant_name` | Raw text from SMS/QR/search |
| `merchant_vpa` | |
| `merchant_slug` | Resolved; if null, the engine resolves it per C5 |
| `platform` | Slug or null. **The engine never infers it**; callers do. |
| `rail` | `upi_qr` / `swipe` / `online` / `contactless` / `atm` / `emi` / `unknown` |

**C3.2 v1 compatibility switch.** A card is **v2-shaped** if any of its
rules/caps carries a v2 field (`rule_role` present, or `cap_kind` non-null), or
the card has `accrual_rounding`. v1-shaped cards use today's code path,
byte-for-byte.

**C3.3 Rule applicability (v2).** All restrictions are AND-ed:
1. Effective dates: same as v1.
2. `rule_role` is `base` or `earn` for earning, `exclusion` for exclusions; `info` never applies.
3. `category_id` set ⇒ must equal `ctx.category_id` (v1 semantics).
4. `excluded_categories` contains `ctx.category_id` ⇒ no.
5. `merchant_slugs` non-empty ⇒ the resolved merchant slug, **or any of its
   ancestors** via `parent_slug`, is in the set. Unknown merchant ⇒ no.
6. `platform_slugs` non-empty ⇒ `ctx.platform` is in the set. Unknown ⇒ no.
7. `mcc_include` non-empty ⇒ `ctx.mcc` is in the set. If `ctx.mcc` is unknown and
   the rule also has `category_id`, the category match (step 3) stands in for
   the MCC; otherwise no.
8. `mcc_exclude` contains `ctx.mcc` ⇒ no.
9. `rail` set ⇒ `ctx.rail` must equal it. **Unknown rail does not match on
   v2-shaped cards** (v1 keeps its old "unknown passes" behaviour).
10. `min_txn_inr` ⇒ `amount ≥ min`.

**C3.4 Rule selection.**
1. If any applicable `exclusion` rule matches, or the card's `excluded_categories`
   contains the category, the result is excluded: 0 earned, `excluded = true`,
   reason from `display_note`.
2. Otherwise, among applicable `base`/`earn` rules, choose the lowest `priority`.
   On a tie, choose the highest effective ₹-per-₹ rate.
3. If none applies, use the card's base unit/rate as an implicit base rule
   (id `null`).

**C3.5 Accrual.**
- Spend that is eligible for the rule is `min(amount, max_txn_inr)`. Spend above
  `max_txn_inr` earns the base rate (v1 behaviour).
- **Cashback / discount units:** `cashback = eligible × rate / 100`, kept to
  paise.
- **Points units:**
  - `block = rule.block_inr ?? unitBlock(unit)`, where unitBlock is
    points_per_100 → 100, points_per_150 → 150, points_per_200 → 200,
    miles_per_100 → 100.
  - `blocks = round_mode(eligible / block)`. `round_mode` is the card's
    `accrual_rounding`: `floor` (default when null on a v2 card), `round`
    (half-up), or `none` (fractional).
  - `points = blocks × rate`.
- **Flat points:** `points = rate` once per transaction.
- **Base vs bonus.** `base_accrual` is the card's base unit/rate on the same
  eligible spend, with the same rounding and the base unit's own block.
  `bonus = max(0, rule_accrual − base_accrual)`, but only if the rule and the
  base are the same currency (both points or both cashback). Otherwise
  `bonus = rule_accrual` and `base_accrual = 0`. For `base` rules, `bonus = 0`.
- **Value:** `value_inr = points × point_value_inr`, or the cashback in ₹,
  rounded half-up to 2 decimals.

**C3.6 Caps.** Every cap amount is in native units: points for `*_points`, ₹ for
`*_cashback` and `eligible_spend`, a count for `txn_count`.

*Which caps apply.* The applicable set is:
- caps with `scope = 'targets'` whose `targets` include the chosen rule;
- legacy fallbacks when `targets` is empty: `reward_rule_id` equals the rule id,
  or (`reward_rule_id` null and `category_id` equals the context category);
- all `scope = 'card'` caps (never for excluded spends);
- **plus every ancestor** via `parent_cap_id`, deduplicated.

`remaining(cap) = max(0, cap_amount − consumed_before[cap.id])`.

*Legacy cap rows* (`cap_kind` null) are converted:
- `spend_amount` → `eligible_spend` with `cap_amount = cap_value`;
- `txn_count` → `txn_count`;
- `reward_value` on a cashback rule → `total_cashback (₹)`;
- `reward_value` on a points rule → `total_points` with
  `cap_amount = cap_value / point_value_inr` (ignored if `point_value_inr` is 0).

*Order of application:*
1. **Eligible-spend caps.** `rule_spend = min(eligible, min remaining over them)`.
   `overflow = eligible − rule_spend` earns according to the binding cap's
   `post_cap_behavior`: `base_rate` (default) gives base accrual; `zero` gives
   nothing; `custom_rate` uses `post_cap_unit`/`post_cap_rate`. Each
   eligible-spend cap consumes `rule_spend`.
2. **Transaction-count caps.** If any has `remaining < 1`, the whole eligible
   spend is treated as overflow (as above). Otherwise each consumes 1.
3. Accrue on `rule_spend` (C3.5) → `base_accrual`, `bonus`; accrue the overflow
   → `overflow_accrual`.
4. **Bonus caps** (`bonus_points` for points accrual, `bonus_cashback` for
   cashback): `allowed_bonus = min(bonus, min remaining over them)`.
5. `earned = base_accrual + allowed_bonus + overflow_accrual`.
6. **Total caps** (`total_points` / `total_cashback`):
   `allowed_total = min(earned, min remaining over them)`. Excess earns nothing.
   `cut = earned − allowed_total` comes off the bonus first.
7. **Consumption deltas:**
   - bonus caps: `max(0, allowed_bonus − cut)`;
   - total caps: `allowed_total`;
   - eligible-spend caps: `rule_spend`;
   - count caps: 1 (or 0 if they forced overflow).
   Only non-zero deltas are reported.
8. **Result:** `points` (points cards), `cashback_inr` (cashback cards),
   `value_inr`, `rule_id`, `cap_deltas {cap_id: delta}`, `excluded`,
   `reasons[]`, `assumptions[]` (e.g. `"merchant_resolved_by_alias"`).

**C3.7 Milestone windows.** `milestone_rules.period` + `anchor`:
- `card_anniversary` uses the user card's `anniversary_on ?? opened_on`. If both
  are null, use the date the card was added and mark the result `approximate`.
- `calendar_year` and `fiscal_year` are calendar-based.
- `window_days` counts from the anchor date.

Qualifying spend excludes the card's `excluded_categories` and the milestone's
`excluded_category_ids`. Phase 1 changes only the window maths; the UI comes in
Phase 2.

### C4 — Shared scenario files

Directory `db/fixtures/reward_v2_scenarios/`. Both test suites load **every**
`*.json` file in it.

| File | Owner |
|---|---|
| `00_contract.json` | Lead only |
| `10_dart.json` | WP3 |
| `20_js.json` | WP4 |
| `30_integration.json` | WP7 |

Scenario shape:

```json
{ "name": "...", "why": "...",
  "card": { "...v2 wire card (C2)...": "..." },
  "ctx": { "amount": 2000, "category_id": null, "category_slug": null, "mcc": null,
           "merchant_name": "...", "merchant_vpa": null, "merchant_slug": null,
           "platform": "phonepe_app", "rail": "unknown", "occurred": "2026-11-10T10:00:00+05:30" },
  "cap_consumed_before": { "<cap id>": 0 },
  "expect": { "points": 200, "cashback_inr": null, "value_inr": 50.0, "rule_id": "...",
              "excluded": false, "cap_deltas": { "<cap id>": 180 } } }
```

A file may add a top-level `"directory": {"merchants": [...], "platforms": [...]}`.
Otherwise suites use `db/fixtures/merchant_directory.json`. Assertions: `points`,
`cashback_inr` and `value_inr` exactly (to 2 decimals); `rule_id`; `excluded`;
`cap_deltas` exactly (keys and values).

### C5 — Merchant and platform directory

File `db/fixtures/merchant_directory.json` (format below), seeded into C1 tables.

```json
{ "version": 1,
  "merchants": [ { "slug": "instamart", "name": "Swiggy Instamart", "parent_slug": "swiggy", "category_slug": "groceries",
                   "aliases": ["swiggy instamart", "instamart"], "vpa_prefixes": [], "mcc": [], "notes": "" } ],
  "platforms": [ { "slug": "hdfc_smartbuy", "name": "HDFC SmartBuy", "kind": "bank_portal", "issuer_slug": "hdfc",
                   "aliases": ["smartbuy"], "notes": "" } ] }
```

**Resolution algorithm** (identical in both engines):
1. `normalize(s)` = lowercase, then replace every non-alphanumeric run with one
   space, then trim.
2. A VPA match wins: the part before `@`, normalized, starts with a
   `vpa_prefix`.
3. Otherwise, an alias matches if the alias, normalized, appears in the
   normalized merchant name **on word boundaries**. The longest matching alias
   wins; ties go to the slug that sorts first.
4. Ancestors come from `parent_slug`, with a maximum depth of 5 and cycle-safe.

Slugs are lowercase `[a-z0-9_]`. A slug, once published, is never renamed; it
may be deactivated.

### C6 — Worked examples (issuer-verified)

Directory `db/fixtures/card_worked_examples/`, one file per card,
`<source_slug>.json`. `source_slug` is the CardPipeline checklist `source_slug`.

```json
{ "source_slug": "sbi-phonepe-select-black", "cardpipeline_id": "state-bank-of-india-...", "card_name": "...",
  "verified_on": "2026-11-05",
  "sources": [ { "url": "https://...", "doc": "MITC Jul 2026", "quote": "≤25 words" } ],
  "examples": [ { "id": "001", "title": "₹2,000 electricity bill in PhonePe app",
                  "ctx": { "...C3.1 fields...": "..." },
                  "state_before": { "caps_by_source_id": { "phonepe-other-monthly": 0 } },
                  "expect": { "currency": "points", "amount": 200, "value_inr": null, "excluded": false,
                              "cap_deltas_by_source_id": { "phonepe-other-monthly": 180 } },
                  "why": "10 pts/₹100 in-app; base 1 pt; bonus 180 counts to monthly bonus cap" } ],
  "research_notes": [ { "item": "cap phonepe-other-monthly", "cardpipeline_says": "...", "issuer_says": "...",
                        "proposed_fix": "override | importer | engine | none", "override_file": "api/scripts/catalogue_overrides/<slug>.json" } ] }
```

Each card needs at least 6 examples:
- base spend;
- each bonus rule;
- one exclusion;
- one cap boundary (partly consumed);
- one post-cap spend;
- one rounding case (points cards).

Caps are referenced by CardPipeline local ids, so examples don't depend on
database UUIDs.

### C7 — Loader v2 (CardPipeline → catalogue) mapping rules

1. **Split pure from database code.** Add
   `catalogue_v2/transform.js → transformCardRecordV2(record, {directory, overrides}) → {card, rewardRules, capRules, capTargets, milestones, feeWaivers, benefits, unlockRules, redemptionOptions, coverage}`,
   with no I/O. `import_card_pipeline.js` writes the result.
   Bump `import_transform_version`, so the publish gate requires re-review.
2. **Overrides first.** If `api/scripts/catalogue_overrides/<source_slug>.json`
   exists, apply it to the source record before the transform. Format:
   `{ "source_slug", "changes": [ { "path": "cap_rules[id=swiggy_cashback_cap].metric", "value": "...", "reason": "...", "source_url": "...", "checked_on": "YYYY-MM-DD" } ] }`.
   Path syntax: dotted keys, `[n]` index, `[id=x]` selector. Applied overrides
   are listed in the coverage report.
3. **Rule category token** (`reward_rules[].category_id` in the source), resolved in order:
   1. `CATEGORY_MAP` (existing, extended) → `category_id`.
   2. `MERCHANT_TOKEN_MAP` (e.g. `swiggy_app → [swiggy]`, `amazon_shopping → [amazon]`) → `merchant_slugs`.
   3. `PLATFORM_TOKEN_MAP` (e.g. `phonepe → [phonepe_app]`, `smartbuy → [hdfc_smartbuy]`) → `platform_slugs`.
   4. `all_retail` / `other` / `other_retail` → unrestricted.
   5. Composite tokens (`dining_movies`, `dining_grocery_departmental_movies`) →
      one rule per mapped part, with the same rate, and cap targets cloned to
      every part.
   6. Anything else → `rule_role = 'info'`, reported.
4. **Condition keys:**

   | Source keys | Becomes |
   |---|---|
   | `mcc`, `mcc_list`, `mcc_in`, `mccs` | `mcc_include` |
   | `merchant_pattern`, `merchant`, `merchant_names`, `eligible_merchants`, `merchant_platform` | Resolved through the directory → `merchant_slugs` |
   | `platform`, `app`, `channel` / `channel_type` naming an app or portal | `platform_slugs` |
   | `minimum_transaction_inr` | `min_txn_inr` |
   | `excluded_categories` | Excluded categories |
   | `channel_type ∈ {all, online_and_retail}` and similar | No restriction |
   | Any other restricting key (`birthday_window`, `selected_plan`, `booking_type`, `variant`, `transaction_type`, `app: not_X`, …) | Rule becomes `info` |

5. **Roles:**
   - source `exclusion` → `exclusion` (rate 0);
   - `standard_accrual` / `fallback` with no restriction → `base`;
   - `accelerator` / `standard_accrual` with restrictions → `earn`;
   - an `accelerator` with **no** restriction at all after mapping → `earn`, but
     flagged `unrestricted_accelerator` for review.
6. **Engine version.** `min_engine_version = 2` if the rule uses `platform_slugs`,
   `mcc_include` / `mcc_exclude`, more than one merchant slug, `block_inr`, or
   `rule_role = 'info'`.
   A single merchant slug stays v1-visible, with
   `merchant_pattern = <that merchant's shortest distinctive alias>`.
   MCC-only exclusions are v2-only. Category exclusions stay v1-visible at
   rate 0.
7. **Caps.**

   | Source `metric` | `cap_kind` |
   |---|---|
   | `bonus_reward_points` / `accelerated_reward_points` | `bonus_points` (or `bonus_cashback` if the targeted rule is cashback) |
   | `total_reward_points` | `total_points` / `total_cashback` by the targeted rule's currency |
   | `eligible_spend_amount` | `eligible_spend` |
   | `txn_count` | `txn_count` |
   | `waiver_amount*` | Skip (fuel waiver lives in `fuel_surcharge_rules`) |

   - `cap_amount` = `limit_value` (native) ?? `limit_value_inr`.
   - Targets come from every rule whose `action.cap_reference` names the cap,
     plus `target_rule_ids`.
   - No targets and a total metric → `scope = 'card'`.
   - `parent_cap_id` comes from `parent_cap_id`.
   - Post-limit: `downgrade_to_base_rate` / `earn_base_rate` → `base_rate`;
     `zero_accrual` → `zero` (meaningful only for eligible-spend/count caps;
     bonus and total kinds already encode it).
   - Period: `day` caps → kept, but `min_engine_version 2` and marked
     `unenforced_period` (no daily period in Phase 1); `calendar_year` →
     `annual` + anchor `calendar_year`.
   - **v1 projection** (for `GET /catalogue`):
     - bonus kinds → `measure = reward_value`,
       `cap_value = cap_amount × point_value` (₹ for cashback),
       `post_cap_rate = NULL` (base continues);
     - total kinds → `reward_value`, `post_cap_rate = 0`;
     - `eligible_spend` → `spend_amount`, with `post_cap_rate` NULL for
       `base_rate`, or 0 for `zero`;
     - `reward_rule_id` = the single target if there is exactly one, else
       NULL **and** `min_engine_version = 2`.
   - **Sanity flags** (reported, not fixed):
     - `suspect_cap_unit`: an `eligible_spend` cap ≤ ₹5,000 on a rule with ≥ 5%
       cashback;
     - `missing_cap_value`;
     - `orphan_cap`: no targets, no category, not card-wide.
8. **Milestones.**
   - `card_anniversary_year` → `annual` / `card_anniversary`;
   - `calendar_year` → `annual` / `calendar_year`;
   - `fiscal_year` → `annual` / `fiscal_year`;
   - `quarter` / `calendar_quarter` → `quarter` / `calendar_year`;
   - `calendar_month` → `calendar_month` / `calendar_year`;
   - `statement_cycle` → `statement_cycle` / `statement_cycle`.
   Fix the existing bug where both branches return `card_anniversary`.
   Welcome-type milestones ("within 90 days") → `window_days`. Fill
   `reward_points` / `reward_kind` where the source gives them.
9. **Unlock rules.** Normalize
   `lifestyle_and_network_benefits[].evaluation_engine.conditions` keys
   (`spend_threshold_inr`, `minimum_spend_inr`, `previous_quarter_spend_inr`,
   `eligible_spend_milestones_inr[]`, `spend_period`, `unlock_period`,
   `access_period`, …) into `benefit_unlock_rules` rows: one per threshold, linked
   to the benefit. Tiered benefits (Atlas Silver/Gold/Platinum) → `kind = 'tier'`
   rows with `tier_label`. A benefit that mentions spend but can't be parsed gets
   the `unparsed_unlock` flag.
10. **Card fields and coverage.**
    - `accrual_block_inr`, `accrual_rounding` (`N/A` → null; `floor_to_nearest_paisa`
      → `none`; `nearest_integer` → `round`), and `points_expiry_months` come from
      the source.
    - `model_coverage` =
      `{rules_total, rules_modelled, rules_info, caps_total, caps_enforced, flags: [{code, source_local_id, detail}], overrides_applied: [...]}`.
    - `model_status`:
      - `basic` if there is no earning rule beyond base;
      - `partial` if any `info` rule, unenforced cap, or unresolved flag exists;
      - otherwise `partial` until WP7 marks it `verified`, after its worked
        examples pass. Verified slugs are listed in
        `api/scripts/catalogue_overrides/verified_cards.json`.
11. **Reports.** The loader writes `api/scripts/.staging/coverage-report.json` and
    `.md`. These hold per-card coverage plus catalogue-wide metrics: unmapped
    tokens by frequency, info rules, unrestricted accelerators, orphan caps,
    suspect units, and milestone anchors. `api/scripts/audit_catalogue.js` takes
    any catalogue JSON (v1 or v2 feed) and prints the R1–R9 metrics from the
    feature spec, for before/after comparison.

### C8 — Contract changes after wave 1 started (these win over the text above)

| # | Date | Change | Affects |
|---|---|---|---|
| D1 | 2026-11-05 | The existing semantic-identity unique indexes are recreated with the v2 columns, so two v2 rules or caps that differ only in v2 fields don't collide. **`uq_reward_rules_semantic_identity`** adds `rule_role`, `merchant_slugs`, `platform_slugs`, `mcc_include`, `mcc_exclude`, `block_inr`, `min_engine_version`. **`uq_cap_rules_semantic_identity`** and **`uq_cap_rules_label_identity_v1`** add `cap_kind`, `cap_amount`, `scope`, `parent_cap_id`, `post_cap_behavior`, `anchor`, `min_engine_version`. **`uq_milestone_rules_semantic_identity`** adds `reward_points`, `reward_kind`, `window_days`, `excluded_category_ids`. `source_local_id` is **not** part of identity. `api/src/catalogue_label_identity.js` `RULE_KEYS.cap_rules` mirrors its index and changes with it (plus its test). The Dart identity keys (`rewardRuleIdentityKey`, `capRuleIdentityKey`, `milestoneRuleIdentityKey`) must include the same v2 fields, so the app's de-duplication never merges two different v2 rules. | WP1, WP3 |
| D2 | 2026-11-05 | The v1 view also hides a cap whose `reward_rule_id` points at a rule hidden from v1 (`min_engine_version = 2` or `rule_role = 'info'`), and any cap with a `cap_rule_targets` row pointing at such a rule. This is defence in depth; the loader also does it (D3). | WP1 |
| D3 | 2026-11-05 | C7.7 addition: a cap gets `min_engine_version = 2` if **any** of its targets is v2-only. | WP2 |
| D4 | 2026-11-05 | `payment_platforms.issuer_slug` uses the app's issuer seed slugs (`hdfc`, `sbi`, `axis`, `icici`, `kotak`, `idfc`, `indusind`, `scb`, `rbl`, `amex`, `yes`, …) and is **not** a foreign key (some issuers, e.g. HSBC, aren't seeded). The C5 example's `"hdfc-bank"` should read `"hdfc"`. | WP1, WP5 |
| D5 | 2026-11-05 | WP1's addition to `api/src/portable_backup/coverage.json` (four `global_catalog` entries for the new tables) is accepted as part of WP1. | WP1 |
| D6 | 2026-11-05 | **`parent_slug` means "the same merchant for reward purposes"**, because a rule on the parent also pays on the child (C3.3 step 5). Use it only for true sub-brands that card terms treat as the parent (e.g. Swiggy → Instamart, Dineout, Genie; Air India → Vistara). Corporate-group siblings that are separate brands (Myntra/Cleartrip under Flipkart; BigBasket/Croma/Tata CLiQ under Tata; Blinkit/District under Zomato; Goibibo under MakeMyTrip; Titan brands; Reliance and Landmark store brands) get **no** `parent_slug`. Instead they get an optional JSON field **`group`** (e.g. `"tata"`, `"flipkart"`, `"zomato"`, `"titan"`, `"reliance"`, `"landmark"`, `"ihcl"`). `group` is informational. Engines ignore it, and the seeder ignores it (no DB column in Phase 1). The loader (WP2) uses it to expand group-wide card terms (e.g. "Tata Neu partner brands") into an explicit `merchant_slugs` list. | WP5, WP2, WP1 (seeder must tolerate the key) |
| D7 | 2026-11-06 | **Two more rounding modes** for `card_products.accrual_rounding`, because some issuers round the final points, not per block (Tata Neu: ₹7,500 × 1.5% = 112.5 → 113). Allowed values are now `floor`, `round`, `none`, `points_half_up`, `points_floor`. `floor`, `round` and `none` keep the C3.5 meaning (applied to blocks). `points_half_up` is `round_half_up(eligible × rate / block)`, `points_floor` is `floor(eligible × rate / block)`, both on the whole-transaction product. Base accrual uses the same mode. Contract scenarios T1–T3 cover them. | WP1 (check constraint), WP2, WP3, WP4 |
| D8 | 2026-11-06 | **Loader and data rules from issuer research:** (a) when an issuer pays whole points or CashPoints per block (e.g. Millennia: 1 CashPoint = ₹1, per ₹100), model the rule as a points unit with the block and `point_value_inr`, never as `cashback_percent` (which pays to the paisa). (b) A portal or programme with different multipliers per travel type (HDFC SmartBuy: hotels 10X, flights 5X, trains 3X) becomes one rule per type, using `platform_slugs` plus `mcc_include` (hotels 7011 and 3501–3999, airlines 3000–3299 and 4511, rail 4112), never one "up to" rule. (c) Worked examples and overrides use only the app's category slugs (groceries, fuel, dining, online, travel, bills, rent, insurance, education, government, wallet, entertainment, health, emi, other); general offline retail is `other`. (d) Caps whose tier depends on card age (e.g. IndianOil HDFC fuel cap 250 for the first 6 months, then 150) use the steady-state value in Phase 1 and are flagged `tier_by_card_age` in coverage. | WP2, WP6a, WP6b, WP7 |
| D9 | 2026-11-06 | **Engine rulings** (from WP4's judgement calls; binding on both engines). (1) A `base`-role rule earns at its own unit/rate with bonus 0; the card's `base_reward_*` is the implicit base and the "base" in bonus maths. (2) A v2 rule with a legacy `merchant_pattern` and empty `merchant_slugs` keeps the v1 substring restriction (never widen); `merchant_pattern` is ignored when `merchant_slugs` is set. (3) `post_cap_behavior` null is derived from `post_cap_rate`: null → `base_rate`, 0 → `zero`, other → `custom_rate`. (4) `card.accrual_block_inr` is informational. Blocks come from `rule.block_inr ?? unitBlock(unit)`, and the implicit base always uses `unitBlock`. When a card's block differs from its unit's block, the loader must emit an explicit `base`-role rule carrying `block_inr`. (5) Rule spend, cap overflow and spend above `max_txn_inr` are accrued and rounded separately. Above-max accrual counts toward total caps, not toward eligible-spend caps. (6) Flat points earn `rate` once when rule spend > 0, with bonus = rate − base accrual. (7) A cap applies only to accrual in its own currency. `points` is non-null when any points accrual exists, and `cashback_inr` likewise. (8) Ties between equally binding eligible-spend caps go to the first in catalogue order. If a count cap forces overflow, every count-cap delta is 0. Count caps take 1 even when an eligible-spend cap is exhausted. (9) Legacy category-matched caps also apply to the implicit base rule. An unknown `cap_kind`/`scope`, a null `cap_amount`, or a points-value legacy cap on a card with point value 0 is skipped (with a reason), never guessed. (10) For VPA matches, the longest prefix wins, with ties to the slug that sorts first. Inactive merchants are never resolved but still count as ancestors. | WP3, WP4 |
| D10 | 2026-11-06 | **The v1/v2 switch (C3.2) must not key on columns that have database defaults.** After migration, every existing rule has `rule_role = 'earn'` and empty arrays. A card is **v2-shaped** iff any of the following hold: `accrual_rounding` is non-null; any cap has a non-null `cap_kind`; any rule has `rule_role` in (`base`,`exclusion`,`info`), a non-empty `merchant_slugs`/`platform_slugs`/`mcc_include`/`mcc_exclude`, a non-null `block_inr`, or `min_engine_version` = 2. Otherwise the card is v1-shaped and uses the v1 path. **The loader (WP2) always sets `accrual_rounding`** on every card it writes: the source value; else `floor` for points cards and `none` for cashback-only cards, with a coverage flag `rounding_assumed`. So every v2-loaded card is v2-shaped, and cards not yet re-imported keep today's behaviour. A scenario may carry an optional `"assert"` list; when present, harnesses compare only those keys. Contract scenario **L1** pins this. | WP2, WP3, WP4, WP8 |
| D11 | 2026-11-06 | **Cashback rounding.** Some issuers pay whole rupees per transaction (SBI Cashback: ₹149.95 → ₹149). New column `card_products.cashback_rounding text null`, check in (`paise`,`rupee_floor`,`rupee_half_up`); null means `paise`. It is exported in the v2 and admin views alongside `accrual_rounding`. Engines apply it to every cashback accrual piece (rule spend, overflow, above-max) before caps. `accrual_rounding` keeps governing points only. A non-null `cashback_rounding` also makes a card v2-shaped (adds to D10). The loader sets it from source or overrides; it is null when the source is silent. Contract scenario **C4** pins it. | WP1, WP2, WP3, WP4 |
| D12 | 2026-11-06 | **Engine rulings from the WP4 review.** (a) **A rule paying less than the base earns its own rate.** For same-currency earn rules, `base_part = min(rule_accrual, base_accrual)` and `bonus = rule_accrual − base_part`, so pre-cap earning equals the rule's accrual (e.g. 1 pt/₹100 on utilities on a 2 pt/₹100 card gives 10 points on ₹1,000, not 20). Contract scenario **D12** pins it. (b) `custom_rate` overflow uses `post_cap_unit` when set; otherwise it uses the rule's unit **and** the rule's `block_inr`. (c) The C3.4 priority tie-break compares each tied rule's pre-cap ₹ value for this transaction, not its nominal rate, so flat-point rules compare fairly. A remaining tie goes to the rule id that sorts first. "Pre-cap ₹ value" means the rule's own accrual on its eligible spend (`min(amount, max_txn_inr)`), plus the base accrual on any spend above `max_txn_inr`, valued at `point_value_inr` for points. No caps are applied. An unknown cap `anchor` is read as null; the cap is not dropped. (d) An unknown `post_cap_behavior`, `cap_kind` or `scope`, or a null `cap_amount`, means the cap is skipped and the engine adds `cap_skipped:<cap_id>:<reason>` to `reasons`. Never guess. (e) Harnesses round the actual money to 2 dp (half-up) and compare exactly. (f) `points` is non-null (0 if nothing earned) whenever the card's base unit is a points unit or any points accrual exists. `cashback_inr` is non-null (0.0) whenever the base unit is cashback or any cashback accrual exists. An accrual "exists" when any spend piece is accrued in that currency, even if it rounds to 0. | WP3, WP4 |
| D13 | 2026-11-06 | **Terms that depend on the cardholder are deferred to Phase 2, never guessed.** (a) A cap whose amount depends on the user (a % of credit limit, credit limit + X, a tier) keeps its `cap_kind` with `cap_amount` null and coverage flag `cap_depends_on_user`; engines skip it (D12d). (b) A rule that depends on a user attribute (member tier, paid membership such as Kiwi Neon, Prime) becomes `info` with flag `depends_on_user_attribute`. The exception is when the issuer states an unambiguous default/entry-tier rate; then it's an `earn` rule at that rate, with the same flag. (c) Booking-type differences on one merchant (MakeMyTrip flights vs hotels) are split using `mcc_include`, as in D8b. (d) **Override conventions** (C7.2): whole-array replacement (`reward_rules`, `cap_rules`) and `null` values are allowed, and so is setting `rule_role` directly. The source period `statement_cycle_quarter` maps to `quarter` with flag `period_approximated`. The D11 override path is `accrual_engine.cashback_rounding`. | WP2, WP6a, WP6b, WP7 |
| D25 | 2026-11-06 | **Rulings from the WP7 fix-round review.** (a) **Rounding tolerance on issuer examples.** Where an issuer rounds each component separately (base and bonus) and the engines round the rule's accrual once (C3.5), the two can differ by 1 point (Tata Neu Infinity HDFC: issuer 1,056, engines 1,055). Do not add component-wise rounding now. An example may carry `tolerance_points` (at most 1) with a `tolerance_note` citing the issuer's own arithmetic. Both harnesses accept only an engine value in `[expected − tolerance, expected]`: the engine may under-state, never over-state. (b) **Rail-scoped reductions and carve-outs apply only on a known rail** (C3.3 step 9). A spend with no rail at a Tata partner brand earns the partner rate. This is accepted: most card-SMS spends are card-rail, and inferring UPI/EMI from the SMS text is a Phase 3 item (later-phases doc). It is not a D24b case, because the partner rate is not itself a UPI rule. (c) **IndiGo Kotak stays Verified.** The D24a fix landed in the same round and `blocking_flags` is empty. (d) **D24d applies to every card WP7 touches.** Restate each issuer exclusion that an MCC list or category can carry (UNO/Ultimo gift cards, investments, card bill payment, charges; Tata Neu rent, government, cash advance), and keep the rest as `info` with a D13 flag. Report any such gaps on cards WP7 did not touch as a list for Phase 2; do not widen this round. (e) **EMI at a Tata Neu SBI partner merchant earns nothing.** SBI T&C 11.4(a) and 11.6(e) exclude Flexipay and forfeit NeuCoins on EMI conversion, so use the same rail-EMI all-retail exclusion as Millennia. An EMI rate carried over from the HDFC card is a copy error, not a finding. (f) **Accepted trade-off:** with `except_merchant_slugs` (D16c), the Flipkart Axis 5% rule is v2-only, so installed apps no longer show 5% at Flipkart for that card until they update. That is conservative (H2). Record it in the rollout notes (§9). (g) **A newly loaded above-base rule must carry the issuer's per-brand or per-category fair-usage limits** (D24c). Where the schema can't target a cap to one merchant, use the conservative reading (a cap that can only under-state) and flag it. | WP7 |
| D24 | 2026-11-06 | **Integration rulings from the WP7 review.** (a) **A card's value counts only rewards issued because of the card.** That means the bank's points and cashback, or a co-brand partner's card-linked earn. It excludes loyalty points the merchant's own programme gives every member whatever the payment method (e.g. IndiGo BluChips' base 8 + channel 4 of the "15 per ₹100"; only the card's 3 count). Ranking must compare cards on what choosing that card adds. Fix indigo-kotak (and its example 004 with a cited note), and un-verify it until fixed. (b) **UPI-rail earn rules are v2-only** (`rail: upi_qr`, above base). In v1 an unknown rail matches, and most SMS spends have no rail, so v1 would pay the UPI rate on almost everything. Pre-existing `online`-rail rules stay v1-visible: that is accepted legacy behaviour. (c) **Silence in a newer document doesn't remove an issuer-documented limit or exclusion.** Remove one only when an issuer document says it changed. (d) Restated or loaded rules must carry every exclusion the issuer lists for that card. When a rule set loses an exclusion, the override restates it. (e) Known failures that data can fix (EMI rail exclusions, Tata Neu partner brands, SimplyCLICK cap representation) are fixed in WP7, not deferred. (f) When a directory merchant lists several MCCs, a caller filling `ctx.mcc` uses the first in the list (deterministic). WP5/WP7 order the list most-specific first. | WP7, WP9 |
| D23 | 2026-11-06 | **Server-state rulings from the WP8 review.** (a) **Accepted scope deviation:** v2 cards are rebuilt in native units inside `reconcileCurrentCapStates`. Without this, every `GET /user-cards` would overwrite native rows in v1 measure. (b) **Statement cycles in v2** use their own correct bounds function, leaving v1's unchanged (D10). A statement day beyond the month's length clamps to the month's last day. A period runs from the day after the previous statement date to the statement date inclusive, with no overlap and no gaps, including statement day 1 and 29–31. (c) **v2 windows use Indian Standard Time (Asia/Kolkata) calendar dates**, for all period kinds: month, quarter, year, statement cycle, card year and window_days. Indian issuers bill in IST, so a spend at 03:00 IST on 1 Dec belongs to December. v1 keeps its current behaviour. (d) **Lock order:** routes that change a transaction (PATCH `/transactions/:id`, POST ignore/restore, delete) take the user's `transaction-ingest:<user>` advisory lock **before** the row lock, as inserts already do. So a rebuild (reconcile/recompute) can't interleave with an edit. (e) Server state queries also filter by `profile_id` (defence in depth, including the admin recompute). (f) Lifetime caps rebuild only from the card's `opened_on` (or first transaction), not from 1970. | WP8 |
| D22 | 2026-11-06 | **Server-recording rulings from WP8.** (a) **Milestone and fee-waiver qualifying spend excludes every spend whose reward result is `excluded`.** That covers card-level excluded categories, the milestone's own `excluded_category_ids`, and full exclusion rules, including D16b minimum-amount exclusions. This is conservative, since progress is never over-stated. A milestone's own terms can widen it later through an override. (b) **Welcome milestones** (`window_days`) anchor on `opened_on ?? anniversary_on ?? created_at` (the issue date first); flag approximate when `created_at` is used. Card-year milestones keep `anniversary_on ?? opened_on ?? created_at`. (c) **Old installs keep the v1 meaning of `consumed`.** `GET /user-cards` returns `consumed` in each cap row's v1 measure, as before: for points kinds, native consumed × `point_value_inr` (₹ reward value); for ₹, spend and count kinds, unchanged. It adds `consumed_native`, `cap_kind`, `cap_amount`, period bounds and `approximate_window` for v2 clients. Storage stays native. WP9 reads `consumed_native` only. (d) **Deterministic rule and cap order.** `v_card_catalogue_export_v2` aggregates `reward_rules` ordered by `priority, source_local_id nulls last, id` and `cap_rules` by `source_local_id nulls last, id`. The server reads them in the same order. This is the "catalogue order" for D9(8) tie-breaks. (e) **Platform is never known server-side** (C3.1: callers supply it). Platform-only bonuses are not credited on SMS-recorded spends, which is conservative. Inferring the platform in the SMS layer is a Phase 2/3 item. (f) Accepted: a statement-cycle window with no statement day is flagged approximate. | WP8, WP1, WP9 |
| D21 | 2026-11-06 | **Round-4 confirmations and one v1 gap.** (a) **Confirmed:** reduced-rate rules and carve-outs with an exact category plus an explicit MCC list also get a v2 MCC-only row (a known MCC in the list decides, as in D20a). A condition list naming both merchants and apps ("CRED, Cheq, MobiKwik") is a set of alternatives for exclusions, carve-outs and reduced rates: one merchant row and one app row. Earn rules keep the narrower AND reading. (b) **A carve-out at or below base whose scope v1 can't express** (MCC- or multi-merchant-scoped) hides every accelerator it carves out of from v1 (`min_engine_version` 2). This is conservative: v1 pays the base rate rather than the accelerator where the bank pays only the base. Report the count. | WP2 |
| D20 | 2026-11-06 | **Loader rulings from the WP2 round-3 re-review.** (a) **Three rows for an exclusion with an explicit MCC list:** a v1-only category row; a v2 category + MCC row (the category stands in when the MCC is unknown); and a **v2 MCC-only row** (category null), so a known MCC in the list excludes whatever the category label says. This completes D19c ("the MCC list decides whenever the MCC is known"). (b) **An "exclusion" whose action states a positive earn rate is a reduced-rate earn rule**, not an exclusion and not `info`. Examples: "standard 1X here", "base 1 RP", "earns at the regular rate". It applies at that rate on the excluded scope, at a priority number lower than the accelerator it carves out of, and follows the D18c reduced-rate projection. This replaces `bonus_only_exclusion` wherever a rate is stated (fixes BoM wholesale over-paying 5×, and makes IndusInd Tiger's utility/government/insurance/education/rent consistent). `bonus_only_exclusion` remains for accelerated-only text with no stated rate. (c) **The bonus-only classifier only looks at the excluding clause.** Qualifiers in clauses like "… remains eligible for 5X" are ignored, so bobcard-icai-exclusive fast-food (0 points) is a full exclusion. If the excluding clause has no reward word or qualifier, the exclusion is full. (d) **Source MCCs that are not 4 digits** (e.g. 32, 66, 2541 lists, 4001 in RBL TVS/Maxima) are flagged `malformed_mcc` and dropped from `mcc_include` (a non-4-digit code can't match a real MCC). An exclusion left with no valid MCCs falls back to its category rows. (e) The coverage report lists every source whose classification changed since the previous run, so demotions are always disclosed. | WP2 |
| D19 | 2026-11-06 | **Loader rulings from the WP2 round-2 re-review.** (a) **`bonus_only_exclusion` only when every excluded benefit is qualified as accelerated, bonus or milestone.** The exclusion is full if the text also excludes core/base points or plain "reward points": "excluded from core and accelerated Reward Points", "not eligible for reward points", "earn 0 Reward Points", "excluded from Reward Points and milestone benefits". Add a negative test for each phrasing found in the 41 cases. (b) **Card-level `excluded_categories` holds only exact-category exclusions.** An exclusion derived from a narrow token (gaming or movies → entertainment; railways or tolls → travel) is emitted as exclusion rules, using the D18b pattern: a v1-only broad row plus a v2 precise MCC row. It never goes into the card-level list, which v2 can't ignore (fixes the Landmark SBI movie bonuses). (c) **When a source exclusion gives an explicit MCC list, the MCC list decides whenever the MCC is known.** *Amended after implementation:* the v2 row keeps its category as well as the MCC list. By C3.3 step 7 the MCC list decides when the MCC is known, and the category stands in when it isn't (most SMS carry no MCC). The category-only row is v1-only. MCC-only v2 rows would have stopped 769 exact-category exclusions on 213 cards from applying whenever the MCC is unknown. This still fixes flipkart-sbi railways zeroing Cleartrip 5% at MCC 4722, aditya-birla utility and ujjivan grocery when the MCC is known. **Accepted trade-off (D18b):** narrow-token exclusions (e.g. fast food within dining) are MCC-only in v2. Otherwise an unknown MCC would zero the whole category's bonus. So an unknown-MCC spend can't prove a narrow exclusion. To narrow this gap, WP9's context builder fills `ctx.mcc` from the merchant directory when the SMS lacks it. (d) **Cap targets follow the source rule, not the category label.** A cap targets every emitted row of its source rule: v2 MCC rows and v1-only projections. Its `min_engine_version` follows D3 (fixes the CSK ICICI transportation cap). (e) A **v1-visible above-base earn rule whose governing cap is not v1-visible is hidden from v1** (`min_engine_version` 2; conservative, since v1 would otherwise pay above the cap). (f) **Caps on benefit categories** (lounge, golf, concierge, insurance cover, movie ticket counts) are `non_earning_cap_skipped` (D18g refined; fixes KrisFlyer Priority Pass caps). (g) A v1-only reduced-rate projection may outrank a v1 accelerator in the same category (e.g. idfc-first-select railway 1X vs 10X travel). That is accepted as conservative under H2; no change. (h) *Optional:* use an MCC→app-category table to project multi-category MCC-list reduced rates into one v1-only row per category (YES Bank `select_categories`). | WP2 |
| D18 | 2026-11-06 | **Rows only the v1 feed uses, plus loader rulings from the WP2 re-review.** (a) **New column** `reward_rules.max_engine_version int null` (null = no maximum). A row with `max_engine_version = 1` is **v1-only**: the v1 feed shows it (subject to the existing v1 filters), and **v2 engines ignore it entirely**. A non-null `max_engine_version` makes a card v2-shaped (extends D10). (b) **The D17b broad-category exclusion projection rows are v1-only.** v1 stays conservative, excluding the broad category. v2 uses only the precise MCC/merchant rows, so a fast-food exclusion no longer zeroes all dining in v2 (e.g. Axis Horizon travel EDGE 5X, BOBCARD dining/travel 10X, SBI co-brand movie bonuses). (c) **Reduced-rate rules** (same currency, rate below the card's base) are the inverse case: broad is conservative. When D17a/D17f narrow such a rule to MCCs, the loader **also** emits a v1-only broad-category row at the reduced rate. With no MCC mapping, the reduced-rate rule stays an earn rule with the broad category in both feeds. D17a/D17f narrowing applies to above-base rules as written. (d) A composite or synonym restatement whose mapped parts are all the rule's own category is a restatement, not "unknown" (fixes the IndusInd Iconia/Pioneer/Crest/Platinum RuPay and ixigo AU reduced-rate rows). (e) **"Other than X" / "except X" on an exclusion is an exception (D16a), never extra scope** (e.g. idfc-first-lic-select non-LIC insurance). An exclusion that only removes an accelerated rate ("does not qualify for the accelerated 5%") is not a full exclusion: it becomes `info` with flag `bonus_only_exclusion`. (f) Narrow tokens inside combined (and-ed) restrictions keep their MCC pinning. (g) Non-earning cap detection uses cap id and label only, never description. A brand-name exception is taken from prose only for keys that explicitly denote exceptions. D17c brand detection uses directory alias matching, not letter case. (h) A rule whose platform is also in its own except list is self-contradictory: `info` with flag `self_contradictory_rule`. (i) A narrow token on a rule that already has `merchant_slugs` adds no `mcc_include` (aggregators book under their own MCC, e.g. 4722). If the source gives different rates by booking type on that merchant, those rules are `info` (D14b), unless the merchant itself is a hotel or airline. (j) **Flags that block `verified`** (D17j refined): any `info` earn rule other than D13/D14 deferrals, `orphan_cap`, `missing_cap_value`, `suspect_cap_unit`, `unrestricted_accelerator`, `post_limit_conflict`, `dangling_cap_reference`, `override_removed_exclusion`, `self_contradictory_rule`. Everything else is informational, e.g. `tier_by_card_age`, `period_approximated`, `broad_category` on v1-only rows, `exclusion_scope_broadened`, `brand_from_identification_text`, `rounding_assumed`, `narrow_token_to_mcc`, `bonus_only_exclusion`. Contract scenarios **M1–M4** pin (a)–(c). | WP1, WP2, WP3, WP4, WP7 |
| D17 | 2026-11-06 | **Loader rulings from the WP2 review** (all to restore H2, "never widen"). (a) **Narrow tokens on earn rules** (e.g. `pharmacy`, `movie`, `travel_hotels`, `travel_flights`) never widen to the broad app category. They get `mcc_include` from a token→MCC table (hotels 7011 and 3501–3999, airlines 3000–3299 and 4511, rail 4112, movies 7832, pharmacy 5912, …) and become v2-only. With no MCC mapping, the rule is `info`. Exclusions may keep the broad category, since that excludes more. (b) **An exclusion with a broad token plus MCCs keeps its v1-visible category row** as well as the v2 MCC row (C7.6 / question 1); dropping the category row widens v1. (c) **Text like "identified by MID/TID"** is skipped only when it names no brand. Otherwise the brand is resolved (containment allowed), or the rule becomes `info`. (d) **Exclusion lists on an exclusion rule are its own scope:** the source's `excluded_categories` / `excluded_merchants` expand the exclusion (extra exclusion rows), never become `except_*` lists. (e) **The "mentions a platform" fallback** is used only when the clause has no other restricting content; otherwise the rule becomes `info`. (f) An unknown restated category on a rule that already has a token category becomes `info` or an MCC split, never silently dropped. (g) **Cap target inference** applies only to earning metrics. Caps whose id or label indicates transfer, fee, surcharge, waiver, threshold or charge are `non_earning_cap_skipped`. (h) `override_removed_exclusion` compares exclusion ids before and after **any** override (remove, null set, role or evaluation-type change), not only whole-array sets. (i) The override fingerprint includes change values, so a value-only edit forces a rebuild. (j) A card is `verified` only if its examples pass and every remaining flag is a D13/D14 deferral (`cap_depends_on_user`, `depends_on_user_attribute`, `depends_on_txn_attribute`). Otherwise it is `partial`. (k) `nearest_integer` → `points_half_up` per D7 (C7.10's `round` is superseded). (l) **Welcome milestones** (`window_days` non-null) are hidden from the v1 view. | WP2, WP1, WP7 |
| D16 | 2026-11-06 | **Exclusions with exceptions, and minimum amounts** (a common Indian-card pattern). (a) New `reward_rules` columns `except_merchant_slugs text[] not null default '{}'` and `except_platform_slugs text[] not null default '{}'`. A rule does not apply when the resolved merchant (or any ancestor) is in `except_merchant_slugs`, or `ctx.platform` is in `except_platform_slugs`. **An exception takes effect only when the merchant/platform is known and listed**: an unknown merchant or platform never proves an exception, so an excluded spend stays excluded. Examples: "no rewards on fuel except at IndianOil" (exclusion, category fuel, `except_merchant_slugs ['indianoil']`, plus an IndianOil earn rule); "utilities excluded unless paid via Google Pay" (exclusion, category bills, `except_platform_slugs ['google_pay']`, plus a Google Pay earn rule). (b) On an **exclusion** rule, `max_txn_inr` means "the exclusion applies only when amount < max_txn_inr", e.g. "no rewards below ₹100". (c) **Engine version and v1 projection:** non-empty except lists, and an exclusion with `max_txn_inr`, make a card v2-shaped (extends D10). An **exclusion** with except lists stays v1-visible: v1 ignores the lists, so it excludes more widely, which is conservative. An **earn** rule with except lists, and an exclusion with `max_txn_inr` (which v1 would read as excluding everything), get `min_engine_version = 2`. (d) The loader maps source "not via X", "other than X" and "except at X" conditions to these fields, and minimum-transaction-for-rewards terms to a `max_txn_inr` exclusion. Contract scenarios **X1–X2, Y1–Y4** pin it. | WP1, WP2, WP3, WP4, WP6b, WP7 |
| D15 | 2026-11-06 | **Robustness rulings from the WP3 review** (binding on both engines). (a) **No parse-time de-duplication on v2-shaped cards.** The database identity indexes (D1) already guarantee uniqueness, and merging rows can orphan a cap's `targets` or `parent_cap_id`, which would widen. The v1 path keeps today's de-duplication. (b) **An unknown `cashback_rounding` value** still marks the card v2 and falls back to `rupee_floor` (the mode that never over-states). An unknown `accrual_rounding` falls back to `floor`. (c) **The tie-break (D12c) compares values rounded to integer paise**, so decimal-equal values tie and fall through to the rule id. (d) **Skipped rules are visible.** A rule skipped because a field is unparseable or has an unknown value adds `rule_skipped:<id>:<reason>` to `reasons`. If the skipped rule was an exclusion (raw `rule_role = 'exclusion'`), the result also carries the assumption `exclusion_unparsed`, so the UI can mark the estimate low-confidence. The loader validates enum domains, so this is defence in depth. (e) Non-string elements in `mcc_include` / `mcc_exclude` make the rule unparseable (skipped per (d)); they are never coerced, which could drop leading zeros. (f) **Ship gate:** the app's v2 ranking must not use server cap headroom for points-kind caps until WP8 writes native-unit `cap_states`. WP9 and Checkpoint B enforce this. (g) For the D10 switch, any non-null `rule_role` outside (`base`,`earn`,`exclusion`,`info`) also makes a card v2-shaped, and so does any non-null, non-array value in a v2 list field. The v2 path then skips that rule visibly (d) instead of the v1 path applying it as an earn rule. | WP3, WP4, WP8, WP9 |
| D14 | 2026-11-06 | **Facts outside the transaction context, and safe overrides.** (a) A C6 worked example that depends on a fact the C3.1 context can't carry gets `"engine_checkable": false` plus `"not_checkable_reason"`. Such facts include a gift-card purchase on a normal merchant, an international/foreign-currency spend, a birthday window, member tier or booking type when there's no MCC. WP7 skips these for engine checks but keeps them as documentation. (b) A rule restricted to such an attribute becomes `info` with the coverage flag `depends_on_txn_attribute`. Phase 2 adds `is_international` from the existing foreign-payment detection. (c) A whole-array override (`reward_rules` / `cap_rules`) must restate every source rule it keeps, **including exclusions**. The loader reports `override_removed_exclusion` when an override drops a source exclusion, and `dangling_cap_reference` when a rule's `cap_reference` names a cap that no longer exists. (d) Override authors set priorities so a narrower rule wins (e.g. 1X railway at a lower priority number than 10X travel). Use `mcc_include` / `mcc_exclude` rather than relying on broad category tokens, and only use tokens the loader maps (`api/scripts/catalogue_v2/category_tokens.js`). | WP2, WP6b, WP7 |

## 5. Work packages

File ownership is exclusive. A work package edits only its own files. A file
not listed below needs the lead's approval.

### Wave 1 (parallel; depends only on the contracts above)

| WP | Title | Owns | Done when |
|---|---|---|---|
| **WP1** | Schema, feeds and directory seeding | `db/supabase/migrations/20261105120000_card_rules_v2.sql`; `db/tests/20261105120000_card_rules_v2_test.sql`; `api/src/catalogue_route.js` (new); the `/catalogue` handler lines in `api/src/index.js` (replace with module registration only); `api/scripts/seed_merchant_directory.js`; `api/test/catalogue_route.test.js` | Migration applies on a fresh Postgres after all existing migrations. The DB test proves: v1 view hides `min_engine_version=2` / `info` rows; v2 view returns targets, unlock rules and redemption options; RLS for the new tables; data_version bumps. Route tests cover v1 unchanged and v2 shape. The seed script is idempotent. |
| **WP2** | Loader v2 and audit | `api/scripts/import_card_pipeline.js`; `api/scripts/catalogue_v2/**` (new); `api/scripts/catalogue_overrides/README.md` + the loader for that folder (not the per-card files); `api/scripts/audit_catalogue.js`; `api/test/catalogue_v2_*.test.js`; `api/test/fixtures/cardpipeline/*.json` (copies of 5–8 real CardPipeline records) | Unit tests on the pure transform for real records: a co-brand card, an app-platform card, a brand-portal card, an app-bonus card with an unknown cap, a premium card with many caps, a tiered-lounge card, and a cashback card. Every C7 rule has a test. Running the transform over the full local CardPipeline set (dry run, no DB) produces the coverage report. Report numbers go in the WP2 summary. |
| **WP3** | Dart engine v2 | `packages/pandapay_domain/lib/**`; `packages/pandapay_domain/test/**`; `db/fixtures/reward_v2_scenarios/10_dart.json` | v2 fields parse **tolerantly**: an unknown enum value in a v2 field skips that rule or cap, never the card. All C3 semantics and the C5 resolver are in. All files in `reward_v2_scenarios/` pass. **All existing package tests pass unchanged.** Add a `CardProductJson` round-trip for v2 fields. |
| **WP4** | JS engine v2 | `api/src/reward_math_v2.js` (new); `api/src/merchant_directory.js` (new resolver); `api/test/reward_math_v2.test.js`; `db/fixtures/reward_v2_scenarios/20_js.json` | Same C3/C5 semantics. All scenario files pass. `reward_math.js` (v1) is untouched and its tests still pass. Exports: `computeTransactionRewardV2`, `ruleAppliesV2`, `resolveMerchant`, `isV2Card`. |
| **WP5** | Merchant and platform directory data | `db/fixtures/merchant_directory.json` | At least 120 merchants covering every co-brand and every merchant named in CardPipeline accelerator rules and conditions (scan the local CardPipeline set). Includes sub-brands and parent links, legal-entity names seen on bank SMS when publicly known, MCCs where publicly documented, and all bank portals and payment apps referenced by card rules. No personal data. A short report lists the CardPipeline tokens still unmapped. |
| **WP6a** | Worked examples: HDFC and SBI Card (20 cards) | `db/fixtures/card_worked_examples/<slug>.json` for its cards; `api/scripts/catalogue_overrides/<slug>.json` for its cards | C6 files for each card in Appendix C of the feature spec (HDFC + SBI). Verified against issuer pages (MITC / product page). Research errors captured as override files with source URLs. |
| **WP6b** | Worked examples: ICICI, Axis, Amex, IDFC, others (≈26 cards) | Same, for its cards | Same. |

### Wave 2 (after wave 1 is merged into `card-rewards/phase1`)

| WP | Title | Owns | Done when |
|---|---|---|---|
| **WP7** | Integration and verification | `api/test/card_worked_examples.test.js`; `packages/pandapay_domain/test/card_worked_examples_test.dart`; `db/fixtures/catalogue_v2_cards/*.json` (generated snapshots of the transform for golden cards); `db/fixtures/reward_v2_scenarios/30_integration.json`; `api/scripts/catalogue_overrides/verified_cards.json`; fixes in other WPs' files **only via the lead** | Both engines pass every worked example for the golden cards. Mismatches are triaged into override / loader / engine fixes. Before/after audit numbers are recorded in the status doc. |
| **WP8** | Server recording v2 | `api/src/card_state_v2.js` (new); the `applyTransactionState` / `reverseTransactionState` regions of `api/src/index.js`; `api/src/cycles.js`; `api/scripts/recompute_card_state.js` (new); tests | v2 cards record through `reward_math_v2`, updating multiple caps per transaction (targets, card scope, parents) in native units. `expected_points` uses rounding. Milestone windows follow C3.7. The reverse path mirrors it. The recompute script rebuilds current-period `cap_states` / `milestone_states` and expected values after a catalogue publish (dry-run by default). `GET /user-cards` adds `cap_kind` / `cap_amount`. |
| **WP9** | App: v2 feed and cap bars (B1) | `app/lib/data/catalogue_repository.dart`; the catalogue section of `app/lib/app/providers.dart`; `app/lib/features/cards/my_cards_screen.dart`; the caps tab of `card_detail_screen.dart`; `app/lib/features/insights/caps_screen.dart`; cap notification triggers; their tests | The app fetches `?schema=2`, falling back to v1, then cache, then bundle. Parsing is per card (one bad card is skipped and logged, never the whole feed). The cache key is versioned. The merchant directory feeds the context builder. Cards show cap bars in native units ("1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100"). Alerts fire at 80% and 100% with the next-best card. Card detail shows the Partial / Basic label. Widget tests plus one golden (Alchemist) per new widget. |

### Wave 3 — Rollout (owner only; see §9)

## 6. Merge order and integration checkpoints

1. Lead commits docs, contracts, `00_contract.json` and the directory skeleton on
   `card-rewards/phase1`.
2. Wave 1 branches merge into `card-rewards/phase1` in this order:
   WP5 → WP1 → WP4 → WP3 → WP2 → WP6a → WP6b. Data first, schema next, engines
   before the loader that targets them.
3. **Checkpoint A** (lead), after wave 1:
   - `cd api && npm test`;
   - `cd packages/pandapay_domain && dart test`;
   - DB migration test on a fresh container;
   - loader dry run over the full CardPipeline set;
   - `audit_catalogue.js` before/after numbers into the status doc.
4. Wave 2: WP7 and WP8 in parallel (disjoint files), then WP9.
5. **Checkpoint B** (lead), after wave 2:
   - everything in A;
   - `flutter analyze` + app tests;
   - one Android emulator pass of the Cards page.
6. Owner review, then rollout (§9).

## 7. Testing strategy

| Layer | Test | Where |
|---|---|---|
| Contract | Shared scenario files, both engines | `db/fixtures/reward_v2_scenarios/` |
| Real cards | Worked examples, both engines, against generated snapshots | `db/fixtures/card_worked_examples/`, `catalogue_v2_cards/` |
| Loader | Pure transform on real records; every C7 rule | `api/test/catalogue_v2_*.test.js` |
| Database | Migration, views, RLS, triggers | `db/tests/20261105120000_card_rules_v2_test.sql` |
| API | v1 unchanged, v2 shape | `api/test/catalogue_route.test.js` |
| Backward compatibility | v1 feed parses in the **current released** `CardProductJson` (copy the v1 output into `packages/pandapay_domain/test/fixtures_catalogue_response.json` and keep it passing) | WP1 + WP3 |
| App | Widget tests + Alchemist goldens for cap bars | WP9 |

## 8. Phase 1 success numbers (measured by `audit_catalogue.js` on the v2 feed)

| Metric | Now | Target |
|---|---|---|
| Accelerators in unmapped categories (dropped) | 176 / 500 | 0 dropped (each is modelled or `info`) |
| Unrestricted accelerators | 98 rules / 74 cards | 0 unreviewed |
| Caps linked to nothing | 238 / 641 | 0 (enforced, card-wide, or flagged `unenforced_period`) |
| Bonus caps that zero out the base | ~428 post-cap 0 | 0 |
| Milestones on the wrong anchor | 292 / 292 | 0 |
| Spend-gated lounges as structured unlocks | 0 / 124 | ≥ 110 |
| Cards Verified (worked examples pass) | 0 | ≈ 46 (Appendix C, excluding cards not yet in the catalogue) |
| Old app installs parse v1 feed | yes | yes |

## 9. Rollout (owner-run, after Checkpoint B)

1. Review and merge `card-rewards/phase1` into the deploy branch; deploy (the
   migration applies automatically).
2. `node api/scripts/seed_merchant_directory.js --dry-run`, then a real run.
3. `api/scripts/sync_card_catalogue.sh --dry-run`. Review
   `.staging/coverage-report.md`. Real import (cards become drafts).
4. `publish_card_pipeline.js --dry-run`, then publish (existing review gate,
   audit log).
5. `node api/scripts/recompute_card_state.js --dry-run`, then a real run.
6. Run `audit_catalogue.js` against `https://api.pandapath.site/catalogue?schema=2`
   and record the numbers in the status doc.
7. Release the app build with WP9. Old installs keep using v1, which is now
   safer: no widened bonuses and correct bonus caps.

## 10. Risks

| Risk | Mitigation |
|---|---|
| v1 feed change breaks installed apps | H1; the backward-compatibility test pins the released parser |
| Engines drift | Shared scenario files; WP7 runs worked examples on both |
| Research errors look like engine bugs | Worked examples cite the issuer; errors become override files, reviewed |
| Over-conservative v2 (unknown rail/platform) under-states rewards | Shown as "estimated"; Phase 2 reconciliation measures the gap; the SMS layer can supply rail/platform |
| Parallel Codex/agent sessions collide | Exclusive file ownership; check `git worktree list` before launching; never push |
| `index.js` is dirty in the owner's main checkout | WP1/WP8 keep `index.js` edits to small, clearly bounded regions; conflicts are resolved at merge by the lead |
