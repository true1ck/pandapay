# Transaction classification and totals plan

## Scope and UI boundary

This is a **functional correctness** project. Another person is modifying the UI; implement against the latest UI code and do not redesign screens, change layouts, navigation, labels, icons, filters, or color palettes as part of this work. Preserve existing presentation contracts where possible. The backend and app data layer must expose reliable classifications and totals so current and future UI can consume them. If the latest UI already has a kind-based color hook, wire the correct kind into it; otherwise record an optional visual follow-up without making UI work a dependency of classification correctness. Coordinate any necessary screen edit against the latest branch before touching it.

## Goal

Classify each economic event once, persist that decision, and use it in Activity, Insights, budgets, reports, rewards, search, imports, and offline views. A purchase counts once as spending. Moving owned money, settling debt, receiving a refund, or borrowing money does not become spending or earned income merely because an SMS says debited or credited.

## Current state and gap

- `transactions.entry_kind` is `spend | income | investment | transfer`. Spend reports and Insights filter to active `spend` rows. Activity's Money in sums active `income`; Money out sums active `spend` plus `investment`. These existing calculations need to consume the same canonical classification and metric projection; presentation changes are outside this plan.
- Server and local SMS parsers recognize some bill payments and explicitly worded self transfers. A plain destination-bank credit can still become `income`; an unfamiliar debit can become `spend`.
- Refunds and cashback can be classified as `income`, though neither is earned income. Current kinds lack debt, refund, reward, and uncertainty semantics. The system also needs an explicit link between the two sides of a transfer and between a refund and its purchase.
- Manual corrections exist, but classification should be shared by all capture paths and propagated to every aggregate after a correction.

## Product definitions

Maintain separate, clearly named metrics:

1. **Gross purchases**: completed purchases and actual service costs, once per event.
2. **Net spending**: gross purchases minus linked refunds/reversals and optional linked shared-expense reimbursements. This is the primary budget metric; make the value available to existing consumers.
3. **Earned income**: wages, business receipts, interest, dividends, rent received, and similar earnings. Gifts are a separate inflow.
4. **Money received / money sent**: account cash-flow metrics. They may include transfers, loans, and refunds; never use them as spending or earned-income calculations.
5. **Transfers, investments, borrowing/debt settlement, rewards, and adjustments**: separate breakdowns. Investment proceeds need principal/gain treatment when known.

The time period uses the economic event date in the user's timezone. Card spending occurs at purchase, not bill payment. A refund adjusts spending when it settles; historical purchase reporting may additionally expose the linked original date in the data contract.

## Canonical transaction model

Keep `entry_kind` during migration for compatibility, but introduce a versioned classification object shared by server and local storage:

- `direction`: in / out / neutral; `instrument` and owned account/card identity.
- `economic_kind`: purchase, fee, earned_income, gift, own_transfer, card_repayment, loan_principal, loan_disbursement, investment_contribution, investment_proceeds, refund, reversal, reimbursement, reward, cash_withdrawal, cash_deposit, unknown.
- `status`: pending, posted, failed, reversed, ignored, duplicate; retain source and original text reference under existing privacy rules.
- `classification_source`: parser rule, matched pair, user correction, statement, manual; `confidence`, rule/version, and review reason.
- Relationship/group IDs: transfer pair, original purchase for refund/reversal/reimbursement, loan or EMI group, duplicate cluster. Preserve both observed bank rows while counting the economic event once.
- Explicit metric flags should be **derived from kind and relationship**, not independently edited booleans. One shared function returns contributions to gross spend, net spend, earned income, cash flow, investments, and reward eligibility.

Avoid treating a merchant category as the economic kind. `Wallet Load` is a movement purpose, while `Dining` is a purchase category. A fee attached to a transfer must remain a separate spending component.

## Classification pipeline

1. Normalize every source (live SMS, bulk SMS, email, CSV/PDF statement, manual, scan, voice) into one observation shape: amount, direction, account suffix and issuer, counterparty, reference/UTR, event time, completion state, source ID, and raw wording where allowed.
2. Detect non-events first: OTP, offers, due reminders, pending/failed transactions, balance-only alerts. Do not create posted financial events from these.
3. Deduplicate repeated alerts for the *same side* across SMS/email/statement. Do not mistake equal-amount opposite-side transfer alerts for duplicates.
4. Classify explicit high-confidence patterns: card repayment, own-account transfer, merchant purchase, salary, refund, investment, loan, fee, etc. Keep server and offline implementations on a shared fixture corpus and identical taxonomy; prefer a shared data-driven rule definition where feasible.
5. Resolve ownership and pair related entries. Match by exact reference/UTR first, then owned source/destination account identities, compatible amount, direction, and time window. Require enough evidence; matching amount and time alone is insufficient. Account last-four alone is not globally unique.
6. Link refunds to purchases using card/account, merchant, reference, amount, and date; support partial refunds and multiple refunds. Link reimbursements only with user confirmation or strong explicit evidence.
7. Put ambiguous credits/debits into the existing review mechanism. They can remain in transaction history and account cash flow, but must not silently inflate earned income or spending. Reuse existing correction APIs where possible; save a user choice as an override with an audit trail.
8. Recompute derived state transactionally after classification or linking changes: budgets, Insights, rewards/caps, recurring detection, reports, cached summaries, and offline sync. Reversing an old classification must reverse its old reward/cap contribution before applying the new one.

## Core scenario matrix for tests

| Event | Spend | Earned income | Other treatment |
| --- | ---: | ---: | --- |
| ₹80,000 card laptop purchase then ₹80,000 card payment | ₹80,000 | ₹0 | Repayment excluded |
| Canara debit and HDFC credit, both owned | ₹0 | ₹0 | One linked self transfer, two account legs |
| HDFC credit from unknown Canara sender | ₹0 until reviewed | ₹0 until reviewed | Unclassified incoming; do not assume self transfer |
| Wallet top-up then merchant purchase | Purchase only | ₹0 | Top-up excluded |
| ATM withdrawal then later cash purchase | Cash purchase only | ₹0 | Withdrawal excluded |
| ₹1,000 purchase then ₹400 refund | Net ₹600 | ₹0 | Linked partial refund |
| Card cashback ₹100 | No new purchase | ₹0 | Reward shown separately |
| Salary ₹50,000 | ₹0 | ₹50,000 | Earned income |
| Loan ₹50,000 received then principal repaid | ₹0 | ₹0 | Liability movement; interest/fees are costs |
| Investment contribution then redemption | ₹0 consumption spend | Gain only if established | Track principal separately |
| Friend reimburses part of shared bill | Gross purchase unchanged | ₹0 | Optional confirmed net-cost adjustment |
| Failed debit then reversal | ₹0 | ₹0 | Cancel linked movement |
| SMS plus statement for same purchase | Once | ₹0 | Cross-source duplicate |

Add cases for partial card payments, EMI principal/interest, card statement credits, rewards applied to bills, cash deposits, merchant UPI addresses that look personal, two owned accounts at one bank, reused last-four digits, delayed SMS, two identical purchases, split payments, foreign exchange amount differences, and fees on transfers.

## App-wide data integration (no screen redesign)

- **Activity data source:** supply canonical kinds and metric totals to existing widgets. Preserve current layout and styling. Make unknown amount/count available to existing review surfaces.
- **Insights, budgets, trends, category data:** consume the shared metric projection. Exclude uncertain and non-spending movements from spend; expose uncertainty count in the data model.
- **Cards and rewards:** only eligible card purchases affect earned rewards, caps, milestones, and fee waivers. Repayments, refunds, and reversals adjust card state according to linked transaction and issuer rules.
- **Home and notifications:** use the same totals and classification fields; no independent debit/credit arithmetic. Preserve current copy and visual structure.
- **Import and manual edit data paths:** persist proposed kind, evidence/confidence, and correction; reuse existing review and transaction-edit controls. Any new control is a separately coordinated UI task.
- **Offline:** persist the same canonical kind, relationship, version, and user override; sync conflicts must preserve user corrections over parser reruns.

## Delivery order

1. **Metric contract and fixtures:** define names and exact arithmetic; create the scenario corpus and inventory every total/query. Baseline test totals before migration.
2. **Schema and classifier:** add canonical fields, relationship tables/IDs, ownership registry, rule version, review state; centralize metric projection and adapters from legacy `entry_kind`.
3. **Capture and matching:** normalize all import paths; add explicit detection, transfer pairing, refund linking, confidence thresholds, and duplicate separation. Prove server/local parity with the same fixtures.
4. **Reporting and app data integration:** replace each independent aggregate with the projection, retain existing UI structure, and invalidate caches after classification changes.
5. **Historical reconciliation:** dry-run old rows, show proposed changes and totals impact, auto-update only high-confidence matches, queue uncertain rows. Make batch changes reversible and idempotent.
6. **Verification and rollout:** unit fixtures, database aggregation tests, offline/sync tests, end-to-end examples, and production telemetry on unknown classifications and user corrections. Roll out behind a versioned migration and compare old/new totals before making the new projection authoritative.

## Acceptance gates

- The laptop/card-payment example totals ₹80,000 spending across all app screens and reports.
- Both sides of a confirmed owned-account transfer remain visible and contribute ₹0 to spending and earned income.
- An unmatched incoming bank credit never becomes earned income by default.
- Refunds, reversals, and duplicates cannot increase earned income or create a second purchase.
- Activity, Insights, budgets, Home, exports, and offline views reconcile to the same filtered transaction set for the same period.
- User corrections survive import replay, parser upgrades, offline sync, and historical backfill.

---

## Implementation specification: invariants and terminology

This section is normative. If a rule below conflicts with a heuristic, the invariant wins.

1. An **observation** is one SMS, email, statement line, or manual report. An **account leg** is one debit or credit in an account ledger. An **economic event** is the purchase, transfer, refund, debt settlement, etc. Several observations may describe one account leg; a transfer has at least two legs but one economic event. Do not collapse these three concepts.
2. `amount_inr` is a positive integer number of paise internally, with a separate direction. Never infer direction from merchant name or signed display text. Preserve original currency and amount for foreign transactions; INR conversion is a separate amount with rate/source/date.
3. No posted event may contribute to more than one of purchase, earned-income, investment-principal, transfer-principal, or debt-principal categories. A compound event may contain separate components, such as ₹10,000 EMI principal plus ₹500 interest. Components must add to the bank leg amount.
4. User-confirmed classification and account ownership outrank automated parsing. Parser upgrades may propose a change but cannot overwrite a user correction silently.
5. Duplicates are observations of the **same account leg**. A debit from Canara and credit to HDFC are paired legs of a transfer, never duplicates.
6. No alert with only `pending`, `initiated`, `scheduled`, `due`, `failed`, `declined`, `rejected`, or `reversed` wording is a completed purchase/inflow. A later posted notification may promote the same event. A true reversal is a separate linked adjustment or a reversal status, not earned income.
7. A classification can be `unknown` and still show in Activity. Totals must disclose excluded unknown debit/credit amounts and counts; otherwise conservative classification could create a misleadingly low spend/income number.
8. A transfer is classified by **ownership of both endpoints**, not by the word `transfer`. UPI payments to merchants or other people are purchases/outflows. A name match alone never proves ownership.

### Exact metric projection

Implement one pure, versioned projection function `projectFinancialEvent(event, components, relationships) -> metric deltas`. Use integer paise and emit a reason code. Server SQL/reporting and Flutter/offline code must consume this result or share a generated rule table; avoid separate handwritten switch statements. The projection is the source of truth for all surfaces.

| Kind/component | Gross spend | Net spend | Earned income | Cash sent/received | Other |
| --- | ---: | ---: | ---: | --- | --- |
| Posted merchant purchase, bill for goods/services, tax, gift/donation paid, fee, interest cost | +amount | +amount | 0 | Out on actual bank/wallet leg; card purchase is card liability, not bank cash out yet | Category and card attribution |
| Posted refund of purchase | 0 | -amount, capped at linked eligible purchase total | 0 | In if credited to bank/wallet; card credit is liability reduction | Link original |
| Full void/reversal of purchase | Cancel/reverse original purchase exactly once | Cancel/reverse original | 0 | Reverse original leg if applicable | Keep audit history |
| Earned income | 0 | 0 | +amount | In on account leg | Income category |
| Own transfer, wallet load, cash withdrawal/deposit, card principal repayment, loan principal movement | 0 | 0 | 0 | Count each actual account leg in cash flow; never in earned income | Relationship/group |
| Investment purchase/contribution | 0 | 0 | 0 | Out on bank/wallet leg | +investment contribution |
| Investment sale/redemption | 0 | 0 | Only verified realized gain if the product explicitly supports tax/basis accounting; otherwise 0 | In on bank/wallet leg | Principal/proceeds separately |
| Cashback/reward | 0 | 0 by default | 0 | In only if real account credit | Reward total; optional separate effective-cost view |
| Gift received, loan disbursement, reimbursement | 0 | 0 by default | 0 | In if posted | Separate inflow; confirmed shared-expense reimbursement may reduce personal-cost view, not gross spend |
| Unknown debit/credit | 0 pending review | 0 pending review | 0 pending review | Cash-flow direction only if a posted account leg is certain | Unknown amount and count |

Negative net spend for a period is allowed when a prior-period purchase is refunded now; expose the linked refund and original purchase in the data. Never clamp period net spend to zero. Prevent over-refunding an individual purchase unless the excess is separately classified (for example compensation). Gross spend is a posted-purchase measure and remains at purchase date; refunds adjust net spend on refund date. Budgets use net spend by default.

### Direction, status, and account identity

Store `occurred_at` (bank event time), `observed_at` (notification/import time), and `posted_at` if available. Date-only statement rows carry date precision rather than a fabricated midnight time. Use profile timezone for calendar buckets. Do not pair solely because two date-only rows share a date and amount.

Create an owned financial-account registry (bank account, wallet, cash pocket, credit-card liability, loan liability, investment account) with stable user-scoped IDs, issuer, instrument, masked suffix, aliases/senders, verification source, ownership state (`confirmed`, `suggested`, `rejected`), and active dates. Existing bank-account summaries are inferred from SMS and should seed **suggestions**, not automatically verified owned accounts. The same four digits can belong to multiple accounts or cards. Require issuer plus suffix and user confirmation or strong account metadata for ownership. Never store full account/card numbers for this feature.

Use a relationship table with `relationship_type` (`same_leg_observation`, `transfer_pair`, `repays_card`, `refunds_purchase`, `reverses_event`, `reimburses_purchase`, `investment_redemption`, `loan_payment`, `emi_component`), both event/leg IDs, matched amount in paise, source (`automatic`/`user`), evidence codes, confidence, and timestamps. Unique constraints must prevent one posted leg from being paired with two unrelated transfers; allow multiple partial refunds against one purchase. Reject cross-profile links at database and API layers.

### Classification result contract

For every candidate, return:

```text
kind, direction, lifecycle_status, amount_paise, account_id?, counterparty?,
category_id?, effective_at, date_precision, evidence_codes[], confidence,
review_reason?, parser_version, candidate_relationships[], user_locked
```

Confidence is a decision tier, not an uncalibrated decimal: `confirmed_by_user`, `high`, `review`, `unknown`. An `automatic` result must cite explicit wording or verified ownership/relationship evidence. A generic `credited`/`debited` marker determines direction only. Preserve the candidate and its evidence for review and future rule analysis without retaining raw SMS in the ledger. Treat sender, VPA, and reference as potentially sensitive; follow existing redaction and retention rules.

## Decision order for all capture paths

Run the following stages in order; a later generic rule must not overwrite an earlier specific result.

1. **Validity and lifecycle:** reject noise; determine posted versus pending/failed/reminder. Extract each actual amount separately from available balance, credit limit, reward amount, and due amount. If an SMS contains both a transaction amount and balance, require a labeled transaction amount. A message may mention both debit and credit; parse the event clause, not the first keyword.
2. **Same-leg idempotency:** exact source key/observation hash; then cross-source duplicate candidate with same direction, owned account/card, amount/currency, reference, merchant, and event time. Conflicting reference/account is a hard reject. Repeated equal purchases must remain separate when different bank references or sufficiently distinct notification times exist.
3. **Explicit adjustments:** posted refunds, reversals, chargebacks, failed-payment returns, reward credits. Resolve the original where possible. A refund without a match stays a `refund_unlinked` review item and must not become earned income; show it separately until linked or user classified.
4. **Explicit settlement and asset movement:** card repayment, own-account transfer, cash withdrawal/deposit, wallet load, loan principal, investment funding/redemption. Extract fees/interest as separate cost components. An issuer's credit-card payment receipt describes the same repayment event as the bank debit, but is a different liability leg.
5. **Explicit earned income:** salary/payroll, pension, interest, dividend, rent received, verified business/customer receipt. Do not infer earned income from a plain incoming UPI or bank credit.
6. **Purchase or cost:** posted card merchant spend, debit-card merchant spend, UPI merchant/person payment, utility/insurance/rent/tax/donation, fees and interest. A payment to a person is a cost/outflow unless explicit evidence of own-account movement or debt/investment purpose exists. Keep category as a separate step.
7. **Pair and resolve:** use ownership registry and counterpart legs to upgrade a candidate to confirmed transfer/refund/repayment. Re-run affected projection atomically.
8. **Uncertain:** store visible unknown debit/credit and ask the smallest useful question. Do not let the fallback parser assign `spend` or `income` only because of direction.

### Pairing gates

**Automatic own transfer** requires both endpoints to be confirmed owned and at least one strong link: identical transaction reference/UTR with compatible amount and plausible time; or explicit `from your account X to your account Y` wording naming both verified endpoints. If references are absent, require a distinctive source/destination account pair, exact principal amount, narrow event window, and no competing candidate; place in review rather than auto-pair if any ambiguity remains. Never match on same amount and date alone. Support delayed incoming leg, weekends, NEFT settlement lag, and a single debit funding multiple credits only with explicit references or user confirmation.

**Card repayment** requires explicit bill/card-payment wording or a matched bank debit and card-liability credit for the user's card. A purchase at a bill-payment app is not automatically a card repayment. Partial, minimum, advance, and overpayments remain repayments; associated convenience fees are costs. Treat a card-credit alert for a refund as a refund, not a repayment.

**Refund** requires explicit refund/reversal wording or a matching merchant return/chargeback reference. Merchant, instrument, date, and amount provide candidate evidence. Multiple partial refunds may link to one purchase; one refund may cover several order components only with an allocation. Never auto-link a salary-like or ordinary person transfer because the amount matches an old purchase.

**Cashback/reward** requires explicit reward/cashback wording and actual posting. An offer promising cashback is not a transaction. A statement reward offset may reduce card liability without bank cash receipt. Points-only awards are not rupee cash flow.

## Detailed scenario catalogue

The following is the minimum fixture set. Each fixture should include SMS variants, statement variants where relevant, expected observations, canonical event/legs, links, projected metrics, and confidence. Test both server and offline paths using the same inputs.

### Purchases and fees

1. Credit/debit card POS and online purchase; card authorization followed by settlement; hold later released.
2. UPI P2M with merchant VPA; UPI P2P payment for goods/services; merchant whose display name is a person; personal VPA used by a small shop.
3. Rent, utilities, mobile recharge, subscriptions, insurance premium, tax, school fees, donations, gifts, tips, gambling, and bill payments for actual services. These count as costs/purchases even when no physical item is bought.
4. Card annual/joining/late/forex/cash-advance fee and GST, bank transfer/ATM fee, loan interest and processing fee. Separate fees from principal or transfer amount.
5. Split tender: ₹1,000 item paid ₹600 card plus ₹400 UPI; two distinct account legs, one ₹1,000 purchase when linked. Do not dedupe the two legs as identical purchases.
6. Foreign-currency purchase with INR settlement difference, dynamic conversion, later exchange adjustment, tips added after authorization. Avoid double count; preserve original and settled amounts.
7. Merchant cancellation before settlement, failed UPI payment with temporary debit then return, disputed charge and chargeback (including chargeback reversal).

### Transfers, funding, and cash

8. Same-bank own-account transfer; different-bank Canara→HDFC; joint account; transfer between two owned accounts with identical last-four digits; delayed credit; missing debit or missing credit alert.
9. UPI self-transfer, IMPS/NEFT/RTGS, auto sweep, fixed-deposit funding, bank-to-wallet top-up, wallet-to-bank withdrawal, prepaid card load, cash deposit, ATM withdrawal.
10. Credit-card bill paid from bank, wallet, another bank, or autopay; partial/minimum/advance payment; failed bill payment then refund; issuer receipt and bank debit; overpayment/card positive balance.
11. Payment to someone else's account with same surname or same bank; payment to a business via a person's VPA. Do not mark self transfer from name or bank alone.
12. Transfer fee or convenience fee bundled in one bank debit (for example ₹10,005 debit = ₹10,000 own transfer + ₹5 fee). Principal excluded; fee counted as spending.

### Incoming and adjustments

13. Salary/payroll, pension, freelance invoice, sale of goods/services, interest, dividend, rental income; income tax refund (separate tax adjustment, not salary), employer expense reimbursement (offset linked expense where possible).
14. Gift, allowance, inheritance, government benefit, insurance claim, scholarship, prize; show separate named inflow classes and avoid assuming earned income.
15. Merchant refund to original card, bank, or wallet; partial refund; store credit/gift card rather than cash refund; refund in a later month; refund greater than purchase due to compensation.
16. Cashback as bank credit, card statement credit, wallet credit, points, voucher, or promised future reward. Only posted value appears; distinguish cash from noncash benefit.
17. Friend repaying a loan versus reimbursing a shared purchase versus paying for work; same incoming UPI wording can mean different kinds and needs evidence or review.
18. Own cash deposit, investment redemption, FD maturity, bond principal and interest, mutual-fund dividend, stock sale, crypto sale. Do not label entire proceeds earned income.
19. Loan disbursement, overdraft draw, credit-card cash advance, loan principal repayment, EMI principal/interest split, debt forgiven or written off. Principal movements are not purchases or earnings.
20. Credit-card statement payment receipt, reversal, reward credit, or balance adjustment; distinguish these despite all appearing as card credits.

### SMS and source ambiguity

21. Promotional offer containing an amount and `cashback`; OTP/security alert; payment due/reminder; mandate registration; upcoming autopay; balance-only notification.
22. SMS says `debited` and `credited` in one body; transaction amount and available balance; multiple amounts (principal, fee, tax, cashback); old transaction date with new delivery date.
23. Same event from bank SMS, merchant SMS, email, statement, screenshot, and manual entry; duplicate SMS templates; two legitimate equal purchases close together; partial captures arriving offline and syncing later.
24. Bank credit names only origin bank, not account owner; account suffix missing/reused; sender ID unrecognized; VPA aliases; misspelling/transliteration; reference missing or shared across multiple legs.
25. Import row labeled `TRANSFER` without ownership proof; CSV `credit` column representing a card purchase refund, card repayment, or bank income; PDF signed amount conventions differing by issuer.

## Repository implementation map

| Area | Existing anchor | Required work |
| --- | --- | --- |
| DB ledger | `db/supabase/migrations/0004_user_domain.sql`, `0040_budgets_instruments_recurring.sql` | New additive migration for account identities, precise kind/status, relationships, classification audit, constraints/indexes; do not edit applied migrations |
| Provenance/dedupe | `20260908195414_canonical_transaction_ingest.sql`, `api/src/transaction_dedup.js` | Reuse `transaction_observations`; distinguish same-leg duplicate from paired opposite legs; preserve source keys |
| Server ingest | `api/src/index.js` transaction create/update/SMS paths; `api/src/sms_parser.js`; `api/src/statement_import.js` | One normalize/classify/link service before insert; all routes use it; reclassify atomically with reverse/apply card state |
| Offline capture | `app/lib/data/local_sms_parser.dart`, `app/lib/data/local/sms_import_store.dart`, `app/lib/data/local/financial_store.dart`, `app/lib/data/transaction_import_pipeline.dart` | Same taxonomy/fixtures and persisted provisional result; reconcile with server without overriding user edits |
| Reports | `api/src/spend_reports.js`, Activity/Insights data providers, `app/lib/app/providers.dart` | Query shared projection; expose gross/net/income/cash flow/unknown separately; remove local arithmetic drift without changing widgets |
| Corrections | `api/src/index.js` PATCH transaction, existing review/edit APIs and data repositories | Kind, account ownership, counterpart linking, correction audit and undo in the data layer; UI extensions are separate |

Migration must tolerate existing `entry_kind` and clients. New API responses include old `entry_kind` plus new classification fields during transition. Old rows map provisionally: `spend→purchase`, `income→unknown_credit` unless independently verified, `transfer→transfer_unverified` except explicit known patterns, `investment→investment_contribution` where direction is confirmed. This mapping is **not** a final historical truth and must not silently rewrite old financial meaning. A dry run reports count and rupee impact by proposed reclassification. Keep old summaries available for comparison until new totals are reconciled.

## Work packages with completion criteria

**A. Contract and inventory.** Freeze taxonomy, status semantics, projection table, period/refund policy, and unknown-total treatment in code-readable fixtures. Search every endpoint/provider/widget for sums of `amount_inr`, `entry_kind`, and transaction status. Produce an owner checklist; no aggregate may be left with implicit old semantics.

**B. Additive schema and API.** Add account identity, classification, relationships, and audit storage; RLS/profile constraints; indexes on profile/date/kind/account/reference; idempotent ingest. Expose normalized classification and candidate links. Reject invalid cross-user or over-allocated links.

**C. Pure classifier and linker.** Build parser-independent normalization and projection, then explicit deterministic rules, then conservative matching. Every rule returns evidence and confidence. No generic debit/credit fallback to purchase/income. Separate same-leg dedupe and opposite-leg pairing.

**D. Capture path migration.** Route live/bulk SMS, email, statements, screenshot, manual, scan, and voice through the service. A manually chosen kind is user-locked. Re-ingest cannot create duplicate economic events or replace confirmed decisions.

**E. Correction and reconciliation.** Extend existing correction API/data operations for kind correction, account ownership confirmation, pair/unpair, refund link/unlink, split components, and undo. Use current review/edit UI only where it already supports the operation; list missing controls as a separate follow-up. On save, reverse old derived card/reward state and apply new state inside one database transaction. Offline queue carries the same edit operation/version; expose edit conflicts to the existing review mechanism.

**F. App-wide reads.** Build common projection query/provider. Activity, Home, Insights, budgets, recurring, caps/rewards, exports, notifications, and search data use canonical fields. Distinguish cash-flow legs from economic totals in returned data. Keep existing widgets and visual styling intact.

**G. History and rollout.** Run read-only proposal over existing rows; auto-apply only proof-backed cases, review the rest. Store migration version and before/after audit. Feature-flag new projected totals, compare with old reports by profile and period, then switch data providers after fixture/end-to-end parity. Keep reversible rollback of projection/read path without deleting new classifications.

**H. Verification.** For every scenario above, assert exact paise totals in server projection, SQL aggregates, local/offline projection, Activity, Insights, budgets, and export. Test idempotency, ordering (credit before debit), timezone/month boundaries, user correction persistence, duplicate conflicts, partial links, and compound fees. Add property tests: sum of components equals leg amount; same observation replay changes no totals; transfer pairing changes spend/income by zero; adding a refund never increases net spend; duplicate observation never changes totals.

Release gate: zero known contradictory totals across app data surfaces, no cross-profile links, no silent overwrite of user classifications, and an available review count/amount for unresolved entries. Track only privacy-safe rates of unknown, auto-matched, corrected, and unpaired entries; investigate high correction rates by rule version. Visual changes, including separate colors, are optional follow-up work coordinated with the UI owner.
