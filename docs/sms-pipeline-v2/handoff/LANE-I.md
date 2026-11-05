# Lane I handoff: brokers and investments

Branch `sms-v2/lane-i-brokers`, from `sms-v2/claude-lanes` (1baab86). Local only: nothing pushed, deployed or flagged. No Gmail, scorer, contract, ignore-rule or other-lane file was touched. The three owned files under `rules/sms/v2/investments/` needed no change.

## What was added

New folder `rules/sms/v2/brokers/`, six files, 20 rules, 40 examples (each rule has a positive and a negative synthetic example). Bundle totals: 809 rules and 1,676 examples before, 829 and 1,717 after.

| File | Rules | Covers |
| --- | --- | --- |
| `exchange_reports.json` | 2 | NSE and BSE broker fund-balance reports. A zero or positive balance is `balance_snapshot` `available_balance`. A negative balance (user owes the broker) is `outstanding` with the absolute value. Both on a broker instrument, issuer from the broker name, never money. Dates in `dd-MM-yy(yy)` with `-` or `/`. |
| `payouts.json` | 4 | Settlement and withdrawal payouts to the bank: a successful transfer notice is `movement` credit, purpose `investment`, bank account mask, broker counterparty, UTR in `references.txnId`. "Payout processed" and "we will settle your account and credit" are `attempt` `pending` credit. A generic "transferred to your bank account" notice from registered broker senders is a movement. |
| `dividends_nach.json` | 5 | NACH dividend credits at the bank: dividend wording (with and without the balance twin), a generic NACH credit from a company (lower confidence, excludes salary, refund, pension, subsidy, tax and similar), and a narrative variant. `movement` credit, purpose `dividend`, rail `nach`. |
| `demat.json` | 4 | Depository debit and credit notices (shares, not money): `info` `service`. The credit rule rejects IPO and FPO allotments, which belong to the IPO lane. |
| `topups.json` | 2 | Bank "Sent Rs ... To broker or fund" debit as an investment top-up (UPI), and a NACH debit to a clearing corporation or mutual-fund SIP. |
| `mutual_funds.json` | 3 | Fund-house lump-sum received, SIP instalment debited, and units-allotted-at-NAV confirmations, all `evidenceOnly` (the bank debit is the money). |

Existing broker, mutual-fund and dividend rules were left as they are. The existing UPI, VPA, "trf to" and "; X credited" top-up rules already cover the bank debits in the sample. The "payable to you" notice is already an informational ignore (never a movement); only its printed amount is lost (request 1).

Rule ids start `BRK-`. Mutual-fund wording had no real example in the sample or corpus, so those three rules and the NACH-SIP debit use synthetic wording and are candidates for replacement once real messages exist.

## Private draft-sample scores (strict agreement, sure rows)

| Family | Before | After | Rows |
| --- | --- | --- | --- |
| investment | 5 | 31 | 32 |
| other | 17 | 19 | 31 |
| attempt, card_bill, ipo, movement, refund, rewards_limits, salary, security, subscription, wallet | unchanged | unchanged | 235 |
| all sure rows | 174 | 202 | 316 |

0 regressions: no row that agreed before disagrees now. The one remaining investment miss is an IPO no-allotment notice labelled with a reading the scorer cannot produce (IPO lane). Two `other` rows (broker balance reports) are fixed by the new reports rule. A demat debit row in `movement` now produces a fact, but its draft reading (`demat_movement`) cannot be produced by the scorer, so its agreement is unchanged (request 2).

Corpus effect (private corpus, engine only): more messages matched and fewer stayed unknown. Every changed message moved from unknown or from the intended baseline rule, and nothing that matched before was lost.

## Decisions and caveats

- A payout notice from the broker is a counted movement because the draft label expects it. The bank's own credit alert is also a counted movement, so the same withdrawal can be counted twice until the linker has a duplicate-notice rule for credits (request 4). The UTR is carried in `references.txnId` for that join.
- Exchange reports use `issuerSlugFrom` on the first word of the printed broker name, so unknown brokers are still read. Slugs for multi-word brands can differ from the registry slug (request 6).
- A negative fund balance is held as `outstanding` because balances cannot be negative (request 3).
- Dividend masks are cut to the last four digits so they match the same account's UPI alerts. The generic NACH dividend rule can in theory read a non-dividend NACH credit from a company; its reject list and 0.7 confidence limit this, and the narrow dividend-keyword rules sit higher.
- Rule examples use fictional names. A few examples keep a real broker or fund keyword in the sender id or in the broker-name alternation the rule needs to match.

## Checks run

- `lint --rules ../../rules/sms/v2`: clean.
- `build`: 829 rules, 29 ignore rules, 148 senders, 1,717 examples, all OK.
- `dart run tool/check_pipeline.dart`: 115 cases and 15 scenarios, ok.
- `node test/regex_parity.mjs`: 51,510 comparisons, 0 mismatches.
- `tools/sms_rules_cli` `dart test`: 41 passed. `packages/pandapay_domain` `dart test`: 1,029 passed.
- Private scoring and corpus comparison done under `/tmp` only; no message text is in the repository.

## Requests

`docs/sms-pipeline-v2/requests/LANE-I-shared-files.md`: ignore-rule scope for the payable notice, scorer readings, negative broker balance, payout duplicate linking, sender registry entries, canonical broker slug.
