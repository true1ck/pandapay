# Lane I requests: files outside the brokers and investments lane

Lane I (brokers and investments) owns only `rules/sms/v2/brokers/` and three files under `investments/`. These need other owners.

## 1. Ignore rules: `IGN-BROKER-PAYABLE-TRADES` hides the printed amount

Owner: `ignore_rules.json`. The ignore rule turns "Rs N is payable to you for all trades" into an `info` fact with no amount, and ignore rules run before ordinary rules, so a rule cannot carry the amount (CCR-002 `amountMinor`). Lint reports `lint.shadowed` if the rule below is added today. Proposed change: narrow or retire the ignore rule, then add this rule (synthetic examples only):

```json
{
  "id": "BRK-PAYABLE-NOTICE-01", "version": 1, "family": "broker_notice", "senders": ["*"], "priority": 470,
  "match": {
    "pattern": "(?:rs\\.?|inr|₹)\\s*(?<amt>[\\d,]+(?:\\.\\d{1,2})?)\\s+is\\s+(?:payable|receivable)\\s+(?:to|by)\\s+you\\s+for\\s+all\\s+(?:your\\s+)?trades",
    "flags": "i", "rejectAny": ["has been", "was credited", "debited"]
  },
  "emit": [{"factType": "info", "attrs": {"category": "service", "amountMinor": {"from": "amt"}}}],
  "confidence": 0.9,
  "examples": [
    {"sender": "VM-ACMESC-S", "body": "Dear Customer, Rs.480.25 is payable to you for all trades till 05/11/2026. - Acme Securities", "expectFactTypes": ["info"]},
    {"sender": "VM-ACMESC-S", "body": "Dear Customer, Rs.480.25 has been credited to your bank account for all trades till 05/11/2026. - Acme Securities", "expectFactTypes": []}
  ],
  "status": "active", "createdBy": "lane-i", "updatedAt": "2026-11-05T00:00:00Z"
}
```

Today the notice is already informational (info, never a movement); only the amount is lost.

## 2. Scorer: readings the private scorer cannot produce

Owner: `tools/sms_rules_cli/tool/score_private.dart`. The drafts use `broker_notice` (payable notices), `demat_movement` (`BRK-DEMAT-*` info facts) and `ipo_allotment_shares`. Every `info` fact is scored as `service_notice`, `promo` or `otp`, so these rows can never agree. Suggest mapping by rule id, as already done for `INV-IPO-NSE-COLLECT-NOTICE`: `BRK-PAYABLE-NOTICE-*` to `broker_notice`, `BRK-DEMAT-*` to `demat_movement`.

## 3. Contract question: negative broker fund balance

Exchange reports print a negative fund balance when the user owes the broker. `balance_snapshot` amounts cannot be negative. `BRK-EXCH-FUNDBAL-NEG-01` stores the absolute value with role `outstanding` on the broker instrument (never money, no ledger effect). Please confirm, or add an explicit contract reading (for example a signed available balance). No contract file was touched.

## 4. Linker: broker payout notice and bank credit can double count

Owner: `link_rules.json` and the linker. A payout is announced by the broker (`BRK-PAYOUT-TRANSFER-OK-01`, with the UTR in `references.txnId`) and again by the bank credit alert (`INV-BROKER-WITHDRAW-CREDIT-*`). Both are non-evidence movements credit with purpose `investment`, so `investment_withdrawn` could be counted twice. There is no link rule for credits (`LINK-DUP-NOTIFY` is debit only). Suggest a duplicate-notice link rule for `investment_withdrawal` that joins a credit to a credit on amount and a shared UTR reference, within a short window. Until then the broker notice is the only reading the draft label expects.

## 5. Sender registry entries

Owner: `senders/investments.json` (not in lane I). Real senders seen with no registry entry, all of which lane I rules match through `*`: a broker payout handle and a broker settlement handle (aliases of existing broker brands), the exchange fund-balance handles (NSE and BSE), the exchange registration-notice handles, and the depository transaction handles (CDSL and NSDL). Adding them lets rules be sender-scoped.

## 6. Canonical broker issuer slug on balance snapshots

`BRK-EXCH-FUNDBAL-*` take the issuer slug from the first word of the broker name printed in the report, because the engine can only lowercase a captured group. For a multi-word brand this can differ from the registry slug (for example the first word versus `kotak_securities`). A registry alias lookup in `issuerSlugFrom`, or one override rule per brand, would remove the mismatch.
