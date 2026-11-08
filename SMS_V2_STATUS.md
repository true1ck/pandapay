# SMS v2: status tracker

**Last updated:** 8 Nov 2026. Section 0 is current; section 1 onwards is the 5 Nov snapshot on a private sample, kept for history.
**Privacy:** it contains evaluation numbers from the owner's private message sample (totals only, no messages). Claude keeps it up to date as work progresses.

Percentages are estimates from test results and agent reports. Accuracy numbers are measured on the 327-message private sample against draft labels written by Claude, so they are agreement with those labels, not independent accuracy.

## 0. Update, 8 Nov 2026

SMS v2 is the only pipeline and has been live in production since 6 Nov 2026. All waves in `SMS_V2_IMPLEMENTATION_PLAN.md` are merged.

- **Code:** `master` (was `latest-dev`) on GitHub was at `4112b13` (pushed 8 Nov 2026, 11 commits on top of the merge with 67 commits from other sessions: Splits, the SMS AI drafts worker, performance work). Since 9 Nov 2026 `latest-dev` is renamed `master` (the integration branch, tests only) and production deploys from the `prod` branch: a push to `prod` runs Build and test and then deploys on its own.
- **Production:** cut over to SMS v2 only on 6 Nov 2026 (new product database, feature flags set, minimum app version 1.0.17). Signed rule bundles 9 to 12 are live since 8 Nov 2026 (1,140 rules, 125 ignore rules, 154 merchant aliases; cohorts all, 25%, 5%, testers) and renew hourly. They add 41 rules, 26 ignore rules and 16 aliases to bundles 5 to 8.
- **App:** build 1.0.17 (142) is installed on the owner's iPhone. Since 6 Nov it adds: a "Refresh rules and re-sort" button; a fix so records the server refuses for good no longer block the re-sort; earlier "ignored" messages are read again when they arrive again; a checklist after an edit (choose which other transactions to change, nothing ticked for type or payment-method changes); a Save confirmation; "Transfer between my accounts" and "Credit card bill payment" actions; a "Transfer type" choice in Edit; a searchable, grouped category picker.
- **Rule edits not yet live:** the server import adds only new rule ids, so 188 edits to existing rules in the repo (among them four Union Bank rules) are in no bundle yet. Each needs a new version published from the admin console or by a script.

- **Replay of six months of the owner's real bank messages** (8 May to 8 Nov, 2,613 messages read from the Mac's synced Messages, counts only, nothing stored in the repo) through the real phone pipeline with the 1,099 repo rules: 649 transactions. Findings: (1) 11 messages from one half-day window on 3 Nov, 2 of them money, never reached the app (the iPhone Shortcut did not return them; cause unknown); (2) 43 messages the phone had marked "ignored" are counted by today's rules (5 card spends and 38 small cashbacks and refunds), because the old keyword gate called them promotions and an ignored decision was final (fixed in the app in `dfe5d07`); (3) about 11 messages are real rule gaps (foreign-currency card spend, small card spend, income-tax challan payments, Airtel recharges, wallet payments); (4) merchant names split by processor prefixes and cut-offs (Swiggy under 10 names, Amazon under 7, MakeMyTrip under 3), now merged by the new aliases.
- **Not yet checked:** the "Needs review" count on the phone (the app database is encrypted, so it cannot be read from the Mac); why the Shortcut missed the 3 Nov window; whether payments to the owner's own name become transfers automatically (needs the profile name set).

Tests on `4112b13`: app 3,242 passed; domain 2,127 passed; rules lint clean.

## 1. Headline

All wave 1, 2 and 3 lanes (H to W) are merged into `sms-v2/claude-lanes` (`03d1319`). Measured by me on the private sample with the lane K scorer, whole phone-pipeline replay:

| Measure (confident rows, 316) | Before wave 1 | Now | Target |
| --- | --- | --- | --- |
| Accuracy, weighted to the whole inbox | 68.8% | **94.4%** | 95% |
| Accuracy, unweighted (303 of 316 rows) | 59.5% | **95.9%** | 95% |
| Totals-correct on rows that change totals | 92.9% | **98.2%** (weighted 99.8%) | 95%+ |
| False counts (messages that must not change totals) | 0% | **0 of 260** | 0 |
| Financial unknown rate, weighted | 7.4% | **1.8%** | 5% or less |

Including the 11 rows I marked unsure: weighted 91.9%, unweighted 93.3%, false counts 0.37% (the one row is an unsure label).

Labels are Claude's draft, so these are agreement with draft labels, not independent accuracy. The sample is drawn from one person's inbox.

| Family (confident rows) | Now |
| --- | --- |
| Wallet, investments, IPO, security, rewards and limits | all complete (32/32, 32/32, 32/32, 32/32, 23/23) |
| Salary (synthetic spam rows) | 2 of 2 |
| Refunds | 30 of 32 |
| Movement | 29 of 30 |
| Other | 29 of 31 |
| Card bills | 28 of 30 |
| Attempts | 9 of 10 |
| **Subscriptions** | **25 of 30 (weakest)** |

Event fidelity: IPO 40 of 45, investments 34 of 34, subscriptions 8 of 9, refunds 29 of 31.

| Other numbers | Value |
| --- | --- |
| Code built | about 95% |
| Ready to ship | about 75% |
| Deployed anywhere | No |
| Pushed to GitHub | Only the older `sms-v2/integration`. Nothing from these lanes. |

## 2. Where the code is

| Branch | Commit | What it is |
| --- | --- | --- |
| `sms-v2/claude-lanes` (local) | `03d1319` | Codex's tip plus lanes A to W. Not pushed. |
| `codex/sms-v2-wp14` and `sms-v2/main` (local) | `dc76789` | Codex's working line. |
| `origin/sms-v2/integration` (GitHub) | pushed 5 Nov ~11:45 | **Cleaned copy of everything**: all lanes A to W, Codex's work, and your two new commits from `codex/ios-shortcuts-prototype` (console overview, status page, monitoring). For your developer. Nothing deploys from `sms-v2/*`. |
| `origin/codex/ios-shortcuts-prototype` (GitHub) | `31bbd88` | The remote working branch. You pushed 2 new commits today (10:44 and 01:25). The deploy workflow was skipped (no marker). Untouched by me. |
| Your own folder | `codex/ios-shortcuts-prototype` at `234ef00` | 18 commits behind the remote, 111 uncommitted files. |

## 3. Checks on `sms-v2/claude-lanes`

| Suite | Result |
| --- | --- |
| Shared Dart package | 1,077 pass (on `03d1319`) |
| Rules tool | 244 pass, rules lint clean, golden gate passes (239 cases, 26 scenarios) (on `03d1319`) |
| Regex parity (Dart vs Node) | 145,584 comparisons, 0 mismatches |
| Server | 1,437 pass, 0 fail, 4 skipped (re-run on `ea837c1`) |
| Full app, v2 on | 3,063 pass, 8 skipped, 0 fail on the pushed `9ebe7fe` (all lanes plus your two remote commits) |
| Full app, v2 off | Not re-run on the merged branch (lane G ran it before the merge: 2,951 pass) |
| Local rig end to end on the merged code (scratch DB): 973 rules imported, 4 signed cohorts, HTTPS OTP login, signed rules fetch, tamper rejection, fact upload and sync | Passed |
| Real phone, real server, real SMS | Not done |

## 4. Phases

| Phase | Covers | Done |
| --- | --- | --- |
| 1. Test on your iPhone | Rig, test key, build, Shortcut, screens | 88% |
| 2. Accuracy | Rules and measurement | 88% |
| 3. Decisions | Contract and product choices | 40% |
| 4. Server readiness | Runbook, bundle pipeline, security, metrics | 83% |
| 5. Phone readiness | Real-device speed, review, dry-run | 68% |
| 6. Release and cleanup | Testers, rollout, WP-17 | 31% |

## 5. Items

| ID | Item | Done | What is left | Owner |
| --- | --- | --- | --- | --- |
| T1-T3 | Local rig, test key, iPhone build | 100% | Rebuild the iPhone app from the merged code to test it | Codex script, you |
| T4 | Shortcut intake with tagged senders | 70% | Real Shortcut automation on the phone | You |
| T5 | Screens populated with data | 70% | Verified from replays (lane V). Real-device check left. | You |
| A1 | Fair measurement | 95% | Done. Labels are still drafts: review them. | You |
| A2 | IPO family | 95% | 32 of 32 rows. Hold labels need a product decision. | Done |
| A3 | Brokers | 95% | 32 of 32 rows. Broker-owned bank account quirk. | Done |
| A4 | Refunds | 90% | 30 of 32. Two need contract changes. | Done |
| A5 | Subscriptions and bills | 80% | 25 of 30 (weakest). Rest need contract changes or label decisions. | Open |
| A6 | Wallet, card, UPI mismatches | 90% | Wallet 32/32, movement 29/30 | Done |
| A7 | Noise sweep | 90% | Unknown rate 1.8% weighted | Done |
| A8 | Money in and salary | 80% | Payer capture done. Salary is synthetic only. | Open |
| A9 | Full-corpus replay | 85% | Replay harness built and run. Real-world double counts not provable. | Open |
| A10 | Generalise to other users' banks | 75% | 87 rules, no real messages behind them. About 45 sender handles unverified. | Open |
| D1 | Optional amount on info facts | 100% | Done (CCR-002) | Done |
| D2 | Refund category on the wire | 100% | Done (CCR-003). Server must deploy before phones. | Done |
| D3 | Consent wording and store disclosures | 0% | Your text | You |
| D4 | Legacy-route cutoff date | 0% | Your choice (plan proposes 8 weeks) | You |
| D5 | Tester list and who reviews corrections | 0% | Your list | You |
| P1 | Migration rehearsal | 55% | Scratch data done. Restored production copy needed. | You + Codex |
| P2 | Dark-deploy runbook | 90% | Your approvals, production-data dry run | You |
| P3 | Bundle release pipeline | 90% | Production key | You |
| P4 | Security | 85% | LO-11 (your decision), App Check registration, limited-use wiring | You |
| P5 | Go/no-go metrics | 95% | Built, with minimum sample size | Done |
| M1 | Real-device speed | 55% | 20,000 messages in 43 s on desktop (was 85-124 s). Phone run needed. | You |
| M2 | Final review, native acceptance | 75% | Final review items | Codex |
| M3 | Your history dry-run | 40% | Run it on your phone, review | You |
| M4 | Old-app compatibility | 80% | Server fixed and tested. Real-phone old-build check left. | You |
| M5 | Cross-device (Android + iPhone) | 90% | Tested with two stores. Real devices left. | You |
| R1 | Tester build, 7 days | 0% | Not started | You |
| R2 | Staged rollout | 0% | Not started | You |
| R3 | WP-17 cleanup | 25% | Deletion check and 426 gate exist. Nothing deleted. | Later |
| R4 | Hard-coded logic guard | 100% | Done | Done |

## 6. Lanes run this session (all merged into `sms-v2/claude-lanes`)

| Lane | What | Result |
| --- | --- | --- |
| A | Subscription, mandate, bill, attempt rules | 31 rules. Subscriptions 8 to 12 of 30. |
| B | Wallet, card and UPI rules | 26 rules. Wallets 17 to 31 of 32. |
| C | Metrics endpoint, legacy 426 gate, release-bundle script | Done. Sync-error and migration-failure metrics need phone reporting. |
| D | Dark-deploy runbook, old-app compat tests, hard-coded guard, deletion check | Found 2 compat bugs (fixed by lane G). |
| E | Optional amount on info facts | Done. |
| F | Linker bug: debit under a mandate dropped from totals | Fixed. |
| G | Old-app fixes plus the app sending a version header | Done. |

## 6b. Wave 1 lanes (all done and merged into `a8a9560`)

| Lane | What | State |
| --- | --- | --- |
| H | IPO and ASBA rules | Done (`c14a6d2`). IPO 0 to 16 of 32 with the old scorer (32 of 32 with the table lane K built). Not yet merged. |
| I | Brokers and investments rules | Done (`0356083`). Investments 5 to 31 of 32. Not yet merged. |
| J | Refunds and money-in rules | Done (`f92ad14`). 29 rules, 34 golden cases, 3 scenarios. Not yet merged. |
| K | Fair scorer and replay harness | Done (`adea521`). Not yet merged. |
| L | Noise sweep and sender registry | Done (`8e0ee5a`). Corpus unknown 31% to 16%. Not yet merged. |
| M | Refund category on the wire (CCR-003) | Done (`c527a6f`). Not yet merged. |
| N | Phone reports sync and migration metrics | Done (`4413fdb`). Not yet merged. |
| O | Security audit and fixes | Done (`87432ad`). 3 HIGH and 4 MEDIUM fixed. 3 MEDIUM, 4 LOW still open. Not yet merged. |
| P | Performance and cross-device tests | Done and merged |
| Q | Generalise beyond one user's banks | Done (`2f903f8`). 87 rules, 68 golden cases. Not yet merged. |

## 6c. Wave 2 lanes (running, launched 5 Nov 03:58)

| Lane | What | State |
| --- | --- | --- |
| R | Release plumbing: engine version bump and `minEngineVersion`, lint rejects aliases in sender lists, minimum sample size for go/no-go, test lists, derived copies | Done (`aa61e00`). Not yet merged. |
| S | Linker: IPO batch vs sequential linking, partial-allotment and broker-payout double counts | Done (`321598d`) and merged. |
| T | Remaining rule gaps: refunds (18 of 32), subscriptions, card bills, filed rule fixes | Done (`bd58bfd`) and merged. |
| U | Security follow-ups: pre-sign rule bundles (LO-09), bind App Check to account (LO-10), key revocation runbook | Done (`8da6aef`). Not yet merged. |
| V | Product screens: verify Investments, IPO applications, Money in, Subscriptions, card bills from real pipeline fixtures; fix bugs | Done (`1825328`) and merged. All five screens verified, 9 bugs fixed. |

## 6d. Wave 3 lane (running, launched 5 Nov 07:05)

| Lane | What | State |
| --- | --- | --- |
| W | Payer names on credits, investment withdrawal events, processed-vs-failed standing instructions, non-IPO mandates, missing broker messages, scorer reading table for IPO holds | Done (`03d1319`) and merged. |

## 6e. Lane X (done, merged locally into the publish branch, not pushed)

Bill-payment receipt with no funding debit (your Kiwi decision): earlier month is skipped silently; current month, after 3 days, asks once "Did you pay this bill?" with Yes / No / Not sure; counts once as a card payment if you say yes; resolves itself if the debit arrives. Domain 1,099 pass, rules tool 244 pass, app sms_v2 374 pass (flag off and on).
Open choices: limit the question to card-bill receipts only? "Not sure" has no snooze. App name comes from the sender slug ("Kiwi"). Late debit after "Yes" is attributed to the account you chose.

## 7. Open items for Codex (filed by the lanes)

- Scorer: treat `$` as USD, recognise the new collect-request rules, let ignored notices read as `not_financial`, map receipts and statements.
- Sender registry: seven sender handles are not registered.
- IPO and broker rules using the new optional amount.
- Two Kiwi card-bill receipts: decide whether the label or the contract changes.

## 7b. Follow-ups from lane H (to do at merge)

- Bump `smsEngineVersion` and add a `meta.json` with `minEngineVersion` before release, because three IPO rules emit the new `amountMinor`.
- Fix the ignore rule that swallows the BSE "application submitted" notice (lane L owns the ignore file).
- Linker decision: a partial allotment could count twice if the bank's own debit alert arrives more than about 10 minutes after the registrar's.

## 7c. Follow-ups from lane M (to do at merge)

- Deploy order: server first, then phones. An old server rejects refund rows that carry a category.
- Old phones: the server hides a refund's category unless the client sends `X-Sms-Contract-Features: refund-category`. Confirm you accept this behaviour.
- The server's stored refund row keeps the old category until the phone re-pushes after another device recategorises the purchase. Totals stay correct.

## 7d. Follow-ups from lane N (to do at merge)

- Add the new SQL test and `client_metrics_pg.test.js`, and lane C's metrics tests, to `tests/admin_console_security/full_schema.test.js`.
- Add a minimum sample size so an early "go" can't be reported from a handful of phones.
- Only the automatic first-run migration is counted, not the user-started history update.
- New migration `20261113100000` sits after lane C's `20261112210000`. Order is fine.

## 7e. Follow-ups from lane I (to do at merge)

- Linker: add a duplicate-notice link rule so a broker payout notice and the bank's credit alert are not both counted as a withdrawal.
- Narrow or retire the ignore rule `IGN-BROKER-PAYABLE-TRADES` (it loses the printed amount). Ready rule is in the request file.
- Decide how to store a negative broker balance (stored as `outstanding` with the absolute value for now).
- Mutual-fund rules use synthetic wording (no real examples in the sample).
- Register the broker payout, exchange and depository sender handles.

## 7f. Security audit (lane O): still open

- **LO-11 MEDIUM, needs your decision:** raw SMS text sits in a plain SQLite file (`pandapay.sqlite`) in the iOS Documents folder, which is included in device backups. The app uses `sqlite3` with `sqlite3_flutter_libs`, not an encrypted build. Codex's WP-06 note called it an "existing encrypted financial database", which does not match. Options: exclude the file from backups, encrypt it (SQLCipher), or store less raw text.
- **LO-09 MEDIUM:** the rule signing key lives in the public API process and signs on every request. Recommendation: pre-sign bundles in the hourly admin job.
- **LO-10 MEDIUM:** App Check tokens are not bound to the account or device. Add limited-use tokens before switching to enforce mode.
- LOW: no certificate pinning, a leaked rule key needs an app release to revoke, no match timeout for stacked quantifiers, debug App Check tokens accepted if registered in production.
- Full report: `docs/sms-pipeline-v2/security-audit-2026-11.md` (on lane O's branch).

## 7g. Follow-ups from lane J (to do at merge)

- Re-measure with lane K's scorer: lane J's pending-refund rules only score fully once the scorer reads a non-scheduled attempt as a pending refund.
- A refund or cancellation notice with no printed amount cannot be an `attempt` under the frozen contract.
- Existing rules `GEN-REFUND-NOMASK` and `GEN-REFUND-PENDING` overlap lane J's rules. `GEN-REFUND-NOMASK` misreads "initiated and will be credited" as money back.
- Generic salary rules capture no payer, which salary detection needs.
- Lane J edited `tools/sms_rules_cli/test/shared_golden_parity_test.dart` to compare against the loaded golden set instead of fixed counts. Other lanes' golden cases then stop breaking it.

## 7h. Follow-ups from lane L (to do at merge)

- Engine trap: an ignore rule's `senders` matches the canonical brand only, but lint accepts aliases. Make lint reject aliases in rule `senders` so a rule cannot silently never fire.
- Rules still needed for a biller's UPI-Mandate collect request and the BSE advance notice (now unknown, no longer swallowed).
- Load `tools/sms_golden/ignore_examples/*.json` into the golden runner (lane L added examples and a test for them).
- Demat debit notices were not ignored because the draft label treats them as a sure demat movement.

## 7i. Follow-ups from lane Q (to do at merge)

- Test `shared_golden_parity_test.dart` hard-codes 115 golden cases (lane J already changed it to compare against the loaded set; keep that).
- Refresh the derived copies `console/assets/sms_golden/bundle.json` and the baseline bundle after merge.
- About 45 candidate sender handles to register. All unverified guesses. Five rules use a wildcard sender with an anchored word until registered.
- Findings for other rules: Bank of Baroda IMPS credits with a 12-digit reference read as UPI person-to-person; `INV-BROKER-WITHDRAW-CREDIT-02` reads ICICI Direct, HDFC Securities and Kotak Securities "credited to your trading account" as a withdrawal; some SBI and IDFC refund wordings unmatched; a bank debit ending "failed" reads as a movement; Axis EMI/LOAN debits fall to the last-resort rule.

## 7j. Notes from lane R (to do at merge)

- Engine is now 2.1.0 and `rules/sms/v2/meta.json` requires it. **Release order: the app carrying engine 2.1.0 must ship before the first bundle built from these rules is published.** Phones on 2.0.x will refuse it and keep their last bundle.
- New lint error `lint.sender.alias`. Six rules used alias handles that never fired; they now use the canonical brand.
- Go/no-go needs at least 20 devices and 200 sync runs. The server currently counts device-days, so the device count is a lower bound. The SQL report should add `count(DISTINCT device_digest)`.
- `console/assets/sms_golden/bundle.json` regenerated. The shipped baseline in the app stays the empty version-0 placeholder on purpose.
- Lane R blamed the failing app test on stale hard-coded counts. That is wrong: the test compares batch against one-at-a-time capture, and the batch really produces 3 ambiguous refund events. Lane S owns the fix.

## 7k. Notes from lane U (to do at merge and deploy)

- The public API no longer holds the rule signing key. Deploy order: apply migrations `20261114100000` and `20261114110000`, run `run_sms_v2_rule_jobs.js` once on the maintenance host, deploy the API, then remove `SMS_RULES_SIGNING_KEY` from the API environment. Until the job has run, `/sms/v2/rules` answers 503.
- The hourly job must run and be alerted on. An unrefreshed bundle expires after 7 days and the API then fails closed.
- App Check tokens are now bound to the first account and install that presents them. Limited-use replay protection is built but off. Do not turn it on until `limitedUseHeaders()` is wired into the app's sync headers.
- Small edits overlap with the rules store and route files; check at merge. The new `sms_v2_bundles.served_body` column is part of the migration.

## 7l. Follow-ups from lane V (a rules and linker lane is needed)

- Rules: payer names are missing on IMPS, dividend, refund and UPI person credits (salary detection needs them). ICICI "mandate raised by <non-IPO company>" gives no subscription mandate. Zerodha funds-added and NSE fund-balance messages produced no facts in a probe (may be sender registration).
- Linker: an Upstox withdrawal produces no `investment_withdrawal` event. A processed card standing instruction becomes a plain purchase, so a failed one cannot attach to its service.
- The batch vs one-at-a-time refund failure (lane S).
- Screens were verified from replayed golden scenarios, not on a real phone.

## 8. Decisions waiting on you

| Decision | Recommendation |
| --- | --- |
| Combine with Codex's latest, clean private counts, push `sms-v2/integration` | Yes. A `sms-v2/*` push deploys nothing. |
| D2: refund category on the wire | Add an optional category on refund rows, copied from the linked purchase |
| Version header format | Set the first v2 version as `x.y.z+build` |
| Store-account payments count as spending | Confirm (risk: double count if its top-up is also spending) |
| Wallet credits with an expiry read as cashback, not refunds | Confirm |

## 9. Known risks

- The rig account uses the fixed code `1234` on your Wi-Fi. Stop the rig when not testing.
- Remove any "PandaPay SMS v2 local test CA" profile from your iPhone (Settings, General, VPN and Device Management).
- A rule update does not re-read history that was already matched. Reinterpreting past facts needs a replacement protocol that does not exist yet.
- The shared production host serves live Android users. Pushing `master`, or pushing `codex/ios-shortcuts-prototype` with `[deploy-prod]` in the last commit message, deploys. `sms-v2/*` pushes do not.
- Two database enum additions (`refund`, `superseded`) cannot be undone.

## 10. Change log

| Date | Change |
| --- | --- |
| 5 Nov (fresh-start Phase 0) | Owner confirmed the fresh-start plan (`docs/superpowers/plans/2026-11-05-fresh-start-release.md`). Phase 0 done locally, nothing pushed: main-checkout changes saved on `rescue/main-checkout-2026-11-05`; local `sms-v2/integration` (worktree `../pandapay-integration`) = origin `48df9ca` + lane X + login/auth feedback, live alert status, iOS import progress and Android lanes (`ae342a9`). Foreign-payments and docs drafts in the checkout were older than integration and not taken. 34 merged agent worktrees and 53 merged local branches removed. Server 1,552 pass, auth 375 pass. |
| 5 Nov 12:20 | Lane X done: receipt-without-payment question (your Kiwi decision). Merged into the local publish branch (`1448435`); not pushed yet. Full app suite on pushed `9ebe7fe`: 3,063 pass, 0 fail. |
| 5 Nov 11:50 | Pushed the cleaned `sms-v2/integration`. Before pushing I replaced real UPI reference numbers and card endings that had leaked from the private sample into 9 test and rule files, and removed corpus counts from 5 docs. Merged your two new remote commits. Server 1,453 pass, console 91 pass. Built and installed the merged app on your iPhone (build 110): installed, but could not launch because the phone was locked. |
| 5 Nov 08:15 | Final full app suite on `03d1319`: 3,057 pass, 0 fail. Local rig end-to-end check passed on the merged code. |
| 5 Nov 07:50 | Lane W done and merged (`03d1319`). Rules 973, examples 2,022, golden 239 cases and 26 scenarios. Measured by me: weighted accuracy 94.4%, unweighted 95.9% (303 of 316), totals-correct 98.2% (weighted 99.8%), false counts 0, financial unknown 1.8%. Full app suite re-running on the final branch. |
| 5 Nov 07:05 | Lane S done and merged: batch vs one-at-a-time linking was partly a test-harness bug (source keys) and partly real order sensitivity, now fixed with property tests. Two new double-count link rules. Lane V merged. Launched lane W. Full server suite green on `ea837c1`. |
| 5 Nov 06:32 | Lane V done: Investments, IPO applications, Money in, Subscriptions and card payments verified from pipeline replays. 9 screen bugs fixed (subscription split by card, salary UTC/IST month boundary, no-payer credits called salary, IPO screen missing date and status, and more). |
| 5 Nov 06:20 | Lanes R, U, T merged, plus a scorer fix (pending refund reads as refund_initiated). Rules: 966, 2,002 examples, golden 225 cases and 18 scenarios. Weighted accuracy 92.8%, unweighted 93.4%, totals-correct 98.2% (weighted 99.8%), false counts 0, financial unknown 2.3%. Lanes S and V still running. |
| 5 Nov 05:56 | Lanes R and U done. Engine bumped to 2.1.0. Rule bundles are now pre-signed by the maintenance job. App Check bound to account. |
| 5 Nov 05:36 | Usage limit stopped all five wave-2 agents at about 04:00. Resumed them after the 05:30 reset. Full app suite on merged wave 1: 3,005 pass, 1 fail (batch vs sequential linking differs on refunds). Added to lane S. |
| 5 Nov 04:00 | All wave-1 lanes merged (`a8a9560`) with no conflicts. Lint clean, 960 rules, golden 217 cases and 18 scenarios, parity 140,722 comparisons with 0 mismatches, domain 1,047 pass, rules tool 227 pass, server 1,437 pass. Weighted accuracy 89.5%, totals-correct 99.8%, false counts 0, financial unknown 3.4%. Launched wave 2 (lanes R to V). Full app suite running. |
| 5 Nov 03:12 | Lane Q done: 87 generalisation rules, 68 golden cases (golden set now 183 cases). Statements, insurance, utilities, wallets, SIP, ATM, limits, EMI coverage up sharply. |
| 5 Nov 03:03 | Lane L done: 41 ignore rules, 74 sender entries. Corpus matched 2,064, ignored 1,518 to 2,290, unknown 1,614 to 842. |
| 5 Nov 02:52 | Lane J done: 29 refund and money-in rules, 34 golden cases, 3 scenarios (two months of salary, refund initiated then credited, UPI reversal). |
| 5 Nov 02:40 | Lane O done: security audit. 3 HIGH and 4 MEDIUM fixed. LO-11 (plain SMS database in iOS backups) needs your decision. |
| 5 Nov 02:27 | Lane I done: 20 broker and investment rules. Investment family 5 to 31 of 32 strict. |
| 5 Nov 02:20 | Lane N done: phone reports aggregate sync and migration counters. Go/no-go metrics now real. |
| 5 Nov 02:14 | Lane M done: refund category now travels on refund ledger rows (CCR-003). Two devices give identical category totals. |
| 5 Nov 02:08 | Lane H done: 15 IPO rules. IPO family 0 to 16 of 32 strict. |
| 5 Nov 01:58 | Lane K done: fair scorer plus replay harness. Weighted accuracy 68.8%, totals-correct 99.2% with replay, false counts 0%. |
| 5 Nov 01:45 | Full app suite (v2 on) passed on `sms-v2/claude-lanes`: 2,951 pass. Wrote `SMS_V2_IMPLEMENTATION_PLAN.md`. Launched wave 1: ten agents (lanes H to Q) off `1baab86`. |
| 5 Nov 01:21 | Created this file. Lanes A to G merged into `sms-v2/claude-lanes`. Full suites green. Strict agreement 43% to 55% on the sample. |
