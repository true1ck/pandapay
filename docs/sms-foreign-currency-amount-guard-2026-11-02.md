# SMS monetary-role guard — 2 November 2026

## Problem

A foreign-currency card alert printed an ambiguous `USD .00` charge followed
by an available credit limit in INR. Both the device grammar and hosted
fallback could take the first INR number as the payment amount. The app's
`Money`/transaction totals currently represent INR; a foreign amount is not
an INR amount, and no conversion can be inferred from a credit limit.

## Shared prevention

`SmsAmountEvidence` and its JavaScript mirror distinguish payment amounts from
balances, available/credit/cash limits, outstanding values and due amounts.
A movement without an evidenced INR posting is reviewable. A foreign charge
with a separately printed INR billed/equivalent amount can use that posting.
Currencyless domestic movement wording remains supported. No exchange rate
is guessed. Original SMS evidence remains available in local review.

The guard runs before downloaded posted-movement rules, at mapped-amount
validation, in built-in and fallback parsing, and in AI amount evidence.
AI confidence cannot override the amount-role gate. Review-form prefilling also refuses an unsupported AI amount. The parser version is 27.
Review copy explains that a limit is not the expense and asks for billed INR.

New foreign/unclear payment messages are retained locally for review and do
not reach an older hosted parser that might recreate the bogus expense.

## Repair

Untouched provisional local SMS rows are removed from spending only when their
amount exactly matches a non-payment figure in the original SMS and lacks
independent payment evidence. Confirmed rows and pending edits are excluded
from that local repair. The original evidence is retained as a review item;
unsafe queued movement facts cannot recreate the expense.

Synced rows use a separate authenticated lifecycle repair. It requires the
original captured SMS, an exact balance/limit amount match, no pending user
mutation, and a fresh server read with the same source key and amount. Older detail
responses that omit the source key require an exact committed source receipt,
matching transaction ID, date, amount and linked card. A conflicting non-null
source key is never accepted through this fallback.
Rows with notes, tags, or custom categories are skipped. The existing
`wrong_transaction` domain route reverses card/reward contributions and marks
the old record ignored, retaining recoverable history. The payment remains
in local review for its actual billed INR amount. Network/account failures
leave durable data available for retry. Each failed candidate is isolated so it
cannot block other corrections. This repair runs before legacy SMS upload work. No raw SMS is sent by this repair.

This is an amount-role safety invariant, not a promise that every bank message
or every foreign-currency accounting case can be parsed automatically.

## Verification

- Shared synthetic fixtures cover USD, EUR, GBP, AED, SGD and currency symbols;
  ambiguous/missing amounts; domestic limits; a balance before the charge;
  identical charge/balance values; and explicit billed INR after a foreign price.
- 325 app parser/intake/store/AI tests passed. Additional valid-charge assertions
  confirm genuine INR postings still become transactions.
- 447 API SMS/AI tests passed; two database-dependent tests were skipped.
- API syntax checks passed. New guard/repair code static analysis passed.
- A separate local copy of the phone's financial database identified and
  exercised repair of 12 source-backed synced misparses, including the
  screenshot amount. The copy replay used a mock reversal and did not mutate
  the server.
- Signed device build 1.0.15 (104) contains the guard and retains existing
  Shortcut contracts and the background import recovery from build 103.

The API source changes require the normal backend deployment; they have not
been published to production as part of this change. Other users receive the
app-side protection when the mobile build is released.

## Connected-phone verification

Installed and launched signed build **1.0.15 (104)**. The correction initially
waited at Face ID; after unlock, an older transaction-detail response omitted
`source_key`. Compatibility now uses an exact previously committed source
receipt plus unchanged transaction ID/date/amount/card when that field is
absent. Conflicting non-null source keys and user corrections remain excluded.

The live authenticated correction pass reported **11 candidates, 11 repaired**
through the existing `wrong_transaction` domain route. A fresh device database
copy passed `PRAGMA quick_check`; it contained 11 amount-role review items,
and no displayed transaction with the screenshot's erroneous amount. The
original screenshot SMS was present in review. The earlier local-only replay
had 12 candidates before subsequent cache changes; it was not a live repair
count. Ignored server records remain recoverable; normal active-list refresh
may remove ignored records from the local display cache.

Seven focused correction tests cover fresh server edits, annotations, account
changes, failed reversals, and legacy-detail receipt requirements. Additional
review-form/widget checks passed (51 tests). Safe local diagnostics retain
only correction stage names and HTTP status codes, without SMS text, source
keys, transaction IDs, credentials, or card numbers.

API source is implemented and tested, but deployment and public mobile release
are still required to distribute the protection to all users.
