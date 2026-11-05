# Card Rewards — Status Tracker

**Keep this file current.** Update it whenever a work package starts, finishes,
merges or changes plan. It is the single place to see where things stand and how
to resume.

**Integration branch:** `card-rewards/phase1`, in worktree
`.worktrees/card-rewards-phase1` (never pushed).
**Docs:**
[feature spec](card-rewards-intelligence-feature-spec-2026-11-05.md) ·
[Phase 1 plan](card-rewards-phase1-implementation-plan.md) ·
[agent plan](card-rewards-phase1-agent-plan.md) ·
[later phases](card-rewards-later-phases.md)

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1 — Trust the rules | Rules v2, loader v2, both engines, directory, worked examples, server recording, cap bars | **In progress** (wave 1 started 2026-11-05) |
| 2 — Ledger and progress | Points ledger, statement/screenshot reconciliation, milestones, unlocks, Cards page | Not started |
| 3 — Which card now | Recommendation v2, entry points, coaching, monthly plan, freshness | Not started |
| 4 — Value and Pro | Reports, portfolio audit, renewal advisor, Pro tier | Not started |

## Phase 1 work packages

Status values: `not started` · `running` · `done (branch ready)` · `merged` ·
`blocked` · `needs rework`.

| WP | Title | Wave | Branch | Status | Updated | Notes |
|---|---|---|---|---|---|---|
| WP0 | Docs, contracts, scenario seed, directory skeleton | 0 | `card-rewards/phase1` | merged | 2026-11-05 | Lead |
| WP1 | Schema v2, v1/v2 feeds, directory seeding | 1 | `card-rewards/wp1-schema` | **merged** | 2026-11-06 | Review + 6 follow-ups incl. hashed identity indexes (checkpoint); DB test in CI |
| WP2 | Loader v2 (pure transform), coverage, audit script | 1 | `card-rewards/wp2-loader` | merged; follow-up round running | 2026-11-06 | D24b UPI-only bonuses hidden from old apps; EMI exclusion alternatives; Magnus higher-tier rate; loader limits found by WP7 |
| WP3 | Dart engine v2 + tolerant parsing | 1 | `card-rewards/wp3-dart-engine` | **merged** | 2026-11-06 | 477/477 tests; all 127 shared scenarios agree with JS (incl. D15, D16, D18) |
| WP4 | JS engine v2 + merchant resolver | 1 | `card-rewards/wp4-js-engine` | **merged** | 2026-11-06 | 272/272 targeted tests on merged branch; passes all 127 shared scenarios incl. Dart's own |
| WP5 | Merchant and platform directory data | 1 | `card-rewards/wp5-directory` | **merged** | 2026-11-06 | 164 merchants (9 true sub-brand parents, `group` tags per D6), 61 platforms; review + 1 fix round clean; IHCL brands kept under `taj` (ruling in ledger) |
| WP6a | Worked examples: HDFC, SBI Card | 1 | `card-rewards/wp6a-examples-hdfc-sbi` | **merged** | 2026-11-06 | 21/21 cards, 15 override files; review + 1 fix round clean; Swiggy exact-half rounding parked |
| WP6b | Worked examples: ICICI, Axis, Amex, IDFC, others | 1 | `card-rewards/wp6b-examples-others` | **merged** | 2026-11-06 | 23/25 cards (Amazon Pay ICICI, AU Zenith+ skipped), 13 override files; 2 fix rounds, verified with the real loader; 18-card loader mismatches carried to WP7 |
| WP7 | Integration: worked examples through both engines | 2 | `card-rewards/wp7-integration` | needs rework (fix round 2) | 2026-11-06 | Round 1 confirmed (UNO, SimplyCLICK, Flipkart, IndiGo, EMI). Round 2: SBI Tata Neu cards still pay on EMI/UPI, missing issuer exclusions and limits on touched cards, 1-point rounding tolerance — D25 |
| WP8 | Server recording v2 + recompute script | 2 | `card-rewards/wp8-server-state` | fix round 2 done, in re-review | 2026-11-06 | Round 2 in: cashback kept out of the points balance, the edit/recalc lock on all edit routes, Indian-time milestone window, steadier test; 309 server tests pass incl. 9 real-database |
| WP9 | App: v2 feed, tolerant parse, cap bars, alerts | 2 | — | not started | | Starts after WP8 merges |
| — | Checkpoint A (after wave 1) | — | — | **passed** | 2026-11-06 | API 1695/0 fail; Dart 477/0; real DB import 376/376; old feed parsed by the released app parser with 0 errors; JS = Dart on 11,914 real-data purchases (0 mismatches) |
| — | Checkpoint B (after wave 2) | — | — | not started | | |
| — | Rollout (owner) | 3 | — | not started | | See plan §9 |

## Metrics (from `audit_catalogue.js`)

| Metric | Baseline 2026-11-05 (prod v1) | After Phase 1 (v2) |
|---|---|---|
| Bonus rules dropped (unmapped category) | 176 / 500 (104 cards); WP2 count 249 / 147 cards | 0 dropped (361 modelled, 437 info) — WP2 dry run |
| Unrestricted accelerators | 98 rules / 74 cards | 6 rules / 6 cards (2 flagged) — WP2 dry run |
| Caps linked to nothing | 238 / 641 | 30 / 642, all flagged — WP2 dry run |
| Caps with post-cap 0 | 428 (273 bonus caps zeroing base) | 0 bonus caps zeroing base — WP2 dry run |
| Milestones on the wrong anchor | 292 / 292 (60 non-annual) | 0 / 308 — WP2 dry run |
| Spend-gated lounges structured | 0 / 124 | 115 cards (195 unlock rows) — WP2 dry run |
| Co-brand cards with a merchant rule | 8 / 74 (WP2 count 5 / 102) | 53 / 102 — WP2 dry run |
| Cards Verified | 0 | 19 (WP7, pending review); 15 more pass all examples but blocked by loader flags |

## Decisions log

| Date | Decision | By |
|---|---|---|
| 2026-11-05 | Fixes are card-wide patterns; named cards are only examples. | Owner |
| 2026-11-05 | Defaults for open questions taken as in feature spec §13. | Owner (implicit, "start implementing") |
| 2026-11-05 | New semantics ship only in the v2 feed (`?schema=2`); v1 shape frozen. | Lead (plan H1) |
| 2026-11-05 | Unmodellable rules become `info`, never widened. | Lead (plan H2) |
| 2026-11-05 | Unknown rail/platform does not satisfy a restriction on v2 cards. | Lead (plan C3.3) |
| 2026-11-05/06 | Contract changes D1–D8 (identity indexes, v1 cap filter, cap engine version, issuer slugs, coverage.json, parent vs group, rounding modes, loader/data rules) — plan §4 C8. | Lead |
| 2026-11-06 | IHCL hotel brands stay under `taj` (taj = IHCL). | Lead (ledger ruling) |
| 2026-11-06 | D12: a category paying less than the base earns its own (lower) rate; D13: cardholder-dependent caps/rates (credit-limit caps, tiers, paid memberships) are deferred to Phase 2 and never guessed. | Lead |
| 2026-11-06 | D14: examples depending on facts a purchase can't tell us (gift card, international, birthday) are kept but not engine-checked; such rules are info-only until Phase 2; overrides must never drop exclusions. | Lead |
| 2026-11-06 | D15: engines never silently drop limits or exclusions they can't read; they skip visibly and lower confidence. The app must not use cap headroom for points caps until server state is in native units (WP8). | Lead |
| 2026-11-06 | D16: exclusions with exceptions ("no rewards on fuel except at IndianOil", "utilities only via Google Pay") and minimum amounts ("nothing below ₹100") are modelled; an unknown merchant or app never proves an exception. | Lead |
| 2026-11-06 | D17: the loader never widens a narrow bonus (pharmacy, movies, hotels, flights) to a whole category — it uses MCC codes or keeps it information-only; exclusions never lose their old-app row; fee/surcharge/redemption limits are never attached to earning rules. | Lead |
| 2026-11-06 | D18: some rows exist only for the old feed (broad exclusions, broad reduced rates); the new engines ignore them and use the precise version, so old apps stay cautious and the new app stays accurate. | Lead |
| 2026-11-06 | D19: an exclusion counts as "bonus-only" only if every benefit it removes is a bonus/accelerated rate; an explicit MCC list is the exclusion's real scope; caps follow their source rule; a capped bonus without its cap is hidden from old apps. | Lead |
| 2026-11-06 | D22: milestone progress counts only spends that earn (never over-states); welcome offers start from the card's issue date; old app installs keep the old meaning of limit progress; rule order made deterministic. | Lead |
| 2026-11-06 | D23: limit periods follow Indian time and correct statement dates (incl. 1st and 29th–31st); edits and recalculations can't overlap. | Lead |
| 2026-11-06 | D25: issuer examples may differ by 1 point where the bank rounds each part separately (the engine may under-state, never over-state); a spend with an unknown payment method gets the normal card rate; every issuer exclusion a card has must be carried on the cards we touch; Tata Neu SBI earns nothing on EMI; installed apps lose the 5% at Flipkart on the Flipkart Axis card until they update. | Lead |
| 2026-11-06 | D24: a card's value counts only rewards the card itself gives (not the merchant's own loyalty programme); UPI-only bonuses are hidden from old app versions; newer documents' silence never removes a documented limit. | Lead |
| 2026-11-06 | D10: cards switch to the v2 engine only when re-imported by the v2 loader (DB defaults alone never switch a card), so existing cards keep today's behaviour until re-import. | Lead |

## Changelog

- **2026-11-06:** **Checkpoint A passed.** All tests green; all 376 cards import into a real database; the old feed parses in the app version installed today; the phone and server engines agree on 11,914 real-data purchases. Wave 2 next.
- **2026-11-06:** WP2 merged — all of wave 1 is in. Checkpoint A started: all tests green; the first real database import loaded 365 of 376 cards and found 2 issues (index size on 9 cards, duplicate benefits on 2), now being fixed.
- **2026-11-06:** WP3 merged (phone reward engine v2; same answers as the server on all shared scenarios).
- **2026-11-06:** WP6b merged (23 more cards with issuer-verified examples). WP4 follow-ups (D15, D16) merged.
- **2026-11-06:** WP4 merged (server reward engine v2).
- **2026-11-06:** WP6a merged (21 HDFC/SBI cards with issuer-verified examples and 15 correction files).
- **2026-11-06:** WP1 merged (schema v2, feeds, seeder; backward-compatibility test now in CI).
- **2026-11-06:** WP5 merged into `card-rewards/phase1` after one fix round.
- **2026-11-06:** All agents paused by the 5-hour usage limit, then resumed. WP1 finished (review pending). WP5 finished, in fix round 1 (Titan parent links, bare "indigo" alias, contract D6). Contract changes D1–D6 recorded in plan §4 C8.
- **2026-11-05:** Feature spec approved with the card-wide change. Phase 1 plan,
  agent plan, later-phases summary and this tracker written. Integration worktree
  created from `33ee22f`. Wave 1 agents launched.

## How to resume (new session or new person)

1. Read this file, then the Phase 1 plan §2 (constraints) and §4 (contracts).
2. `git -C .worktrees/card-rewards-phase1 log --oneline -15` shows what is
   merged.
3. `git branch --list 'card-rewards/*'` and `git worktree list` show agent
   branches still open.
4. For each WP marked `done (branch ready)`, review and merge using the agent
   plan §5. Then run the checkpoint commands and update this file.
5. Next wave briefs are in the agent plan §4.
