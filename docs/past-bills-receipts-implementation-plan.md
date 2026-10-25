# Past Bills & Receipts — Detailed Implementation Plan

Status: Planning

## 1. Objective

Preserve completed bill evidence and merchant e-bills without breaking the existing Bills & Commitments screen or double-counting spending.

Examples:

- An Apollo Pharmacy e-bill for ₹413.10 is paid purchase evidence, not an unpaid bill.
- A credit-card statement can be an open bill, a paid historical bill, or an ambiguous historical bill.
- A payment may match an existing transaction, but an unmatched receipt must not automatically create a second transaction.

The feature will keep current obligations on the existing Bills & Commitments screen and provide a separate `Past bills & receipts` page for complete history.

## 2. Product decisions

### 2.1 Preserve the current screen

Do not replace the existing hierarchy:

1. AutoPay authorizations
2. Credit cards
3. Scheduled payments

Add only a compact section below Scheduled payments:

```text
Past bills & receipts                         View all ›
Apollo Pharmacy                         ₹413.10
Paid · Linked                              28 Sep
```

Show at most the latest two or three historical items. If there are no historical items, omit the section rather than showing an empty card.

### 2.2 Separate current obligations from history

The current page remains focused on money that may require action. Historical items must not affect:

- Payments Due counts
- overdue warnings
- current bill totals
- spending totals unless the user explicitly saves an unmatched receipt as a transaction

The full archive opens through `View all` on a separate page.

### 2.3 Status vocabulary

Use explicit statuses rather than a generic `Paid` label:

- `paid_linked` — receipt/bill is linked to an existing transaction or payment.
- `paid_unlinked` — paid evidence exists, but no canonical transaction is linked.
- `partially_paid` — one or more payments cover only part of an obligation.
- `historical_unpaid` — an old bill exists and no payment was found; this is not the same as a current due bill.
- `needs_confirmation` — evidence is insufficient or multiple payments are plausible.
- `user_saved_purchase` — user explicitly converted unmatched receipt evidence into a transaction.
- `ignored` — user dismissed the evidence; preserve a lightweight decision record for replay safety.

The compact chip can display:

- `Paid · Linked`
- `Paid · Unlinked`
- `Partially paid`
- `Payment not detected`
- `Needs confirmation`

## 3. Domain model

### 3.1 Paid receipt / historical bill entity

Introduce a local durable entity, preferably `local_paid_receipts` or a general `local_bill_evidence` table. Do not overload `local_commitments`, because commitments represent future or recurring obligations.

Suggested fields:

```text
namespace                 owner/cache scope
id                        stable source/evidence id
source_key                original SMS/source identity
kind                      merchant_receipt | card_statement | utility_bill | other
merchant_name             normalized display merchant/biller
sender                    sender/header for evidence
amount_paise              printed amount
minimum_amount_paise      optional minimum due
currency                  INR initially
purchase_date             printed date when available
statement_date            optional
due_date                  optional
received_at               SMS receive time
card_last4                optional
account_last4             optional
linked_transaction_id     optional canonical spend transaction
linked_payment_ids        zero or more bill-payment transaction ids
status                    status vocabulary above
match_confidence          exact | strong | confirmed | ambiguous | none
match_reason              structured reason code
source_body_local         raw evidence, device-only
parser_version            parser/fact version
created_at / updated_at   local lifecycle timestamps
archived_at               optional
user_note                 optional
```

The raw SMS remains local-only. Server AI may receive only the existing redacted payload and validated structured facts. The server must not become the source of truth for the raw historical receipt.

### 3.2 Bill versus receipt semantics

Use message evidence to decide the domain type:

| Evidence | Domain result |
|---|---|
| `amount due`, `minimum due`, `outstanding`, `due date` | bill obligation |
| `statement generated`, `bill ready`, `statement available` | bill statement |
| `purchase`, `thank you`, `download your bill`, `invoice for ₹X` | paid receipt/e-bill |
| `bill payment successful`, `paid your card bill` | bill payment |
| `AutoPay registered`, `consent approved` | mandate/authorization |
| `amount deducted` for a service fee | posted transaction |

An e-bill is not automatically an unpaid bill. A receipt with no due/statement language should be stored as paid evidence.

## 4. Matching and reconciliation

### 4.1 Matching priority

Use deterministic matching after parsing. Gemini can extract fields, but must not be the final authority for linking money.

Apply rules in this order:

1. Exact bank/reference/UTR identifier.
2. Merchant or biller + amount + card last-four + date window.
3. Merchant or biller + amount + account last-four + date window.
4. Merchant + amount + close date when exactly one candidate exists.
5. Same amount and same date only when there is exactly one eligible candidate and no contradictory evidence.

Same amount and same date alone must never win when multiple candidates exist.

### 4.2 Candidate constraints

Only consider:

- active canonical transactions;
- spend transactions for merchant receipts;
- transfer/card-bill-payment transactions for card statements;
- transactions in the correct date window;
- transactions with compatible card/account/instrument evidence;
- transactions not already claimed by another receipt, except where the receipt is an explicit duplicate delivery.

### 4.3 One-to-one matching

For ordinary merchant receipts:

```text
one receipt -> zero or one spend transaction
one spend transaction -> zero or one primary receipt
```

For bill obligations:

```text
one bill -> zero or many payment transactions
one payment -> at most one bill unless explicitly user-confirmed
```

This prevents duplicate SMS deliveries and same-day purchases from creating false links.

### 4.4 Date windows

Initial conservative windows:

- Merchant receipt/e-bill: received date ±72 hours.
- Utility/service bill payment: due date ±10 days.
- Credit-card bill payment: statement date through due date + 15 days; allow an earlier payment window when the payment explicitly names the card.
- Historical imported evidence: widen only when card/account/reference evidence is strong.

The implementation must make windows configurable constants and include the window in the stored match reason.

### 4.5 Ambiguity handling

When multiple candidates score similarly:

- do not auto-link;
- store `needs_confirmation`;
- show candidate transactions in the detail view;
- let the user choose one, save as a new purchase, or ignore.

After user selection, persist the explicit link and never replace it with a later automatic match without a deliberate correction.

## 5. Lifecycle

### 5.1 New receipt path

```text
SMS captured
  -> local parser / rule bundle
  -> receipt or bill classification
  -> extract amount, merchant, dates, card/account evidence
  -> search canonical transactions
  -> create/update local bill evidence
  -> link or mark unlinked/ambiguous
  -> remove from active Needs Review only after durable resolution
```

### 5.2 Existing Needs Review rows

On read/reconciliation:

- recognized receipts should be migrated into bill evidence;
- matched receipts become `paid_linked`;
- unmatched receipts become `paid_unlinked`, not deleted;
- old receipts must not be purged after 30 days;
- already dismissed items must not be resurrected by a late AI result;
- duplicate source keys must converge to one evidence row.

### 5.3 AI result path

Gemini may return structured facts such as:

```json
{
  "factType": "posted_movement",
  "payload": {
    "amountRole": "posted",
    "amountInr": 413.10,
    "merchant": "Apollo Pharmacy",
    "occurredAt": "2026-09-28"
  }
}
```

The app/API must then:

1. validate evidence against the message;
2. derive a receipt or transaction candidate;
3. run deterministic matching;
4. persist only the projection appropriate to the evidence;
5. keep the historical record visible even when linked;
6. remove the active review item only when the result is safely materialized.

## 6. UI plan

### 6.1 Existing Bills & Commitments screen

Preserve the screenshot’s layout and card design.

Add:

- a `Past bills & receipts` section below Scheduled payments;
- latest 2–3 rows only;
- a right-aligned `View all ›` link;
- existing card `Paid ✓` treatment unchanged;
- no new top-level tab required.

### 6.2 Past Bills & Receipts page

Header: `Past bills & receipts`

Filters:

- All
- Paid
- Unlinked
- Partially paid
- Payment not detected

Optional filters after the first release:

- card/biller
- month
- search merchant

Rows should show:

- icon based on receipt/bill/card;
- merchant or card name;
- amount;
- date;
- status chip;
- linked transaction indicator where applicable.

### 6.3 Detail view

Use a detail page or modal bottom sheet consistently with existing navigation conventions.

Display:

- amount and status;
- merchant/biller;
- statement, purchase, due, and received dates;
- linked transaction/payment;
- source evidence summary;
- confidence/match explanation in plain language;
- actions appropriate to status.

Actions:

- `View transaction`
- `Link transaction`
- `Save as purchase`
- `Mark as paid`
- `Unlink`
- `Ignore`

Do not show `Mark as paid` for a receipt whose text already proves a completed purchase unless the action is needed for an ambiguous historical bill.

## 7. Data and migration strategy

### 7.1 Local-first storage

Phase 1 should remain device-local, matching the current raw SMS and review storage model. Add a schema version and idempotent migration.

Migration requirements:

- preserve existing `local_needs_review` rows;
- migrate recognized receipt rows once;
- retain source IDs and original timestamps;
- preserve user dismissal/resolution state;
- be safe to run repeatedly;
- never delete raw local evidence during migration.

### 7.2 Server projection

Do not upload raw receipt text solely to build history. If server typed facts already exist, expose a structured historical projection endpoint later. The local app remains authoritative for raw evidence and user linking until the server projection is proven equivalent.

### 7.3 Backup and account switching

Historical receipt evidence must follow the same namespace/account isolation as local transactions. Include it in portable backup/restore only after defining privacy and raw-body retention behavior.

## 8. Implementation phases

### Phase A — Domain and storage

- Add receipt/history status enums and model.
- Add `local_paid_receipts` or `local_bill_evidence` schema.
- Add migration and repository CRUD.
- Add stable identity and duplicate-source handling.
- Replace 30-day receipt deletion with archival.

### Phase B — Matching engine

- Extract merchant, amount, dates, card/account suffix, reference.
- Add deterministic candidate scoring.
- Add one-to-one claiming and ambiguity handling.
- Persist match reason and confidence.
- Add reconciliation when transactions arrive after the receipt.

### Phase C — Existing flow integration

- Update `NeedsReviewRepository.fetchAll` and resolution paths.
- Update local SMS import store.
- Connect existing commitments and card-bill ledger without changing spend totals.
- Ensure matched receipts leave active review but remain historical.

### Phase D — UI

- Add compact preview section to Bills & Commitments.
- Add `Past bills & receipts` page.
- Add detail view and actions.
- Add status chips and empty/loading/error states.

### Phase E — AI integration

- Map validated Gemini facts into receipt/bill evidence.
- Keep AI suggestions reviewable.
- Never allow model output to bypass deterministic matching or user overrides.
- Add queue/reconciliation diagnostics.

### Phase F — Rollout

- Ship behind a local feature flag if needed.
- Backfill existing local receipt review rows once.
- Compare counts before/after migration.
- Monitor duplicate links, unmatched rate, and user corrections.

## 9. Test plan

### 9.1 Model and serialization

- serialize/deserialize every status;
- unknown status falls back safely;
- optional dates and card/account suffixes survive round trips;
- raw SMS remains local-only;
- namespace isolation prevents cross-account reads;
- stable IDs survive app restart.

### 9.2 Classification

- Apollo purchase e-bill becomes `paid_receipt`;
- `view bill`, `invoice`, and `thank you for purchase` are receipt evidence;
- amount-due/statement messages remain bill obligations;
- card-bill payment messages remain transfers/bill payments;
- Jio retention charge becomes posted transaction/service charge;
- OTP, promotion, delivery, and pure service alerts do not become receipts;
- receipt with appended promotion still remains a receipt;
- missing amount remains reviewable and is not auto-saved.

### 9.3 Matching

- exact reference links correctly;
- merchant + amount + card suffix links correctly;
- merchant + amount + account suffix links correctly;
- same merchant but different amount does not link;
- same amount but different merchant does not link;
- same amount and same date with two candidates becomes ambiguous;
- same amount and same date with one candidate links;
- card mismatch blocks automatic linking;
- account mismatch blocks automatic linking;
- outside-window transaction does not link;
- duplicate SMS delivery produces one receipt row;
- one transaction cannot be claimed by two unrelated receipts;
- explicit user link wins over automatic matching;
- late-arriving transaction reconciles a previously unlinked receipt;
- deleting/archiving a transaction does not silently create a replacement link.

### 9.4 Bill payment and partial payment

- full card payment marks bill paid;
- payment above printed amount marks bill paid with tolerance;
- one partial payment leaves remaining amount;
- multiple partial payments aggregate once;
- payment made before statement generation can link only with strong card/reference evidence;
- payment with ambiguous card attribution remains unlinked;
- bill payment does not count as ordinary spending;
- receipt purchase does count only when its transaction exists or the user saves it.

### 9.5 Lifecycle and migration

- old receipt is archived, not deleted;
- matched old receipt becomes `paid_linked`;
- unmatched old receipt becomes `paid_unlinked`;
- migration is idempotent;
- migration rollback preserves original review rows;
- dismissed review rows are not resurrected;
- AI completion cannot overwrite user link/ignore decisions;
- account switch cannot expose another account’s receipts;
- backup/restore preserves IDs and links where supported.

### 9.6 UI/widget tests

- current Bills & Commitments sections render unchanged;
- preview section hidden when history is empty;
- preview shows latest 2–3 items;
- `View all` opens Past bills & receipts;
- filters return correct statuses;
- paid chip has correct wording and color;
- linked receipt opens transaction details;
- unlinked receipt exposes Link/Save/Ignore actions;
- ambiguous receipt lists candidate transactions;
- partial payment shows paid and remaining amounts;
- empty, loading, offline, and error states render safely;
- long merchant names and large amounts do not overflow;
- accessibility labels describe status and action;
- back navigation returns to the same scroll position where supported.

### 9.7 Regression tests

- existing credit-card bill paid state remains correct;
- current Payments Due list is unchanged for open bills;
- AutoPay authorizations are not converted to paid receipts;
- commitments/subscriptions are not duplicated;
- activity and spending totals remain unchanged for linked receipts;
- duplicate SMS imports remain idempotent;
- all existing SMS parser, Needs Review, card ledger, and pending bill tests continue to pass.

## 10. Acceptance criteria

The feature is ready when:

1. An Apollo-style paid e-bill is retained as historical paid evidence.
2. A matching transaction links automatically without creating a duplicate.
3. An unmatched receipt remains visible as `Paid · Unlinked`.
4. Current Bills & Commitments layout remains intact.
5. Full history is available through `View all`.
6. Same-day/same-amount ambiguity never auto-links incorrectly.
7. Historical receipts never appear as current unpaid bills.
8. Bill payments do not inflate spending totals.
9. User links and dismissals survive AI retries, app restart, and reconciliation.
10. The full focused test suite passes, including migration and account-isolation tests.

## 11. Recommended first implementation slice

Start with local storage and migration, then integrate the existing receipt matching logic. Do not begin with Gemini or the new page. The first slice should prove:

```text
Apollo SMS -> paid_unlinked or paid_linked -> historical row -> no duplicate spend
```

Once that is stable, add the preview section and `View all` page. AI extraction and broader bill families can then feed the same durable model without changing the UI contract.
