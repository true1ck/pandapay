# Lane B requests for shared files and the frozen contract

Lane B owns only `rules/sms/v2/wallets/*.json` and `rules/sms/v2/banks_lane_b/`. The items below need an owner of a shared file. No message text, name, number or amount appears here.

## 1. Sender registry (`rules/sms/v2/senders/*.json`)

Seven handles seen in the private sample or corpus are not in the registry, so lint rejects any rule scoped to them. Lane B rules for these use `senders: ["*"]` with sender-agnostic but tightly anchored patterns. Once the registry has them, those rules can be narrowed.

- A store-account wallet handle that differs from the registered brand (add as an alias of the existing `TINYMT` brand).
- A card issuer's credit-card payment handle for YES BANK (alias of the existing YES brand).
- Brand handles for two store wallets (a quick-commerce cash wallet and a district/ticketing money wallet).
- The Amazon Pay gateway handle sent through a payment aggregator (alias of the existing gateway brand).
- Two UPI app / NPCI handles that relay collect requests (BHIM and the NPCI relay).

## 2. Scorer (`tools/sms_rules_cli/tool/score_private.dart`), owned by the scorer lane

- `payment_request` is recognised only for two rule ids. Lane B adds collect-request rules whose id contains `COLLECT-REQUEST`. Suggest matching on that substring or on the rule family `payment_request`. Without it the scorer reads these facts as `failed_attempt`. (Lane B verified with a throwaway patched copy; no tracked change.)
- The foreign-currency check matches only `USD` or `US$` in the body. A body using a dollar sign (`$0.02`) is scored as INR, so a correct USD amount counts as an amount mismatch.
- Labels use `not_financial` where the engine can only say `service_notice` or `unknown` for ignored notices. Rows read as ignored by the phone still count as wrong on `reading`. Suggest treating `ignored` and `service_notice` as equal to `not_financial` and `promo` when the money effect is none.
- A card debit whose merchant is a wallet top-up merchant is read as `wallet_credit` by `reading()` because the movement purpose is `wallet_topup`. The draft labels read the same message as `card_spend`. The money effect (spending) agrees, so only the reading differs. This is a label-versus-contract mismatch, not a rule defect. Decide which wins.

## 3. Ignore rules (`ignore_rules.json`)

These sample rows are non-money notices that stay `unknown`. A sender-scoped ignore (or info rule) would let them read as non-financial:

- A UPI-app notice that registration of UPI payments was initiated.
- A card issuer's "you have enabled <channel> transactions" settings confirmations (domestic or international, POS, ecom, contactless).
- A depository's notice that shares were debited from a demat account.
- A card issuer's EMI or loan promotional offers.
- Delivery-status and appointment-booking notices from consumer apps.

## 4. Frozen contract

- **Bill-pay app receipts.** Draft labels for two card-bill payments made through a bill-pay app read the app's receipt as a transfer with the card mask. Under the contract an `evidenceOnly` receipt never counts as money and the funding debit is a different message, so the receipt is correctly neutral. The label (not the rule) should change, or the contract should allow a receipt to count when no funding debit exists. Lane B did not change the receipt rule.
- **Foreign-currency spends.** Lane B emits `unit: "USD"` posted amounts without `original`. The ledger projector requires INR, so these facts go to review rather than totals. Converting needs a rate field the frozen contract does not provide.
- **Standing-instruction failures.** One draft label reads an issuer's "standing instruction could not be processed" notice as a failed attempt with amount and card mask. That belongs to the subscriptions lane and was not touched.
