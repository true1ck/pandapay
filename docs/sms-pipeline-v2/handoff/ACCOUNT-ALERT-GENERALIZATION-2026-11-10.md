# Account-alert generalisation (10 Nov 2026)

**Trigger:** a second person's phone had a 96-item review queue from a district co-operative bank, a teachers' credit society, SBI-style alerts, India Post and an insurer. The owner then asked the real question: does this work for any user's bank, or only for these messages, given that a missed transaction is the worst outcome.

**Answer, measured:** it did not. On alerts in layouts no rule was written for, the pipeline counted 53% correctly, parked 32% for confirmation and got about 8% silently wrong or lost. After this work the same sets score 97-100% with nothing wrong and nothing silent. Most of the gain comes from four changes to shared machinery, not from new layouts. Part of it needs an app build.

## 1. How it was measured

`tools/sms_golden/heldout/` holds three sets of synthetic alerts with the right answer (661 messages, 76 layouts, account numbers printed 32 ways) and 88 lookalikes that must count nothing (future, failed, pending, offers, OTPs, dues, warnings, holds). Each message goes alone through rules, evidence reader, instruments, linker and ledger. Each set was scored blind once, then used to fix what it showed.

| Set | First (blind) score | Final |
| --- | --- | --- |
| A (360), before any engine change | 53% counted correctly, 32% asked, 7% review, 8% silent or wrong | 100% |
| B (185), after the fixes for A | 96.8% counted, 2.7% review, 0.5% wrong, no lookalike counted | 100% |
| C (116), after the fixes for B | 83% counted (14 points with no account read), 14% review, 3.4% silent, 1 of 20 lookalikes counted | 96.6% counted, 3.4% review |
| Lookalikes (88) | up to 3 counted while fixing | 0 counted |

Set C is the honest figure for a new bank today: most alerts are counted, the rest are visible in review, and a new layout can still surprise. The sets are regression guards now; a new measurement needs a new set (the generators are in the folder).

A second audit ran every rule's own example (953 movements) through the full pipeline: 79 produced no ledger row and no question. 56 are foreign-currency spends (their own screen, by design). **23 were real silent misses**: rules that read the movement but typed its purpose `unknown` at confidence 0.9, which the ledger neither counts nor asks about. That covered every "Rs X Cr./Dr. to A/c" alert for any bank, SBI "has credit for UPI/…", ICICI cheque clearing and India Post credits. Now 0.

## 2. What was wrong, and the general fix for each

| Cause | Effect | Fix | Reaches phones by |
| --- | --- | --- | --- |
| A branch code before the account (`A/c No.40000/XXXXX913`) | about 250 generic rules did not match, or took the branch code as the account; the evidence reader read two accounts and called a debit an own transfer | the engine blanks the prefix (same length, so evidence spans hold) before any rule or the reader runs: `engine/account_token.dart` | app build |
| Weak last-resort rules (confidence 0.5-0.6, purpose unknown) win before the evidence reader gets a turn | a right reading parked in "Please confirm", never counted | **second opinion**: when a rule is unsure and the evidence reader reads the same direction, amount and account, the rule's facts are kept, the purpose and rail filled, and the reading is confident. Disagreement changes nothing | app build |
| A rule for any sender calls a real debit "information only" (`BRK-DEMAT-NSDL-DEBIT-01` read "Rs X has been debited from your a/c" as a share movement; `GEN-BALANCE-ASOF` read "Rs X Cr. to A/c … Avl Bal" as a balance) | the transaction vanished | the same second opinion overrules a wildcard information-only rule when the evidence reader accepts a completed movement; both rules also tightened | app build; the two rule edits need a version publish |
| Purpose `unknown` at high confidence | never counted, never asked | linker: a confident movement with no stated reason is money out (purchase) or money in; an unsure one stays unknown and is asked. 23 typed replacement rules do the same for phones without the build | app build; replacements by import |
| Account shown as first and last digits (`12XXXXXX89`) | first digits taken as the account | the engine takes the digits after the mask characters | app build |
| The intake gate needs a known verb | "Rs 500 Cr on …", "Cash deposit of …", "Deposit of … made" were rejected at the gate; with no matching rule the text is dropped for good | a message from a bank-style sender with an amount beside a masked account number always goes through, in any wording or language; a plain number needs a money word or a printed balance too (`intake_gate.dart`) | app build |
| Evidence reader vocabulary | "Total Avail.bal" read as an offer; a credit verb trusted less than a debit verb; "cheque", "transfer", "towards" taken as payee names; a lodged cheque, a fraud warning and a held card transaction read as money; "mutual fund" taken as proof money moved | pack v3 (data) plus one logic fix: a mandate being set up is a mandate, not a movement | pack by import; the logic fix by app build |
| `CPP-CHEQ` name pattern `^CHEQ` | any payee starting "CHEQUE" became a card-bill payment | `^CHEQ\b` | import |
| `GEN-REFUND-NOMASK` | "Refund … is being processed" counted as a refund | reject wording added | version publish |

The tier promise changed and is pinned by `solver_integration_test.dart`: a rule that is sure is never second-guessed; the evidence reader may change a rule-matched message only by corroboration (same rule, same direction, amount and account; purpose, rail and confidence change) or by overruling a wildcard information-only rule.

## 3. Rules added (89 new ids, all synthetic examples)

Generator: `tools/sms_rules_cli/tool/gen_account_alert_rules.py`. Documented in `rules/sms/v2/generalization/NOTES.md`.

- `account_alerts_account_first.json` (38): `A/c N has been credited/debited by|with Rs X [in TYPE] on DATE [. Info:] by MODE`. Cash, cheque (credit), transfer and no-mode classes sit at 195-225, under the richer `GEN-ACCT-*` rules. The rail classes (NEFT, RTGS, IMPS, UPI, interest, salary, reversal, cheque debit) require a branch code and sit above them: those richer rules already read the wording for a plain account and now, with the prefix blanked, for a branch-coded one on a new build; the classes exist for phones on the current build.
- `account_alerts_label_first.json` (5), `sbi_style_has_credit_for.json` (16), `neft_sent_notices.json` (4), `payment_thanks_receipts.json` (1).
- `typed_replacements.json` (23): typed copies of the 23 silent rules, one priority step above the rule each retires. An import never replaces an existing id, so a new id is the only way a fix reaches phones without a publish.
- `amount_first_plain_debit.json` (2): `Rs X has been debited from your A/c N [on DATE]` with nothing after it, just above the broker rule that swallowed it.
- `senders/cooperative_banks.json`; `normalizeSenderBrand` reads a header without dashes when the rest is a registered brand.
- Linker: two notices with different references are two payments, so the same amount paid again and again pairs one notice to each debit.

## 4. What an import alone gives, and what needs the build

Measured by running the new rules on the engine of the current app build (1.0.18, 144):

| | Before | Import only | Import + app build |
| --- | --- | --- | --- |
| Set A counted correctly | 53% | 65% | 100% |
| Set B | not measured | 64% | 100% |
| Set C | not measured | 66% | 96.6% |
| Asked (right, parked) | 32% | 25-31% | 0-3% |
| Wrong account digits / own transfer | 3% | 3-8% | 0 |
| The 13 reported messages | 0 counted right (2 read right but parked, 4 misread, 7 unread) | 13 right | 13 right |

So the reported messages are fixed by the import. The general gain needs the build. Three edits to existing rules (`BRK-DEMAT-NSDL-DEBIT-01`, `GEN-BALANCE-ASOF`, `GEN-REFUND-NOMASK`) reach phones only through a version publish; on a new build the second opinion covers the first two without it. The "import only" column was run with those three edits in place, so the real import-only figure is slightly lower for the layouts they touch.

## 5. Edge cases covered by tests

| Case | Result | Where |
| --- | --- | --- |
| same amount paid again and again (three days, same day twice, notices first) | each counts once; each debit gets its own notice | golden scenarios `coop_*`, `receipt_review_test.dart` |
| byte-identical texts (same sender, same text) | one message to the phone: identity is account + sender + text, never delivery time. Repeated payments differ by balance or reference | found by `runtime_scenarios_test.dart` |
| notice before or after its alert, alert only, notice only | once / once / counted / nothing | golden scenarios |
| a notice whose alert never came, beside an earlier equal payment | does not hide behind it; the question is raised | `receipt_review_test.dart` |
| 76 layouts, 32 account forms, amount and date forms, Hinglish | counted, or sent to review | `generalization_guard_test.dart` |
| 88 lookalikes | none counted | same |
| the gate lets every alert through, and still stops OTPs | yes | `app/test/.../generalization_gate_test.dart` |

## 6. Verification on the final state

- `tool/check_pipeline.dart`: lint clean, every rule example, golden 294 cases and 64 scenarios all fully passed, 0 double counts.
- Domain 2,229 pass (10,000-message benchmark 742 ms). Rules CLI 421 pass; `ignore_examples_test` fails the same way on a clean `HEAD`.
- Server-side JavaScript `lintPattern` on all 116 rules created or edited: clean.
- Five golden cases that expected purpose `unknown` (Bank of Baroda and Indian Bank "Cr./Dr." alerts, India Post credit) now expect a typed purpose. They encoded "read but not counted"; that is the behaviour that was removed.
- `minEngineVersion` stays 2.4.0.

## 7. Known limits

- A new layout can still be misread; set C shows the size of that. The safety net is that an unread alert goes to review and the learning loop, not to nowhere. Hindi or Marathi in native script is not read.
- An ambiguous card line ("POS txn of Rs X at SHOP on card N" with no word saying it completed) is sent to review on purpose: the same opening also begins "… is on hold" and "… was declined".
- Own transfers inside one bank (two own accounts, both "Transfer", same minute) count as money out plus money in. Needs a linker decision.
- A bank that sends byte-identical alerts for two real payments (no balance, no reference, same date and amount) is counted once.
- The payee on a "sent" notice does not reach the ledger (it anchors on the debit alert). A returned NEFT counts as money in unless the text says reversal, return or refund.
- Nothing here was replayed over a real inbox. The numbers are for synthetic alerts written from how Indian banks word them.
