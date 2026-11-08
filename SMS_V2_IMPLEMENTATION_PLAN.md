# SMS v2: implementation plan to finish the build

**Created:** 5 Nov 2026. Progress is tracked in `SMS_V2_STATUS.md`.
**Status, 8 Nov 2026: complete.** Waves 1 and 2 are merged, the release work in wave 3 is done, and production runs SMS v2 only since 6 Nov. What remains are owner steps and the items in `SMS_V2_STATUS.md` section 0. The plan below is kept as the record of how the build was organised.
**Goal:** finish every item that is code, so the only things left are owner steps (keys, real phone, approvals, deploy, testers) and the final cleanup.
**Base:** `sms-v2/claude-lanes` (`1baab86`). Each agent works on its own local branch and owns its own files. Nothing is pushed.

## Rules for every agent

- Own only your files. Anything else becomes a request file under `docs/sms-pipeline-v2/requests/`.
- Failing test first, then the fix. General rules only: no real names, numbers or amounts.
- Private data stays under `/tmp/pandapay-real-sms.a1N9hk/` (read-only, never committed, never pasted into docs).
- Gates for every rules lane: lint clean, all examples pass, golden gate, regex parity, Dart tests, no row that was correct becomes wrong.
- Local only: no push, deploy, flag change, or Gmail changes.

## Wave 1: build (ten agents in parallel)

| Lane | Backlog | What | Owns | Done when |
| --- | --- | --- | --- | --- |
| H | A2 | IPO and ASBA lifecycle: application notice (with the new optional amount), hold, mandate approval, release, partial allotment, demat credit | `rules/sms/v2/ipo/` (new), `investments/ipo_asba.json` | IPO strict rows 0 of 32 to 22 or more. No IPO message counts as spending. |
| I | A3 | Brokers and investments: NSE/BSE balance reports, settlements, payable notices, Groww/Kotak/Upstox withdrawals, top-ups, dividends | `rules/sms/v2/brokers/` (new), `investments/brokers.json`, `mutual_funds.json`, `dividends.json` | Investment rows 5 of 32 to 20 or more. |
| J | A4, A8 | Refunds (initiated vs credited, merchant cancellation, wallet refund) plus money in: salary, dividends, credits from people, with synthetic salary cases | `rules/sms/v2/refunds_lane/` and `money_in/` (new), new synthetic golden cases | Refund rows 16 of 32 to 26 or more. Synthetic salary and money-in cases pass. |
| K | A1, A9 | Fair measurement: weighted by family population, scorer reading fixes (`$` as USD, `payment_request`, `not_financial`, receipt and statement mapping), a committed full-pipeline replay harness that skips unless a private folder is set | `tools/sms_rules_cli/tool/score_private.dart` and tests, new replay harness | Reports totals-correct, false counts and per-feature event fidelity, not only strict agreement. |
| L | A7 | Noise sweep and sender registry: ignore rules for OTP, promo, service and delivery messages, and the seven unregistered sender handles | `ignore_rules.json`, new sender files | Financial unknown rate from 32% toward 5%. No financial row ignored. |
| M | D2 | Refund category on the wire (CCR-003): optional category on refund ledger rows copied from the linked purchase; remove the local-only workaround | `contracts/sms/v2/`, ledger and store files | Cross-device refund totals identical. Contract tests pass. |
| N | P5 | Phone reports sync errors and migration failures to the server so the go/no-go metrics become real | new client-metrics files plus one registration line each side | Metrics endpoint shows real values, not "unavailable". |
| O | P4 | Security audit (OWASP mobile checker, API review) of the v2 app and server, with fixes for high findings | findings doc plus fixes limited to security-relevant files | No open high finding. |
| P | M1, M5 | Performance benchmark (20,000 messages: time and memory) and a cross-device projection test (two stores, same facts, same totals); fix hot spots if found | new benchmark and test files | Numbers measured and recorded. Budgets met or hot spots fixed. |
| Q | A10 | Generalisation beyond one user's banks: synthetic rules and golden cases for the top issuers, wallets, brokers and billers | `rules/sms/v2/generalization/` (new), new golden cases | Each family has at least one rule and case for the main issuers. |

## Wave 2: integrate and re-measure

1. Merge every lane into one staging branch. Lint all rules together; resolve shadowing.
2. Merge Codex's latest commits.
3. Re-run every suite: domain, rules tool, golden gate, parity, server, full app flag off and on.
4. Re-score the private sample (strict agreement, totals-correct, false counts) and replay the full corpus (double counts, review rate).
5. Fix whatever the replay shows, in a second round of small lanes.

## Wave 3: release engineering (after accuracy is acceptable)

- Refresh a cleaned copy of the integration branch (private counts removed) and push to `sms-v2/integration` once you approve.
- Update the dark-deploy runbook with final migration list and checks.
- WP-17 cleanup runs only after the tester period: remove the flag, delete old parsers, set the legacy cutoff.

## Not code (owner steps)

Production signing key, App Check registration, consent wording, cutoff date, tester list, real-phone checks, your history dry-run, production backup restore, approvals, deploy, tester period, staged rollout.
