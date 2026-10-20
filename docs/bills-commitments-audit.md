# Bills and commitments audit (20 October 2026)

## What was wrong

- The SMS provider treated any bill with no cadence hint as monthly (annual for insurance), then displayed stale due dates as active upcoming items.
- An amount fragment or SMS route could become a bill title. Messages from the same LIC sender could also collapse distinct policies when a policy identifier was available but not extracted.
- The screen converted an expired date into “Payment not detected.” SMS absence cannot establish nonpayment, and the page offered a review banner that routed to the transaction review queue rather than a bill review flow.
- The first credit card took a large panel and showed ₹0 logged spend, which readers could mistake for the issuer balance due.

## Rules now used

- The upcoming list contains due dates strictly after the device's current calendar day. Historical SMS reminders remain source evidence, not current scheduled payments.
- An observed cadence is used only when the message explicitly states it. An unknown cadence stays one-time. A confirmed recurring bill advances past the confirmed payment date.
- Generic amount/text fragments and unknown sender IDs are not promoted to bills. Credit-card statement SMS do not become a second scheduled-payment row.
- A LIC reminder with a policy number can be identified separately by the policy's last four digits. A future debit reminder is classified as a bill observation, not a completed bank debit.
- The page makes no claim that a payment failed merely because an SMS was not found. Card due dates come from saved card settings; the issuer still determines actual amount, autopay and payment state.

## Remaining evidence gap

These changes were tested against synthetic regression cases and the screenshots, not the user's private SMS archive or issuer accounts. Messages without a reliable due date and biller/policy identity are intentionally omitted. Bank, card, and insurer payment confirmation requires a matching verified transaction, receipt, issuer integration, or user confirmation; there is no such general integration here yet. Do not infer nonpayment from message absence.
