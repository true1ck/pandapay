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
| WP1 | Schema v2, v1/v2 feeds, directory seeding | 1 | `card-rewards/wp1-schema` | **merged** | 2026-11-06 | Review approved + 1 fix round (D1, D2, D7, CI step); 1393 api tests; DB test fresh + incremental; seeder loads 164/61 |
| WP2 | Loader v2 (pure transform), coverage, audit script | 1 | `card-rewards/wp2-loader` | running | 2026-11-05 | |
| WP3 | Dart engine v2 + tolerant parsing | 1 | `card-rewards/wp3-dart-engine` | needs rework (fix round 1) | 2026-11-06 | Review approved; agrees with the server engine on 117/118 shared cases (K15 harness fix); applying D15 robustness rulings |
| WP4 | JS engine v2 + merchant resolver | 1 | `card-rewards/wp4-js-engine` | **merged** | 2026-11-06 | Review approved + 1 fix round (D10–D12); 47 JS scenarios pin every ruling; 200/200 targeted tests on merged branch; Dart engine already agrees on 117/118 (K15 harness fix pending in WP3) |
| WP5 | Merchant and platform directory data | 1 | `card-rewards/wp5-directory` | **merged** | 2026-11-06 | 164 merchants (9 true sub-brand parents, `group` tags per D6), 61 platforms; review + 1 fix round clean; IHCL brands kept under `taj` (ruling in ledger) |
| WP6a | Worked examples: HDFC, SBI Card | 1 | `card-rewards/wp6a-examples-hdfc-sbi` | **merged** | 2026-11-06 | 21/21 cards, 15 override files; review + 1 fix round clean; Swiggy exact-half rounding parked |
| WP6b | Worked examples: ICICI, Axis, Amex, IDFC, others | 1 | `card-rewards/wp6b-examples-others` | fix round 2 in re-review | 2026-11-06 | 23/25 cards; Kiwi/IDFC Select/MMT fixed and checked with the real loader; remaining 18-card loader mismatches handed to WP7 after D16 |
| WP7 | Integration: worked examples through both engines | 2 | — | not started | | Needs wave 1 merged; inputs include WP6b's 18-card mismatch list (ledger) and D16 except-list modelling |
| WP8 | Server recording v2 + recompute script | 2 | — | not started | | Needs WP1, WP4 |
| WP9 | App: v2 feed, tolerant parse, cap bars, alerts | 2 | — | not started | | Needs WP1, WP3 |
| — | Checkpoint A (after wave 1) | — | — | not started | | |
| — | Checkpoint B (after wave 2) | — | — | not started | | |
| — | Rollout (owner) | 3 | — | not started | | See plan §9 |

## Metrics (from `audit_catalogue.js`)

| Metric | Baseline 2026-11-05 (prod v1) | After Phase 1 (v2) |
|---|---|---|
| Bonus rules dropped (unmapped category) | 176 / 500 (104 cards) | |
| Unrestricted accelerators | 98 rules / 74 cards | |
| Caps linked to nothing | 238 / 641 | |
| Caps with post-cap 0 | 428 | |
| Milestones on the wrong anchor | 292 / 292 | |
| Spend-gated lounges structured | 0 / 124 | |
| Co-brand cards with a merchant rule | 8 / 74 | |
| Cards Verified | 0 | |

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
| 2026-11-06 | D10: cards switch to the v2 engine only when re-imported by the v2 loader (DB defaults alone never switch a card), so existing cards keep today's behaviour until re-import. | Lead |

## Changelog

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
