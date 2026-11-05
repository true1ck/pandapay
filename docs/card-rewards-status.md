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
| WP3 | Dart engine v2 + tolerant parsing | 1 | `card-rewards/wp3-dart-engine` | running | 2026-11-05 | |
| WP4 | JS engine v2 + merchant resolver | 1 | `card-rewards/wp4-js-engine` | running | 2026-11-05 | |
| WP5 | Merchant and platform directory data | 1 | `card-rewards/wp5-directory` | **merged** | 2026-11-06 | 164 merchants (9 true sub-brand parents, `group` tags per D6), 61 platforms; review + 1 fix round clean; IHCL brands kept under `taj` (ruling in ledger) |
| WP6a | Worked examples: HDFC, SBI Card | 1 | `card-rewards/wp6a-examples-hdfc-sbi` | running (9/21 cards done) | 2026-11-06 | Found CardPipeline errors (Infinia/Swiggy/Tata Neu caps, SmartBuy split, Tata Neu rounding, Millennia points, IndianOil exclusions) → contract D7/D8 |
| WP6b | Worked examples: ICICI, Axis, Amex, IDFC, others | 1 | `card-rewards/wp6b-examples-others` | running | 2026-11-05 | |
| WP7 | Integration: worked examples through both engines | 2 | — | not started | | Needs wave 1 merged |
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

## Changelog

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
