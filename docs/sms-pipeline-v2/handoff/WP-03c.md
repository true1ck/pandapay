# WP-03c handoff: Investments, mandates, bills

Branch `sms-v2/wp-03c-investments`. Only rule JSON, two sender files, this note and one request were added. No contract, engine, Dart or Gmail file was touched.

## What was built

164 rules, 347 examples (each rule has at least one positive and one negative), 44 senders.

| File | Rules | Covers |
| --- | --- | --- |
| `investments/ipo_asba.json` | 23 | ASBA holds placed and released, allotment debits, UPI one-time mandate blocks and releases (hold plus one-time `ipo` mandate), issuer mandates ("approved the mandate of ... raised by"), NSE receipts, BSE "No allotment" |
| `investments/brokers.json` | 25 | Broker top-ups from bank messages (UPI VPA, SBI "trf to", "towards", "; X credited", Axis narrative, generic fallback), broker withdrawals back to the bank, broker own messages (funds added, payout initiated, notices, done), NSE/BSE fund-balance reports (12 brokers) |
| `investments/mutual_funds.json` | 12 | SIP and purchase receipts (evidenceOnly), units allotted, SIP registered, paused, cancelled, upcoming, failed, redemption pending and credited |
| `investments/dividends.json` | 2 | Dividend and IDCW credits |
| `bills_mandates/mandates.json` | 57 | AutoPay, UPI mandate, standing-instruction and e-NACH created, modified, paused, resumed, revoked, expired; upcoming debits (`attempt` `scheduled`); failed (`attempt` `failed`); executions (`movement` with `mandateRef`) |
| `bills_mandates/card_bills.json` | 25 | Card statements and reminders (one `bill_due` per message), zero-due statements, CRED reminders for 16 issuers |
| `bills_mandates/utility_bills.json` | 12 | Electricity, broadband, postpaid, insurance premium, loan EMI dues; biller and rent receipts (evidenceOnly) |
| `bills_mandates/pay_later.json` | 8 | Amazon Pay Later, Axio, LazyPay drawdowns, bills, scheduled debits |
| `senders/investments.json`, `senders/billers.json` | 25 + 19 | Brokers, exchanges, registrars, fund houses; telecom, utility, insurance, CRED, Pay Later senders |

Rule ids: `INV-*` (investments), `MND-*` (mandates), `BIL-*` (bills). Suffixes: `-B` twin that also emits the `Avl Bal` snapshot (priority +1), `-A` twin that also reads the account mask (+1), `-INV` twin for broker or fund-house merchants (purpose `investment` or mandate purpose `sip`, +5), `-90` low-priority fallback.

## Results

- `lint` on `rules/sms/v2` alone: clean. `build`: 164 rules, 347 examples OK. `node tools/sms_rules_cli/test/regex_parity.mjs rules/sms/v2`: 347 comparisons, 0 mismatches.
- Golden set, 03c cases (19 single messages, run with a dev-signed bundle built from this folder plus stub entries for the bank senders HDFCBK, ICICIT, AXISBK and similar, which 03a owns): capture recall 100%, amount and role 100%, instrument 100%, event kind 94.7% (18 of 19). The one miss is `corpus:autopay_failed`: it cannot be produced by any rule because an `attempt` needs an amount and the message prints none. See `requests/WP-03c-attempt-without-amount.md`. Ignored financial cases: 0.
- No other golden case (82 single messages in total) is matched by a 03c rule, so nothing is stolen from banks or wallets.
- The 15 scenarios are not scored: the linker is not available yet.

## Decisions to confirm

1. **Generic senders.** Every rule whose wording is shared (all bank-originated IPO, mandate and broker debits) uses `senders: ["*"]` and takes the issuer from the sender entry. This keeps 03c independent of 03a's `senders/banks.json`: the folder lints and builds alone. Bank-specific wording is told apart by content, not sender.
2. **Priority against 03a.** 03c rules that must beat a bank's generic debit or credit rule sit at 800-850 (IPO, broker), 700-720 (mandates) and 600-700 (bills). A 03a template at the same or higher priority that also matches these texts (HDFC `debited from A/c ... to VPA`, SBI `trf to`, ICICI `; X credited`) would win. After merging 03a, run `lint`: any `lint.shadowed` on a 03c rule means 03a should reject broker names or mandate wording, or 03c's priority goes up.
3. **Investment withdrawal.** There is no movement purpose for it. A broker or fund-house payout to the bank is `movement` `credit` with `purpose: investment` and the broker as counterparty; the linker (WP-05) and ledger (WP-06) must read that as `investment_withdrawal`. Broker-side payout messages are `attempt` `pending` `credit` (initiated) or `evidenceOnly` movement (done).
4. **Receipts never count.** Fund-house SIP and purchase confirmations, broker "funds added", biller and rent receipts, loan "EMI received" are `evidenceOnly: true`; the bank debit is the real movement.
5. **IPO.** A UPI one-time mandate block emits `hold` (`upi_mandate_block`, `placed`) plus `mandate` (`created`, `oneTime`, `mandatePurpose: ipo`) in that order. ASBA blocks and releases are `hold` only. The allotment debit is `movement` `investment`. Bank "allotment" wording has no `hold converted` fact; the debit alone is the conversion, as the scenario `ipo_block_then_allotment` expects.
6. **Zero and dateless statements.** "Total amount due Rs 0" is an `info` (service) fact. A statement with a total but no date cannot be a `bill_due` (needs `dueDate`) or an `outstanding` snapshot (needs `asOf`), so it goes to review. Request filed to let `asOf` fall back to `observedAt`.
7. **CRED reminders.** One rule per issuer sets `issuerSlug` explicitly (the sender is CRED, not the bank); an unlisted bank falls to `BIL-CC-CRED-90` with no issuer.
8. **Standing-instruction cards.** Debit or credit is not printed, so those instrument mentions carry no `kind`; the instrument matcher resolves them by issuer and mask.
9. **Synthetic wording.** The owner's real templates are not available, so ICICI, SBI, Axis, YES, Kotak, NSE and BSE wording was written from the brief and from fixtures in `app/test` and `api/test`. Round 2 must replace or add real templates.
10. **Fallback rules (`-90`).** Confidence 0.7-0.8; they exist so a missed template still yields the right kind of fact. They are the first candidates to retire once real templates cover the families.

## Old parser branches to new rule ids (for WP-17)

| Old branch (`local_sms_parser.dart`, `sms_parser.js`) | New rules |
| --- | --- |
| `asbaIpo` / `asbaOrIpoBlock` (block, lien, accepted) | `INV-IPO-ASBA-BLOCK-*` |
| ASBA release, lien removed | `INV-IPO-ASBA-RELEASE-*` |
| IPO allotment debit, mandate debit for IPO | `INV-IPO-ALLOT-*` |
| UPI IPO mandate block and unblock, SBI "hold removed" | `INV-IPO-UPIMANDATE-*` |
| IPO issuer mandate approved or revoked | `INV-IPO-MANDATE-*`, `MND-REVOKED-03` |
| NSE/BSE IPO notices | `INV-IPO-NSE-RECEIPT-*`, `INV-IPO-NOALLOT-01` |
| `_parseAutoPay`, `isAutoPayNotice` (setup) | `MND-CREATED-*` |
| AutoPay cancelled, paused, modified | `MND-REVOKED-*`, `MND-PAUSED-*`, `MND-RESUMED-*`, `MND-MODIFIED-*`, `MND-EXPIRED-*` |
| AutoPay or SI "will be debited" (future-debit pattern) | `MND-UPCOMING-*` |
| AutoPay or SI failed | `MND-FAILED-01` |
| UPI Mandate, NACH, SI debit executed | `MND-EXEC-*` |
| Broker detection (`Groww`, `Zerodha`, `Upstox`, `Kotak Securities`) and `investment` purpose | `INV-BROKER-*` |
| `isInvestmentFolioAllotment`, SIP folio | `INV-MF-*` |
| Dividend credits | `INV-DIVIDEND-*` |
| `bill_obligation`, statement and due-date extraction | `BIL-CC-*`, `BIL-UTIL-*`, `BIL-INS-*`, `BIL-LOAN-*` |
| Pay Later / Axio / LazyPay drawdown (`merchantName: Amazon Pay Later`) | `BIL-PAYLATER-*` |
| Biller receipt as spend | `BIL-RECEIPT-*` (now evidenceOnly) |

Not covered here (other packages): card "payment received", bank debits to bill billers (03a), wallets (03b), promotions and collect requests (03d).

## Gaps and follow-ups

- `corpus:autopay_failed` (request above). Autopay failures that print an amount are handled.
- Scenarios `ipo_block_then_*`, `mandate_then_charge`, `card_bill_pair` need the linker. Link rules (`LINK-IPO`, `LINK-MANDATE-CHARGE`) are outside 03c; the facts they need (`hold` phases, `mandateRef`, `references.umrn`) are emitted.
- No extra golden cases were added (the golden folder is outside this package). The rule examples (347) carry the new synthetic messages; WP-00's owner can promote them.
- Date formats need two-digit days: "5th of this month" and "5 Nov" are not parsed, so those notices lose `dueAt` or go to review.
- Merge check: build the full bundle with 03a, 03b and 03d and re-run `lint` for shadowing, then `golden` with the real bundle.

## Commands run

```
cd tools/sms_rules_cli
dart run bin/sms_rules.dart lint  --rules ../../rules/sms/v2
dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --out <tmp>/bundle.json
dart run bin/sms_rules.dart sign-dev --in <tmp>/bundle.json --out <tmp>/signed.json   # throwaway dev key
dart run bin/sms_rules.dart golden --bundle <tmp>/signed.json --golden-dir <03c subset> --profile none
node tools/sms_rules_cli/test/regex_parity.mjs rules/sms/v2
```

Scratch tooling (rule generator, stub bank senders for the golden run, dumper) lives outside the repo and is not committed.
