# Card Rewards — Phase 1 Multi-Agent Plan

**Date:** 2026-11-05 · Companion to the
[Phase 1 plan](card-rewards-phase1-implementation-plan.md) (contracts §4, work
packages §5). Progress is tracked in [card-rewards-status.md](card-rewards-status.md).

## 1. How this works

- **Lead** (the coordinating session) owns:
  - the contracts;
  - `db/fixtures/reward_v2_scenarios/00_contract.json`;
  - the integration branch `card-rewards/phase1`;
  - merges, checkpoints and the status file.
- **Agents** each take one work package (WP). Each agent:
  - runs in its own git worktree;
  - starts from `card-rewards/phase1`;
  - edits only the files its WP owns;
  - commits to its own branch `card-rewards/wpN-...`;
  - ends with a short report.
- Agents never push, deploy or touch production. The owner runs rollout.
- Before launching any agent, the lead checks:
  - `git worktree list`;
  - `git branch --list 'card-rewards/*'`;
  - the owner's Codex worktrees, to avoid duplicate work (see memory note
    `sms-v2-parallel-codex-work`).

## 2. Common brief (prepended to every agent prompt)

```
You are implementing work package {WP} ("{TITLE}") of PandaPay Card Rewards Phase 1.

Setup — run first, in your current directory (your own git worktree of
/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs):
  1. git merge --ff-only card-rewards/phase1
     (if not a fast-forward: git merge --no-edit card-rewards/phase1; stop and report if it conflicts)
  2. git branch -m {BRANCH}
Then read: docs/card-rewards-phase1-implementation-plan.md — §2 constraints, the §4
contracts your WP uses, and your row in §5 — and this brief.

Rules:
- Edit only the files your WP owns (plan §5). If another file must change, don't
  change it; describe the change in your final report.
- Contracts (plan §4) are fixed. If one is wrong or ambiguous, take the most
  conservative reading, record it under "Contract questions", and keep going.
- Never push, deploy, publish, or touch production (prod DB, api.pandapath.site
  writes). Never modify the main checkout at
  /Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs — it holds someone
  else's uncommitted work. Never touch Docker containers you didn't start.
- No personal data or real SMS content in any file. Quotes from issuer pages
  stay under 25 words.
- Tests first for each behaviour. While iterating, run only your targeted tests.
  At the end, run the full suite of the package you touched once
  (api: `cd api && npm test`; Dart: `cd packages/pandapay_domain && dart test`).
  Don't build or run the Flutter app.
- Commit in small logical commits on your branch. Message format
  "card-rewards({wp}): <what>", ending with the line
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>".

Final message (≤ 400 words):
- branch name and final commit SHA;
- each "Done when" item: done / partial / not done;
- test commands run and results;
- files changed;
- contract questions;
- follow-ups needed from other WPs;
- anything unfinished.
```

## 3. Wave 1 — specific briefs

### WP1 — Schema, feeds, directory seeding · branch `card-rewards/wp1-schema`

- **Patterns to copy:**
  - `db/supabase/migrations/0003_card_catalogue.sql`: tables and version-bump
    triggers.
  - `0015_card_products_rls_fix.sql` and later RLS migrations: read/write
    policies.
  - `0043_card_product_network_variants.sql`: current view definitions; redefine
    both public and admin views from it.
- **Migration runner:** `db/scripts/product_migrate.js` (see
  `db/scripts/migrate.sh` for env vars). For DB tests, start your **own**
  throwaway container, e.g.
  `docker run --rm -d --name cr-wp1-pg -e POSTGRES_PASSWORD=pg -p 55432:5432 postgres:17-alpine`.
  Apply all migrations, then run your SQL test with `psql`. Follow the style of
  existing `db/tests/*.sql` (find how they're run: grep `db/tests` under `db/`,
  `deploy/` and `scripts/`). Stop your container when done.
- **Migration naming:** check `db/scripts/migration_prefix_policy.js` and
  `db/migration-prefix-exceptions.json` so the new timestamp-prefixed file passes
  policy.
- **Route:** `api/src/catalogue_route.js` exports
  `createCatalogueHandler({withUserClient})`, serving v1 by default and v2 when
  `req.query.schema === '2'`. In v2, also query `merchant_brands` /
  `payment_platforms` (active only). Follow `api/src/lounge_usage_route.js` and
  its test for the handler-factory and response-double style. In `index.js`,
  replace only the body of the existing `app.get('/catalogue', …)` with the
  module.
- **Seeder:** `api/scripts/seed_merchant_directory.js --dry-run|--apply` reads
  `db/fixtures/merchant_directory.json` and upserts it. It never deletes; it
  deactivates slugs that disappeared from the file only with `--deactivate-missing`.
- **Backward-compatibility proof:** in the DB test, insert a card with one v1
  rule, one `min_engine_version=2` rule and one `info` rule. Assert the v1 view
  shows only the first and the v2 view shows all three.

### WP2 — Loader v2 · branch `card-rewards/wp2-loader`

- **Source data (read-only):** `/Users/chandresh_kerkar/Documents/PandaPath/CardPipeline`.
  `data/checklist.json` rows have `status: done` and an `output_file`. Some output
  files wrap the record in `final`; others use `original`. Reuse the existing
  unwrapping in `api/scripts/collect_card_pipeline.js` / `import_card_pipeline.js`.
- **Fixture records:** copy 5–8 real records into `api/test/fixtures/cardpipeline/`
  (strip nothing; it's our own research data):
  - `hdfc-bank-swiggy-hdfc-bank-credit-card` (co-brand, `swiggy_app` token,
    spend-vs-cashback cap mix-up);
  - `state-bank-of-india-phonepe-sbi-select-black-credit-card` (app platform,
    nested caps, MCC exclusions);
  - `american-express-india-platinum-travel-credit-card` (brand-portal
    accelerator, milestones, redemption options);
  - `punjab-national-bank-pnb-kiwi-credit-card` (null cap value, Kiwi Neon
    unlocks);
  - HDFC Infinia (many caps, SmartBuy);
  - `axis-bank-axis-bank-atlas-credit-card` (tiers);
  - a plain cashback card.
- **Design:** pure `transformCardRecordV2` in `api/scripts/catalogue_v2/`, split
  by concern (`category_tokens.js`, `conditions.js`, `caps.js`, `milestones.js`,
  `unlocks.js`, `coverage.js`, `overrides.js`). The existing DB writer in
  `import_card_pipeline.js` calls it and writes the v2 columns and tables (plan
  C1), plus the v1 projections (plan C7.7).
- **Directory:** use slugs from `db/fixtures/merchant_directory.json`. WP5 is
  enriching it in parallel. If you need a slug that isn't there, still map it
  and list it under "needs directory entry".
- **Dry run:** add a `--transform-only` mode (no DB) that runs the transform over
  every `done` row and writes `api/scripts/.staging/coverage-report.{json,md}`.
  Run it and put the headline numbers in your report.
- **Audit:** `api/scripts/audit_catalogue.js <file-or-url>` prints the feature-spec
  R1–R9 metrics for a v1 or v2 catalogue JSON. A copy of the 2026-11-05 prod v1
  feed may be fetched once with
  `curl -s https://api.pandapath.site/catalogue` (public read) for testing; don't
  commit it.
- **Never run against any database.**

### WP3 — Dart engine v2 · branch `card-rewards/wp3-dart-engine`

- **Package:** `packages/pandapay_domain` (pure Dart; `dart test`).
- **Models:** extend `card_rules.dart` / `card_rules_json.dart` with v2 fields,
  all optional with v1-safe defaults: rule role, merchant/platform slugs, MCC
  include/exclude, `block_inr`, `min_engine_version`, `display_note`; cap kind,
  amount, scope, targets, parent, post behaviour, anchor; card accrual
  block/rounding, model status/coverage, expiry months; unlock rules; redemption
  options.
  - **Tolerant parsing for v2 fields:** an unknown enum value skips that rule or
    cap (collect a warning), never the card.
  - The v1 parsers stay strict as today; existing tests must pass unchanged.
- **Directory:** add `MerchantDirectory` (C5) with `fromJson` and `resolve`.
- **Engine:** `RecommendationContext` gets `platform` and `merchantSlug`
  (optional). The engine gets the C3 v2 path behind the v1/v2 switch (C3.2), and
  the evaluation exposes `points`, `cashbackInr`, `capDeltas` and `excluded` in a
  way the app can use.
  Keep `RecommendationEngine`'s public API source-compatible for existing
  callers; the app must still compile without changes.
- **Tests:**
  - load **every** file in `db/fixtures/reward_v2_scenarios/` (see how
    `test/reward_parity_test.dart` loads `../../db/fixtures/...`);
  - add `10_dart.json` with your edge cases (≥ 15);
  - round-trip test for v2 JSON.

### WP4 — JS engine v2 · branch `card-rewards/wp4-js-engine`

- **New modules:**
  - `api/src/reward_math_v2.js`, exporting `isV2Card`, `ruleAppliesV2`,
    `pickRuleV2`, `applicableCaps`, `computeTransactionRewardV2`.
    `computeTransactionRewardV2({card, rewardRules, capRules, capConsumedBefore: {capId: n}, ctx, directory})`
    returns `{points, cashbackInr, valueInr, ruleId, capDeltas, excluded, reasons, assumptions}`.
  - `api/src/merchant_directory.js`, exporting `loadDirectory(json)`,
    `resolveMerchant(dir, name, vpa)` and `ancestors(dir, slug)`.
- v1-shaped cards delegate to the existing `reward_math.js`, so v1 results are
  identical. **Don't edit `reward_math.js`.**
- **Tests:**
  - `api/test/reward_math_v2.test.js` loads **every** file in
    `db/fixtures/reward_v2_scenarios/`;
  - add `20_js.json` with your edge cases (≥ 15);
  - also assert that a v1-shaped card gives the same answer as `reward_math.js`
    on the existing `db/fixtures/reward_parity_scenarios.json` cards.

### WP5 — Merchant and platform directory · branch `card-rewards/wp5-directory`

- **Owns:** only `db/fixtures/merchant_directory.json`. Keep the skeleton's slugs;
  never rename one.
- **Coverage:** scan the local CardPipeline set
  (`/Users/chandresh_kerkar/Documents/PandaPath/CardPipeline`, `data/checklist.json`
  → `output_file`) for merchant and platform tokens:
  - `reward_rules[].category_id` values that name a brand/app/portal;
  - `conditions.merchant*`, `merchant_names`, `eligible_merchants`, `platform`,
    `app`, `channel_type`;
  - `dynamic_promotions_registry[].platform`.
  Every brand or portal they name must have an entry.
- **Each merchant:**
  - name;
  - `parent_slug` for sub-brands (Instamart → Swiggy, Blinkit → Zomato,
    Goibibo → MakeMyTrip, …);
  - `category_slug` from the app's categories (see `db/seed` and the
    spend_categories migrations for valid slugs);
  - aliases: brand names plus legal-entity names that appear on bank SMS
    **only when you are confident** (e.g. "Bundl Technologies" for Swiggy);
    avoid aliases that are common words;
  - MCC only when publicly documented;
  - `vpa_prefixes` only for well-known, publicly documented merchant UPI
    handles, else empty.
- **Platforms:** payment apps (PhonePe, Paytm, Amazon Pay, CRED, Kiwi, …), bank
  portals (HDFC SmartBuy, ICICI iShop, Axis Travel EDGE / Grab Deals, Amex Reward
  Multiplier, SBI Rewardz, …), and merchant apps where a card requires "in the
  app" (Swiggy app, IRCTC app, …).
- **Report:** CardPipeline tokens you couldn't map, with counts.

### WP6a / WP6b — Worked examples · branches `card-rewards/wp6a-examples-hdfc-sbi`, `card-rewards/wp6b-examples-others`

- **Owns:** `db/fixtures/card_worked_examples/<source_slug>.json` and
  `api/scripts/catalogue_overrides/<source_slug>.json` for **its** cards only.
- For each card:
  1. Find its row in `CardPipeline/data/checklist.json` (`source_slug`, `id`,
     `output_file`) and read the CardPipeline record.
  2. Verify the earning rules, caps, exclusions, rounding and milestones against
     the **issuer's own** product page / MITC / KFS (WebFetch/WebSearch). Prefer
     official documents dated 2026.
  3. Write ≥ 6 examples per plan C6, using the **bank's real behaviour**. If the
     bank's behaviour is unclear, say so in `why` and skip that example rather
     than guess.
  4. Where CardPipeline is wrong or missing something, add a `research_notes`
     entry and an override file (plan C7.2), with a source URL and
     `checked_on: 2026-11-05`.
- If a card isn't in the CardPipeline checklist, list it in your report and skip
  it.
- **Priority:** finish complete, correct files for as many cards as possible,
  over partial files for all. Report which cards are complete.
- **WP6a cards (HDFC + SBI):**
  - HDFC: Infinia (Metal Edition), Diners Club Black, Regalia Gold, Millennia,
    Swiggy HDFC, Tata Neu Infinity HDFC, Tata Neu Plus HDFC, PhonePe HDFC Uno,
    PhonePe HDFC Ultimo, IndianOil HDFC, IRCTC HDFC.
  - SBI Card: Cashback, SimplyCLICK, PhonePe SELECT BLACK, PhonePe PURPLE,
    Tata Neu Infinity SBI, Tata Neu Plus SBI, BPCL Octane, Flipkart SBI,
    IRCTC SBI Premier, AURUM.
- **WP6b cards:**
  - ICICI: Amazon Pay, Sapphiro, Emeralde, HPCL Super Saver, MakeMyTrip
    Signature.
  - Axis: Atlas, Magnus, ACE, Flipkart Axis, Airtel Axis, IndianOil Axis.
  - Amex: Platinum Travel, Membership Rewards, Gold, SmartEarn, Platinum.
  - IDFC FIRST: Millennia, Wealth, Select, Power+.
  - Others: PNB Kiwi, YES Klick (Kiwi), AU Zenith, HSBC Live+, IndiGo Kotak.

## 4. Wave 2 — briefs (launched 2026-11-06 after Checkpoint A)

Common brief (§2) applies. Checkpoint A recipe for a throwaway Postgres (agents run their own container, never production):
`docker run --rm -d --name <you>-pg -e POSTGRES_PASSWORD=pg -e POSTGRES_DB=pandapay -p <port>:5432 postgres:17-alpine`; migrate with
`node -e "require('./db/scripts/product_migrate.js').main()"` and env ADMIN_DATABASE_URL=postgres://postgres:pg@localhost:<port>/pandapay, DB_DIR=<repo>/db,
APP_USER_PASSWORD, REWARD_WORKER_DB_PASSWORD (≥16 chars), PHONE_LOOKUP_HMAC_KEY (64 hex), DB_SSL=false, NODE_ENV=test, NODE_PATH=<repo>/api/node_modules;
admin: `insert into admin_users(id,email,role) values (gen_random_uuid(),'x@local.test','owner')`; seed: `node api/scripts/seed_merchant_directory.js --apply`;
import: `node api/scripts/collect_card_pipeline.js --pipeline /Users/chandresh_kerkar/Documents/PandaPath/CardPipeline --out api/scripts/.staging` then
`node api/scripts/import_card_pipeline.js --input api/scripts/.staging/all-collected.json --admin-id <id>`. Views only show published cards: publish inside a
transaction and roll back when you only need to read them.

### WP7 — Integration and verification · branch `card-rewards/wp7-integration`
- **Owns:** `api/scripts/catalogue_v2/snapshot_examples.js` (new); `db/fixtures/catalogue_v2_cards/*.json` (generated); `api/test/card_worked_examples.test.js`; `packages/pandapay_domain/test/card_worked_examples_test.dart`; `db/fixtures/reward_v2_scenarios/30_integration.json`; `api/scripts/catalogue_overrides/verified_cards.json`.
- **May edit, with a cited reason per change in the report:** `api/scripts/catalogue_overrides/<slug>.json` (research corrections); `db/fixtures/merchant_directory.json` (data only — e.g. MCCs); `db/fixtures/card_worked_examples/*.json` (only to correct an example proven wrong against issuer text).
- **Must not edit:** loader code (`api/scripts/catalogue_v2/**` except the new snapshot script), engines, migrations. Report loader/engine bugs with a minimal reproduction.
- **Steps:** (1) snapshot generator: for every card with a worked-examples file, run the WP2 transform (CardPipeline record + overrides + directory) and write its v2 wire card (stable ids from `source_local_id`, e.g. `x#1`) plus the directory; (2) both harnesses: every example with `engine_checkable !== false` runs through JS and Dart; map `caps_by_source_id` to every emitted cap of that source (splits `#n`), compare currency, amount, value, excluded and cap deltas summed per source; (3) triage every failure into: example wrong / research data wrong (override) / directory data / loader bug (report) / engine bug (report + correct expected values in `30_integration.json`); (4) re-check the WP6b 18-card mismatch list and the deferred items in the ledger (IndiGo airline MCC so `indigo_flights_base` returns to v1; MCCs 5311/5411 on `metro_cash_carry`, `best_price`, `flipkart_wholesale`; idfc `government_reduced` mcc_range); (5) write `verified_cards.json` = cards whose engine-checkable examples all pass in both engines and that carry no D18(j) blocking flag; re-run `--transform-only` and report model_status counts; (6) before/after `audit_catalogue.js` numbers.
- **Done when:** every engine-checkable example passes in both engines, or is listed as a known failure with category and routed fix (tests mark known failures explicitly — no silent skips); `cd api && npm test` and `dart test` green; Verified count reported.

### WP8 — Server recording v2 · branch `card-rewards/wp8-server-state`
- **Owns:** `api/src/card_state_v2.js` (new); the `applyTransactionState` / `reverseTransactionState` regions and the `GET /user-cards` cap/milestone mapping in `api/src/index.js`; `api/src/cycles.js`; `api/scripts/recompute_card_state.js` (new); a new migration `db/supabase/migrations/20261106120000_card_state_v2.sql` if columns are needed; tests (`api/test/card_state_v2*.test.js`, `db/tests/20261106120000_card_state_v2_test.sql`).
- **Requirements:** v2-shaped cards (`isV2Card`) record through `reward_math_v2.computeTransactionRewardV2` with the directory loaded from `merchant_brands` / `payment_platforms` (cached). Every applicable cap (targets, card scope, parents) gets its own `cap_states` row per period, with `consumed` in **native units** (points / ₹ / count) and the cap kind recorded so readers know the unit (D15f). Period bounds per cap `period` + `anchor` (C3.7; card anniversary from `anniversary_on ?? opened_on ?? created_at`, flagged approximate). `expected_points` / `expected_value_inr` from the v2 result. Milestone windows per C3.7 (welcome milestones with `window_days`). The reverse path mirrors exactly. v1-shaped cards keep today's path byte-for-byte. `GET /user-cards` adds `cap_kind`, `cap_amount`, native `consumed`, period bounds and an `approximate_window` flag. `recompute_card_state.js` rebuilds current-period cap/milestone states and expected values for v2 cards after a catalogue publish — dry-run by default, prints diffs, idempotent.
- **Done when:** Postgres-backed tests (own container) cover record → reverse → recompute on a v2 card with bonus, total, eligible-spend and parent caps; v1 cards unchanged (existing tests pass); `cd api && npm test` green.

### WP9 — App: v2 feed, cap bars, alerts · branch `card-rewards/wp9-app-caps` (after WP8)
- **Owns:** `app/lib/data/catalogue_repository.dart`; the catalogue/cache section of `app/lib/app/providers.dart` (`catalogueProvider`, a new `merchantDirectoryProvider`, `recommendationEngineProvider`, the `CardSnapshot` builder near `capRemaining`, and the `RecommendationContext` builders that know a merchant name); the cap-state parsing in `app/lib/data/user_cards_repository.dart` (`cap_states` → `UserCard`); the other `CardSnapshot` sites (`features/insights/caps_screen.dart`, `features/calculator/big_purchase_calculator_screen.dart`, `features/scan/scan_result_screen.dart`, `features/onboarding/all_set_screen.dart`); `features/cards/my_cards_screen.dart`; the caps area of `features/cards/card_detail_screen.dart`; the cap section of `features/notifications/notification_triggers.dart`; new widgets under `app/lib/features/cards/widgets/`; their tests and goldens. **Must not edit** `packages/pandapay_domain` (report needed changes) or any API/DB file. Keep `providers.dart` edits small and local: the owner has unrelated uncommitted work in that file on master, so a large diff there means a painful merge.
- **Feed (C2):** `GET /catalogue?schema=2` returns `{schema: 2, cards, merchants, platforms}`. Fallback order: v2 live, then v1 live (`/catalogue`, for an older server), then cache, then bundled asset. Keep today's cache-first order; changing the refresh policy is out of scope. Cache under a **new versioned key** (e.g. `catalogue.v2`) holding the v2 body losslessly. Either store the raw response or prove `CardProduct.toJson` round-trips every v2 field with a test. Read the old `catalogue` key only as a v1 last resort.
- **Tolerant parse (D15):** parse per card at every site (live, cache, bundle). A card that throws is skipped and counted, never the whole list; log only the card id and error type. The directory uses `MerchantDirectory.fromJson` (already tolerant; surface `parseWarnings` the same way).
- **Directory into the engine:** `recommendationEngineProvider` passes `merchantDirectory` (empty directory on v1 fallback). Every `RecommendationContext` built from a merchant name resolves it via the directory and sets `merchantSlug`. When the context has no MCC, it sets `mcc` to the resolved merchant's **first** listed MCC (D19c, D24f). Never guess a platform (C3.1).
- **Cap state, native units (D15f, D22c):** `GET /user-cards` `cap_states` rows carry `cap_rule_id`, `consumed` (v1 measure: unchanged for old installs), and for v2 rows `consumed_native`, `cap_kind`, `cap_amount`, `period_start`, `period_end` (`YYYY-MM-DD`) and `approximate_window`. `consumed_native` and `cap_kind` are null on v1 rows. Parse these into `UserCard`, keeping `capConsumed` as-is for v1 cards.
  - For **v2-shaped cards** (`product.isV2Shaped`), every `CardSnapshot` site sets `capConsumed` from `consumed_native` and leaves `capRemaining` **empty** for those caps. The engine's `v2CapConsumed` fallback (`capValue − capRemaining`) would otherwise mix the v1 ₹ measure with native points.
  - **Lead's ruling:** on a v2 card, a cap row with null `consumed_native` (written before the owner's recompute) is treated as **unknown, not empty**. Feed `consumed = cap_amount` so the engine promises no capped bonus, and show the bar as "updating". Never derive native units from the v1 `consumed`.
  - No row for a cap means nothing consumed this period.
- **Cap bars (B1):** show bars on the My Cards tile (the fullest cap), card detail (all caps) and the caps screen, in native units, e.g. "1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100".
  - **Units by `cap_kind`:** points kinds → "pts"; ₹-cashback kinds → "₹"; spend kinds → "₹ spent"; count kinds → "uses".
  - **Reset date:** `period_end + 1 day`, with "approx." when `approximate_window`.
  - **"then …" clause:** comes from the cap's `post_cap_behavior` (base rate / nothing / custom rate). Omit it when unsure rather than guess.
  - **v1 cards** keep today's display.
- **Alerts:** keep the existing 80% / 100% triggers and their dedupe and budget. For v2 caps:
  - compute the ratio as `consumed_native / cap_amount`;
  - bucket by the server's `period_start`;
  - add the next-best **owned** card for that cap's category (the recommender with the capped card excluded), as "Use {card} for {category} instead". Omit it when none earns more than base.
- **Model status:** card detail shows a "Partial" or "Basic" label from `modelStatus`, with a one-line explanation sheet ("Some earning rules for this card are estimated"). Verified cards get no warning label.
- **Tests:**
  - repository tests for v2 → v1 → cache → bundle, per-card skip and the cache key;
  - snapshot-builder tests proving v2 cards never use the v1 measure (including the null `consumed_native` case);
  - a context-builder test for the merchant slug and first-MCC fill;
  - notification tests for native ratio and next-best;
  - widget tests plus one Alchemist golden per new widget (follow `test/flutter_test_config.dart`).
  - Run `flutter analyze` on the app and `flutter test` once at the end. Generate goldens only for your new tests.
- **Done when:** all of the above, analyze clean, app tests green, `dart test` in the domain package still green (untouched).

## 5. Merging (lead)

For each finished branch:

1. Read the report. Check the diff stays within the owned files:
   `git diff --stat card-rewards/phase1...<branch>`.
2. In the integration worktree, run `git merge --no-ff <branch>`. Order:
   WP5 → WP1 → WP4 → WP3 → WP2 → WP6a → WP6b.
3. Run that WP's targeted tests on the merged result.
4. Update `card-rewards-status.md`: status `merged`, the date, and notes
   (including contract questions raised).
5. Contract change needed? Edit plan §4 first, record it in the status decisions
   log, then tell the affected running agents (SendMessage) or fold it into
   wave 2.

**Checkpoint A** (after all wave 1 merges):

```bash
cd api && npm test
```

```bash
cd packages/pandapay_domain && dart test
```

```bash
node api/scripts/import_card_pipeline.js --transform-only
```

```bash
node api/scripts/audit_catalogue.js api/scripts/.staging/<v2 export>.json
```

Then run the DB migration test in a throwaway container and record the numbers
in the status file.

## 6. If something goes wrong

- **Agent stopped early:**
  - its worktree and branch remain (`git worktree list`);
  - relaunch the same WP with the same brief plus "Continue from branch
    `<name>`; first run `git log` to see what's done";
  - or continue it with SendMessage if it's still addressable.
- **Two branches touched the same file:** the lead resolves at merge, preferring
  the owner listed in plan §5, and records it in the status file.
- **New session picking this up:** follow "How to resume" in
  `card-rewards-status.md`.
