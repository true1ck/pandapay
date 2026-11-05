# Lane T requests and label doubts

No message text, name, number or amount appears here. Row numbers are indexes into the private draft sample.

## 1. Scorer (`tools/sms_rules_cli/lib/scoring.dart`)

- Add the `refund_initiated` reading for a pending attempt with purpose refund (see the handoff). This alone moves the refund stratum from 18 to 30 of 32.
- A hold or mandate fact from a rule in an IPO family reads as `mandate_created` / `hold` / `hold_release`, while the draft labels use `ipo_mandate_approved`, `ipo_hold`, `ipo_release`. Reading from the rule family (as is already done for `ipo_notice`) would resolve 7 sure rows in the subscription stratum (rows 264, 268, 269, 271, 282, 283, 294) and 3 in the IPO stratum (rows 84, 89, 98) once the IPO owner confirms the mapping. Rows 268 and 269 come from rules in `bills_mandates/` that do not know the block is for an IPO, so a family cannot be derived there; that is a label question as well.
- `demat_movement` and `broker_notice` have no reading and are not in the non-financial list (rows 137, 157).

## 2. Frozen contract (rows no rule can fix)

- Payment failed with no amount (rows 9, 10), mandate registration failed (row 285), a cancellation that prints no amount (row 204): an `attempt` needs an amount and `mandate` has no failed phase. Same root cause as `WP-03c-attempt-without-amount.md`.
- Card statement ready with a due date but no amount (row 20), and a statement with a total but no due date (row 41): `bill_due` needs both. A broadband bill "due today" (row 132) has the same limit; a `fromObservedAt` option for `dueDate` would fix it.

## 3. IPO and broker rule owners (folders `ipo/` and `brokers/` untouched)

- Demat credit notices for IPO allotment (rows 84, 98) read as `ipo_application_notice`; the label wants `ipo_allotment_shares`. Partial allotment (row 89) reads as an investment top-up; the label wants `ipo_partial_allotment`.

## 4. Draft label doubts (no rule forced to fit)

- Rows 14 and 26 (bill paid through a card app): the label says the bill payment counts as a transfer and names the card as the instrument, but its own note says the bank debit counts elsewhere. The rule emits an evidence-only receipt, which is what avoids double counting. Keep the rule; fix the label to `none`.
- Rows 226 and 286 (mobile recharge): label says spending. The rule emits an evidence-only bill payment because the notice does not name the funding account. Unsure labels; keep.
- Rows 144 and 166 (card spend on a wallet top-up merchant): the engine reads a wallet credit with the spending effect, which agrees on the effect; the label reading `card_spend` is the doubt.
- Row 183 (clinic refund successful): the engine reads money back, but the phone ledger gives it no effect because no purchase is linked in the replay. Label is likely right; this needs a refund with no linked purchase to count as refund, which is a linker/ledger decision.
- Row 134 (unsure, UPI transfer to a bank): the label guesses a card bill payment; the engine reads a UPI spend. This is the one false-count row in the unsure set and cannot be decided from the text.
- Row 39 (unsure, one rupee credit adjustment to a card with zero due): the engine reads a service notice through the zero-due rule; the label wants a card payment received. Left alone.
- Rows 2 and 7 (unsure, non-payment warning): ignored by design, label says a bill reminder with a card mask.
- Rows 267 and 278 are now read (exchange submitted notice, mandate collect request); the first scores as `ipo_application_notice`.

## 5. Sender registry

`BSELTD` is now an alias of `BSEIND`. `LANE-L-requests.md` said it was registered; it was not.
