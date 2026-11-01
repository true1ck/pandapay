# Main PandaPay: sender-text migration and UPI card payments

**Current isolated test:** use Sender Probe **6**. It fixes registration for **PANDAPAY SENDER CHECK**, which build 5 launched without an active range. Main PandaPay remains **81** unchanged. See the [probe lab record](ios-probe-sender-lab-2026-11-01.md).

This moves the verified single-message text-sender contract into the main application, `app.pandapay.pandapay`. The prototype remains separate. Historical sender recovery is still a device qualification item: the screenshots prove a supplied bank header reaches the original String receiver. Its legacy live tag identifies a receiver, not the shortcut trigger; it does not establish the caller. The isolated probe comparison now mirrors the main fields with the same source variables.

## Shortcut changes

For an existing **main-app** `PANDAPAY SMS HISTORY` shortcut, replace only the action **inside Repeat**:

**Capture PandaPay History SMS → Capture PandaPay History SMS as Text** (choose the PandaPay app, not History Probe).

| New field | Select |
| --- | --- |
| Import request | The original Shortcut Input, or the variable named Import request saved from it. |
| Message body | Repeat Item → Type: Message → Get: Body. |
| Sender (text) | Repeat Item → Type: Message → Get: Sender. |
| Original Message Date | Repeat Item → Type: Message → Get: Date. |

The new action has no Person, contact, sender-type diagnostic, or Repeat Index parameter. Do not bind a whole Message as the sender. If the Sender property resolves to empty, the receiver preserves that absence and financial candidates go to review; it does not invent a bank header.

Keep Begin/Window Start/Window End, date search, count and Finish **bound to the main app**. Search oldest first, with Limit off. Keep **Finish PandaPay History Import**, its Messages found = Count, Find Messages limit is off = Yes, and Stop and Output = Finish result. The app's issued-window receipts and admitted foreground return are unchanged.

For a shortcut that still calls the **prototype**, the whole request protocol must migrate:

| Prototype action | Main-app action |
| --- | --- |
| Prepare PandaPay Selected Range | Begin PandaPay SMS Window **and** PandaPay SMS Window Start. Both take the original import request; only Start returns the start Date. |
| PandaPay Selected Range End | PandaPay SMS Window End. |
| Import PandaPay Range Message / Import PandaPay Range Message as Text | Capture PandaPay History SMS as Text, with the four mappings above. |
| Finish PandaPay Range Import | Finish PandaPay History Import. |

Name the migrated shortcut `PANDAPAY SMS HISTORY`, or select its exact name in PandaPay. Use Start/End outputs as the Find Messages date bounds. Pass the original request to every PandaPay action, not a Date output. Prototype version-2 requests and main version-3 requests cannot be mixed.

For **live incoming messages**, use **Capture Incoming SMS in PandaPay**. Map the incoming Message's Body, Sender and Date. If Current Date is used for a test, choose Estimated date evidence; choose Original only for the real Message Date. Keep the tested space filter if desired; it does not cover messages containing no spaces. A daily background copy uses the text-only Capture and quiet **Finish PandaPay SMS Window**.

Installing an app does not replace saved Shortcut blocks. The new action may require initial iOS consent. No claim is made that adding it suppresses all Shortcuts privacy prompts; repeat-run consent persistence must be checked on the actual recipe.

## What enters the shared pipeline

Native capture saves the same body, actual supplied sender and original receive timestamp to the durable account-scoped inbox. The text-only receiver has explicit-only parameter connections, so an omitted sender cannot inherit the previous whole Message collection. The existing legacy action and its published input types remain for compatibility.

Production uses `IosShortcutSmsBatch` with sender inference disabled, then the same `SmsImportStore` / `LocalSmsParser` used by Android. Security exclusions, account fences, replay receipts, classification and deduplication remain shared. Missing-sender input is not promoted to verified bank evidence.

## UPI and the saved card

The parser preserves these distinct facts:

| Fact | Source |
| --- | --- |
| Actual SMS sender | Supplied sender text, never the merchant or a fabricated bank label. |
| Merchant | The completed bank alert's merchant text. |
| Credit-card instrument | Explicit card wording in the alert. |
| Saved card | Exactly one non-archived saved card with the matching suffix and compatible type. Its ID links to the existing product/catalogue; the saved nickname is displayed when present. |
| RuPay network / co-branded product | The linked saved product. Never guessed from a four-digit suffix alone or from a payment-app mention. |
| UPI payment method | Explicit movement wording, such as “via UPI” or a UPI reference in the alert. |
| QR-specific rail | Remains unknown unless separately established. Generic UPI does not establish a QR scan or QR-only reward eligibility. |

No personal card suffix or product is hardcoded. If matching is absent or ambiguous, retain the extracted suffix and credit-card evidence with no automatic saved-card link. Do not select a default card to break a tie.

`TransactionEntry.paymentMethod` persists as optional `payment_method: "upi"` in device snapshots. This is source evidence, separate from the existing server rail enum, whose `upi_qr` value is narrower. Activity/detail shows **UPI** when the exact rail is unknown. This does not change reward eligibility or invent a QR-specific rail. On reconciliation, the local observation can supply that method only for the exact same source key within the same account; unrelated transactions and accounts cannot inherit it. Detail's online refresh preserves matching local evidence too.

A collect/request SMS creates **zero expenses**. A later completed bank debit creates one expense. Replaying either source in either order keeps one expense. This change does not automatically mark a request/commitment paid by matching merchant and amount; that requires stronger correlation evidence, and is not claimed by the diagnostic comparison.

Synthetic illustration (not a captured SMS or real saved card):

```json
{
  "sender": "SBICRD-S",
  "transaction": {
    "amount_inr": 42.50,
    "merchant_name": "TESTTECHNOLOGIES",
    "instrument": "credit_card",
    "payment_method": "upi",
    "rail": "unknown",
    "card_last4": "4242",
    "user_card_id": "saved-rupay",
    "card_name": "My PhonePe card"
  }
}
```

The sender is acquisition evidence; it is not a transaction-JSON merchant/card field. A date-only SMS retains date-only transaction precision, while SMS receive time stays separate.

## Validation

The regression suite uses synthetic messages and an in-memory account store. It checks iOS/Android shared input parity, real supplied-header preservation, missing sender review, unique/ambiguous card attribution, UPI versus generic mention, original receive time, request-plus-completion replay, exact-source reconciliation, account isolation and the visible UPI/card detail.

Build and installation verification is recorded in the main implementation status document. Installing the text-only action does not prove previously missing historical sender properties are now available. Qualify with one known receive day and inspect sender received/missing counts before a large import. Existing saved rows are not bulk rewritten and no bank sender is inferred to force a parse.

**Delivery:** main PandaPay **1.0.15 (81)** was signed, verified, installed and read back from the paired iPhone. Launch succeeded. The separate probe remains **1.0.0 (4)**. The main compiled action schema confirms four fields and no Person/contact parameter on the text-only Capture action. Device sender recovery still requires the mapped historical test described above.

## Follow-up: historical run with 306 missing sender inputs

The next user screenshots show main build 81, the legacy **Capture PandaPay History SMS** block, Sender (text) bound to a Sender token, and Sender from Message empty. The run reports 346 received, 306 processed, 40 security excluded, **0 sender received / 306 missing**, 186 review and 120 ignored. The input summary says no sender value arrived. These counters are evidence of a missing value at capture, not evidence that every processed message was a financial transaction.

With Person omitted, the legacy action's resolver passes a nonblank String unchanged, just like the text-only action and probe. The separately compiled main/probe sender fields also have the same optional primitive-String contract and explicit-only input connection. Replacing the block removes the legacy Person boundary and stale saved bindings, but cannot by itself prove historical sender recovery. The successful raw probe screenshots available in this conversation have `origin: live`; they are not the missing paired history comparison.

Next diagnostic: one known bank message from its receive day. Inside Repeat, use a built-in **Text** action whose only token is Repeat Item → Message → Sender, and preview that Text with **Quick Look**. Keep the original request/body/date mappings explicit. If the preview shows the actual bank header, bind that Text result to **Capture PandaPay History SMS as Text → Sender (text)** and inspect one capture's sender counters. A contact display name is not proof of the original bank address. A blank preview requires investigating acquisition/property resolution; do not manufacture a bank header from the body or rerun months blindly. This diagnostic has not yet been observed.

Rechecks: the native intake/sender harness and all 11 focused shared-main/probe sender tests passed. No new app build or installation was made for this comparison; main remains build 81.

**Receiver-label correction:** The original probe stamps `origin: live` in its single-message receiver. It can be called from a history loop too. Earlier claims that this tag alone proved incoming-only acquisition were incorrect. See the [build-5 paired receiver test](ios-probe-sender-lab-2026-11-01.md) for the now-authorized probe-only comparison; main stays on build 81.
