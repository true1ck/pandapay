# Foreign payments and monetary-role correction — coordinated release

## Release objective

One user-facing update delivers monetary-role prevention and existing-data repair,
original-currency activity, historical INR estimates, explicit INR confirmation,
settlement reconciliation, review controls and corrected downstream totals.
Implementation tasks run in parallel; these are not separately released stages.

## Accounting invariants

- A balance, credit/spend/cash limit, outstanding balance or bill obligation is
  not a purchase. Limit-change notices must be excluded even without payment verbs.
- Existing `transactions.amount_inr` remains an evidenced INR ledger value. A
  pending foreign payment is a durable, account-scoped record alongside that
  ledger, never a synthetic zero or a guessed INR transaction.
- Preserve original amount/currency independently of a cached INR estimate and
  bank/user-confirmed billed INR. Preserve source commitment and correction history.
- Categories describe purpose. Foreign currency and subscription status are
  metadata/filter dimensions; foreign purchases are not all fees.
- AI may extract fields and propose matches, but cannot override monetary roles,
  invent missing prices/rates, infer payment from limit changes, or confirm estimates.
- A malformed amount such as `USD .00`, an ambiguous dollar symbol, a failed
  payment or an authorization-only alert cannot silently become confirmed spending.
- Frozen historical reference estimates are distinct from billed INR. Use
  currency-specific decimal precision and decimal arithmetic for conversion.
- A linked settlement is one ledger purchase. Retries, later SMSs and statement
  imports must not create an additional expense. Weak matches require review.
- Separately posted fees/refunds stay distinct and are never added twice.
- Estimates never affect rewards, milestones, caps or confirmed utilization.

## Shared wire contract

Authenticated account-scoped `/foreign-payments` GET/POST, with item
`PATCH /foreign-payments/:id` and confirmation/reconciliation endpoints. Responses
use snake_case. Monetary original amounts and rates retain decimal text; INR
response values may be decimal text or JSON numbers, parsed without binary-money
arithmetic. GET returns `{items: [...], summary: {...}}` with bounded pagination.

Record fields: `id`, `source_key` (64-character source commitment),
`original_currency` (ISO code, nullable when ambiguous), `original_amount`
(decimal text, nullable when absent), `occurred_at`, `merchant_name`,
`card_last4`, `account_last4`, `user_card_id`, `category_id`,
`valuation_status` (`awaiting_amount`, `awaiting_rate`, `estimated`, `confirmed`,
`ignored`), `estimated_inr`, `billed_inr`, `rate`, `rate_date`, `rate_source`,
`transaction_id`, `confirmation_source`, `direction` (`spend` or `refund`),
`reference`, `created_at`, `updated_at`. Unknown fee inclusion is not asserted.

The backend owns rate retrieval/validation and estimate calculation. It receives
currency/date/typed purchase evidence, not raw SMS. Existing global body bounds,
authentication, RLS, owner checks and safe-error handling remain in force.
Client replay cannot overwrite a confirmed or user-corrected record.

## Implementation workstreams

### Backend

Add additive RLS-protected storage and rate cache; fixed-provider historical
daily rate retrieval with timeout, bounded concurrency, validation and retry.
Store actual observation date, provider and conversion snapshot; do not apply
today's rate to historical imports or silently substitute a future observation.
Expose durable CRUD, missing-field correction, dismissal and explicit billed-INR
confirmation. Confirmation uses the canonical transaction writer atomically.
Reconciliation links trustworthy explicit evidence or proposes ambiguous matches;
statement and SMS paths preserve one-purchase identity. Preserve ignored history.

### App data

Add typed original-currency model, account-scoped local persistence and durable
mutation replay. Extract foreign purchase evidence locally, including existing
captured/review SMSs. Retain unresolved prices without ledger projections.
Background refresh handles rate outages and app restarts, account changes and
offline edits. Existing review evidence and manually corrected values survive.
Extend amount-role repair to non-movement limit/service notices. Reuse canonical
reversal/ignore operations and invalidate all affected financial views.

### Product UI

Show foreign payments in Activity with original amount, currency badge and
valuation status. Provide a foreign filter, detail view, purpose category,
editable original fields, billed INR confirmation and dismissal. Show separately
labelled estimated pending INR and unknown-amount counts alongside confirmed
spending; include rate date/source and missing-fee caveat in details. Confirmed
records link to the ordinary transaction detail rather than duplicate rows.
Use existing visual/accessibility conventions and make offline/retry states clear.

### Existing-data audit and repair

Audit locally available evidence plus server facts/observations with explicit
coverage. Preview suspect count and amount impact before durable, idempotent,
recoverable correction. Never assume inaccessible source evidence is valid.
Protect notes, tags, explicit user edits and uncertain source identity. Repair
incorrect amount-role rows, retain original evidence in review/foreign activity,
and refresh reports, budget, recurring, card and rewards projections. Confirm
server aggregate exclusion of ignored rows and fresh client cache visibility.

## Acceptance checks

Test original amounts/precision, multiple currencies, ambiguous `$`, malformed
`.00`, zero-value authorizations, declined attempts, mixed INR/foreign amounts,
limits before/after charges and limit-only notices. Test historical/weekend rates,
offline recovery, immutable estimate snapshots, account isolation and duplicate
replay. Test explicit settlement and imported statements, ambiguous matching,
partial refunds, separately posted fees and preservation of manual corrections.
Verify foreign estimates stay outside confirmed totals and rewards, and that
confirmed/dismissed foreign rows do not remain as duplicate pending activity.

Run focused unit/widget and API tests, static analysis, migration/DB checks,
release builds and signed-device acceptance. Inspect final diff for unrelated
workspace changes. Deploy backend/schema and mobile candidate as one coordinated
feature release using existing backup/deployment controls. Record actual shipped
versions and checks; do not report source-only or unverified work as deployed.
