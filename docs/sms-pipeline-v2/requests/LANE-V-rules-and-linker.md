# Lane V requests to the rules and linker owners

Found while replaying golden scenarios and rule-example messages through `SmsV2Runtime` and checking the five product screens. None of these can be fixed in `app/lib/features/sms_v2/ui/` or `ledger/`. The screens already handle the gaps honestly (an unnamed payer shows as "Unknown payer" and is never grouped into salary).

## Rules

1. **Payer name missing on credits.** These facts carry no counterparty, so Money in cannot name the payer, and salary cannot be detected from repetition:
   - `INR 60000.00 credited to A/c no. XX1234 on 01-10-26 through IMPS/P2A/432100000001/GLOBEX LTD/OCT` (HDFC, no word "SALARY"): becomes `p2p_in` with no counterparty. The payer is the segment after the reference.
   - `Dividend of Rs.1,200.00 credited ... from ACME INDUSTRIES LTD` (golden `dividend_credit`): dividend has no counterparty, so it cannot be tied to a company.
   - `Refund of Rs.499.00 from SWIGGY credited to your HDFC Bank Credit Card XX5678` (golden `refund_after_purchase`): the credit leg has no counterparty. The app falls back to the original purchase's merchant when the linker paired them, but an unpaired refund would show "Unknown payer".
   - `Rs.2,500.00 credited ... by UPI Ref ... from RAVI KUMAR (ravi@okhdfc)`: person name not extracted.
2. **ICICI "the mandate of INR 649.00 is raised by SAMPLE STREAM ... for your approval / you have approved the mandate"** produces no `MandateFact` (an `InfoFact`, or nothing), while the same shape for SAMPLE WORKS LI (INR 15000) becomes a one-time `ipo` mandate. A non-IPO raised mandate should be a `subscription` mandate (`oneTime: false`) so it appears in Subscriptions.
3. **Broker messages.** In a probe, `Funds of Rs 5,000.00 have been added to your Zerodha trading account via UPI.` (VM-ZERODH-S) and the NSE `... reported your Fund bal Rs.1250.500 ...` (VM-NSESMS-S, naming ZERODHA BROKING LIMITED) produced no facts, so the Investments screen has no "put in" or "fund balance" for Zerodha. Please check sender registration for these two shapes.

## Linker

1. **Broker withdrawal has no event.** `Upstox: Your withdrawal of Rs 8,000.00 has been credited to your bank A/c XX1234.` yields a `MovementFact` on the `upstox` broker instrument (counterparty kind `bank`) but no `investment_withdrawal` event, so "taken out" and net invested stay at zero for Upstox. Expected: one `investment_withdrawal` event (credit to the user's bank account from the broker).
2. **Card standing instruction processed is a plain purchase.** `your standing instruction (SI) of Rs 119.00 for SPOTIFY SI on ICICI Bank Card XX9012 has been processed` becomes a `purchase` event, not a `subscription_charge`, and there is no mandate fact. The later `could not be processed` notice is an `AttemptFact` (failed) that the Subscriptions screen cannot attach to any series. Expected: a successful SI becomes a `subscription_charge` (or a mandate fact is created from the SI notice) so a failure shows as a failed payment on the service.
3. **Batch versus sequential refunds (pre-existing, not Lane V).** `test/features/sms_v2/pipeline/idempotency_test.dart` "one batch and one-at-a-time agree on every non-IPO event" fails at the lane tip a8a9560 with and without Lane V changes: batch processing leaves 3 `refund/ambiguous` events (10 complete) where sequential processing completes 13. Needs the linker owner.
