# Credit card bill payment and spending audit

## Accounting rule

A purchase on a credit card is spending when the purchase posts. Paying the
card statement later settles a liability; it is a transfer, not a second
purchase. For an ₹80,000 purchase followed by an ₹80,000 repayment, spending
is ₹80,000 and transfer out is ₹80,000. The same rule applies to partial
repayments and repayments in a later reporting month. A statement or due
reminder is an observation, not a posted transaction.

## Paths checked

- Server SMS imports use `api/src/sms_parser.js`. Explicit card repayments are
  parsed before issuer patterns and generic debit/purchase fallbacks.
- On-device SMS parsing uses `app/lib/data/local_sms_parser.dart`. It records
  repayments as `TxnEntryKind.transfer` and purchases as `spend`.
- PDF/statement imports use `app/lib/data/pdf_statement_parser.dart` and
  `transaction_import_pipeline.dart`. Explicit repayment narration is a
  transfer and remains distinct from a merchant purchase.
- `api/src/spend_reports.js` filters every spending breakdown to active
  `entry_kind = 'spend'`. Its totals keep transfers in a separate bucket.
  Monthly report generation, category totals, budgets, and local report
  construction apply the same spend filter. The activity feed can show
  transfers without including them in spending.
- Transaction editing permits changing an incorrectly imported entry from
  Spending to Transfer, so a confirmed historical error can be repaired.

## Fix and limits

SMS and statement parsers now recognize explicit paid card bill wording,
including payments to a named Axis/Flipkart credit card, before generic
purchase categorization. Due reminders remain non-transactions. A merchant
label such as `FLIPKART INTERN` alone cannot establish whether a row is a
purchase or a repayment: Flipkart can be a real seller and the card's brand.
Historical rows should be changed only after checking the original bank/card
alert or statement narration. No bulk amount or merchant matching is safe:
equal amounts and nearby dates can be unrelated transactions.

## Regression scenarios

- ₹80,000 purchase on a Flipkart Axis credit card: `spend`.
- ₹80,000 payment to that credit card: `transfer`.
- ₹80,000 bill due reminder: no transaction.
- Two genuine purchases at Flipkart: both remain spending.
- A bank statement debit explicitly labeled as a credit card payment:
  `transfer` even when parsed through the generic numeric-column path.
- Money received as salary, cashback, refund, or another completed bank
  credit: `income`.
- Money received into one own account from another own account: `transfer`,
  not income.
- Money sent from an own account to another own account: `transfer`, not
  spending.
- Money sent to another person or merchant: `spend` when the recipient is
  explicit; an account debit with no payee stays in review.
- ATM cash withdrawal: `transfer` to cash, because the later cash purchase is
  the spending event and is not known at withdrawal time.
- Mutual-fund/SIP contribution: `investment`, separate from consumption.
- Refund or reversal: `income`; failed, pending, due, and statement alerts do
  not create posted transactions.
