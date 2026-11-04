# Lane L requests

Lane L owns only `rules/sms/v2/ignore_rules.json` and `rules/sms/v2/senders/`. The items below need other owners. No message text, name, number or amount appears here.

## 1. Rules for UPI-Mandate collect requests (subscriptions and investments lanes)

`IGN-UPI-COLLECT-REQUEST` no longer swallows a body that mentions a UPI mandate (the shadowing filed in `LANE-A-subscriptions-requests.md` section 2). Nothing claims these bodies yet, so they are now unknown instead of wrongly ignored (33 corpus rows, 2 sample rows, both sure-financial in the draft labels).

- **Biller request (subscriptions lane, Lane A's shape):** pattern `upi-?\s*mandate\s+collect\s+request\s+from\s+(?<m>[a-z0-9&.' _*-]+?)\s+for\s+(?:rs\.?|inr|₹)\s*(?<amt>[\d,]+(?:\.\d{1,2})?)`, emit `attempt`, status `pending`, direction `debit`, purpose `unknown`, scheduled amount, counterparty from `m`. Sender `SBIUPI` is registered. Without a rule the sample reading stays unknown; with it the scorer reads a scheduled attempt (the draft label says `payment_request`, so the scorer's recognised-rule list may also need this rule id).
- **Exchange advance notice (investments lane):** an application-submitted notice that says a UPI-Mandate collect request for blocking of funds will follow, from the BSE handle (`BSELTD`). The NSE equivalent already has `INV-IPO-NSE-COLLECT-NOTICE`; this one needs an info rule of the same kind.

## 2. Lint: reject aliases in rule `senders` (engine owner)

Lint accepts any brand or alias in a rule's `senders`, but `rule_engine.dart` compares the canonical brand only (`normalizeSenderBrand` resolves aliases first). A rule scoped to an alias never fires and nothing reports it. Lane L found two such rules while building. Proposal: `lint.sender.alias` (error) when a `senders` entry is an alias of another brand, naming the brand to use.

## 3. Depository notices (investments lane)

Handles `CDSLTX`, `NSDLDP`, `CDSLEV`, `NSDLBP` are now registered (kind `other`). Debit-in-account, credit-through-IPO and blocked-for-pay-in notices are left unknown because the draft labels read them as financial movements. If the owner decides share movements are not money, ignore them with a sender-scoped rule; if they should count, they need rules. E-voting and account-maintenance notices from these handles are already ignored.

## 4. Gate sample for ignore precision (golden owner)

The golden set has 27 ignore cases for 70 ignore rules, so `ignorePrecision` barely measures the new rules. The new ignore examples are checked by `tools/sms_rules_cli/test/ignore_examples_test.dart`. Suggest the golden runner load `tools/sms_golden/ignore_examples/*.json` and count positives as ignore cases and negatives as must-not-be-ignored-by-this-rule checks.
