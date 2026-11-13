# Money in, Money out and Spending: the definitions

One definition, used on every path (SMS ledger, legacy server rows, offline
fallback). If a screen disagrees with this page, the screen is wrong.

## The three figures

| Figure | What it adds up |
|---|---|
| **Spending** | Settled spend rows the person has not left out of spending, net of refunds. Feeds budgets, breakdowns, Trends, Insights and voice answers. |
| **Money out** | Spending + spend the person left out of spending + money put into investments. |
| **Money in** | Income + investment returns. Refunds are netted inside spending instead. |

Never in Money in or Money out: transfers between the person's own accounts,
credit card bill payments, wallet top-ups, unknown or ambiguous rows, and rows
that are ignored, deleted or reported as wrong.

## Row kinds (`entry_kind`)

| Kind | Spending | Money out | Money in | Notes |
|---|---|---|---|---|
| `spend` | yes, unless left out | yes | no | purchase, subscription, bill, fee, payment to a person |
| `income` | no | no | yes | salary, dividend, cashback, money from a person |
| `investment` | no | yes | no | SIP, broker top-up, IPO debit |
| `investment_return` | no | no | yes | redemption, sale, broker payout. Mostly the person's own principal, so never earned income |
| `refund` | reduces spending | reduces it | no | follows its purchase |
| `transfer` | no | no | no | own-account transfer, card bill, wallet top-up |
| `unknown` | no | no | no | stays in Activity for review |

## "Don't count in spending" (`exclude_from_spend`)

A per-transaction choice, separate from `status` and from `entry_kind`.

- Leaves the row out of spending totals, breakdowns, budgets and the Activity
  "Spending" filter.
- Does **not** change: the row's status, its place in Activity, Money out, card
  utilisation and dues, rewards, caps, milestones, fee waivers, recurring and
  subscription detection.
- Only a `spend` row can be left out. A refund of a left-out purchase comes off
  the left-out amount, so neither spending nor a category goes negative. Legacy
  rows carry no refund-to-purchase link, so an unlinked refund still comes off
  spending.
- Why not `status = 'ignored'`: that reverses card caps, milestones, points and
  fee-waiver progress and hides the row. Why not `entry_kind = 'transfer'`: that
  loses what the row was and removes it from Money out.
- SMS transactions keep the choice on the phone (like notes and tags). Server
  rows carry it in `transactions.exclude_from_spend`, written through
  `PUT /transactions/:id/spend-exclusion` (a value, not a toggle) by the command
  outbox.

Code: `TransactionEntry.countsAsSpend` (use it for any spending total; use
`entryKind` alone for card-side figures), `Totals.excludedSpendMinor`,
`Totals.moneyOutMinor` / `moneyInMinor` / `allSpendMinor`, and the shared SQL
filter `NOT exclude_from_spend` in `api/src/spend_reports.js`.

## Known disagreements not yet settled

- ATM withdrawal: the SMS ledger counts it as spend; the server parser and
  `docs/credit-card-bill-spending-audit.md` treat it as a transfer.
- EMI: the SMS ledger counts all of it as spend; the server parser treats a loan
  repayment as a transfer.
- Cashback: the ledger counts it as income; `TRANSACTION_CLASSIFICATION_PLAN.md`
  says it is not earned income.
- Home and Trends show an income-only "Money in" beside "Spent", so Surplus
  stays income minus spending. Only Activity's header uses Money in = income +
  investment returns.
- The Money in screen (`moneyIn()` in `sms_v2/ledger/adapters.dart`, sections
  Salary, Dividends, Refunds, Cashback, From people, Other) still excludes
  investment withdrawals and its "Total money in" leaves out refunds, so it does
  not yet equal Activity's Money in header (income + investment returns). Add an
  "Investment returns" section there to close the gap.
- Card-side figures keep counting spend the person left out of spending:
  `/monthly-reports` and the rewards or savings report use all spend as the base
  that rewards were earned on, and `/home-summary` rewards read every spend row.

## Server mapping

The server's v2 projection (`api/src/sms_v2/projection.js`) maps
`investment_withdrawal` to `investment_return`, the same as the phone's
`transactionKindForEvent`, so `spend_reports.periodTotals().investmentReturn`
is filled for SMS v2 users too. The legacy parser (`sms_parser.js`), statement
import and the observation-to-fact migration also accept `investment_return`.

## Deploy order

1. Migration `20261122000200_investment_return_entry_kind.sql`
   (enum value `investment_return`).
2. Migration `20261122000300_transaction_exclude_from_spend.sql`
   (column `exclude_from_spend`).
3. The API.
4. The app.

An app released before steps 1-3 can have its local "don't count" choice on a
server row overwritten on the next refresh, and a push carrying the new kind can
fail the enum cast.
