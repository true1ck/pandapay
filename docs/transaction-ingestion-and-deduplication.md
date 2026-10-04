# Transaction ingestion, provenance, and count-once behavior

Last verified: 9 September 2026

This document is the implementation contract for transaction data used by Activity, Insights, budgets, recurring payments, spend reports, rewards, caps, milestones, points, and fee-waiver progress.

## Core invariant

One real-world financial event may be observed through several channels, but it must contribute to totals and card state at most once.

All consumers use the canonical `transactions` table and count only rows whose `status = 'active'`. Every channel observation is recorded separately in `transaction_observations`; raw SMS bodies, raw email bodies, Gmail access tokens, statement PDF bytes, and PDF passwords are not stored there.

```text
Manual / SMS / forwarded email / IMAP / statement
                         |
                         v
          exact retry identity + per-user lock
                         |
                         v
               cross-source comparison
                    /             \
             no candidate       likely duplicate
                  |                    |
            active row          ignored row + review
                  |                    |
          Insights/rewards      excluded from totals
                                       |
                              merge or keep both
```

## Connected sources

| Source | Transaction ingestion | Exact retry protection | Cross-source dedup | Notes |
|---|---:|---:|---:|---|
| Manual / Quick Add | Yes | `clientMutationId` | Yes | An unchanged retry keeps the same id and timestamp. The offline outbox also preserves card-less cash/UPI/income/investment/transfer fields. |
| Live SMS | Yes | Hash of profile, sender, body, and original SMS timestamp | Yes | The Android message timestamp is sent, not upload time. |
| SMS backup XML | Yes | Same message hash | Yes | `sms` and `sms_bulk` are one source family, so repeat backup imports rely on exact identity rather than a risky heuristic. |
| Email forwarding webhook | Yes | Profile-salted normalized-content hash | Yes | A provider retry or second forwarding of the same content stays one transaction; only a one-way hash of provider message ID is provenance, not identity. One canonical webhook route; the old shadow route was removed. |
| IMAP poller | Yes when the poller is enabled | Connection ID + IMAP UID, server-hashed | Yes | Requires deployment configuration and an active connection. |
| Statement PDF | Yes | Server-wrapped SHA-256 of local PDF bytes, plus line index | Yes | PDF and password stay on-device; only reviewed structured rows are uploaded. Credit (`Cr`) rows are not imported as spend. |
| Direct Gmail OAuth | Card discovery only | Not applicable yet | Not applicable yet | Raw messages and token currently stay on-device by explicit consent. See the planned work below. |

## Exact retries

Exact identity handles network retries and repeated imports without heuristics:

- Quick Add generates one UUID and captures one occurrence timestamp before the HTTP request. An unchanged retry and the offline outbox keep both values. The API returns the already-created canonical transaction with HTTP 200.
- SMS identity includes the original bank-message timestamp, so two genuine identical purchases can remain separate while the same exported message cannot be imported twice.
- Forwarded email identity uses normalized sender, subject, and body, so it is stable across webhook retries, line-ending/whitespace-only transport changes, and a different provider ID on re-forwarding.
- IMAP identity uses mailbox connection plus UID.
- Statement identity starts with a digest of the local file and adds a stable line index.

The database enforces exact uniqueness with `transactions(profile_id, source_key)` and records each source in `transaction_observations`.

## Cross-source matching

The heuristic runs only for spend from different source families. It rejects the match when both sides provide contradictory card, instrument, merchant, amount, or timing evidence.

Evidence includes:

- amount difference no greater than ₹1;
- event time no more than 36 hours apart;
- same card when both channels know the card;
- exact normalized merchant name, or conservative containment for a meaningful merchant token;
- extra weight for close timestamps and independent channels.

A score below `0.72` is retained as an ordinary active transaction. A score at or above it creates a pending `duplicate_candidates` row and marks the newly-arriving row `ignored` before reward or card state is applied. There is no hidden auto-merge.

## Review outcomes

- **Keep both** reactivates the temporarily suppressed row and applies its card state once, unless it is a historical backfill.
- **Merge** or **delete one** keeps the selected canonical row, reverses the dropped row only if its state had actually been applied, and reattaches every `transaction_observations` record to the survivor.
- Other pending candidates involving a dropped row are resolved so stale review cards are not left behind.

`transactions.state_applied` prevents reversing state that a suppressed or historical row never contributed. `transactions.is_backfill` prevents historical statement/SMS imports from changing the current cycle's cap, milestone, points, or fee-waiver counters.

## Parser behavior

Configured `parser_patterns` are ranked by sender specificity, extracted-field completeness, and version. The engine no longer accepts whichever matching row happens to be first.

When no configured row matches, a conservative fallback can parse ordinary card-spend messages. It requires currency, amount, spend wording, and card evidence. OTPs, verification codes, due notices, credits, refunds, reversals, declined/failed messages, and account-only debit messages are rejected. Unparsed foreground and background SMS messages remain in the on-device Needs Review queue; anonymized shapes continue to feed server parser telemetry.

## Downstream features

The count-once rule applies automatically to existing consumers because they read active transactions:

- Activity and transaction search;
- Insights overview, spend trends, category totals, and monthly savings;
- budgets and recurring/subscription detection;
- monthly reports and exports;
- card rewards, cap consumption, milestones, points ledger, and fee-waiver progress;
- merchant/category history used to improve later imports.

`transaction_observations` is provenance, not another spend table. Consumers must never sum observations.

## Remaining planned work

These are explicit remaining items, not features claimed as complete:

1. **Direct Gmail transaction sync:** add an opt-in distinct from card discovery. Parse on-device, upload only structured amount/date/merchant/card suffix plus a server-wrapped Gmail message identity, and update the consent copy before enabling it. Do not upload raw email or OAuth tokens.
2. **One visible Needs Review queue:** the app's unparsed-SMS queue is on-device while confidently parsed-but-unresolved server messages use `needs_review_items`. Add owner-scoped list/resolve APIs and a combined UI without moving raw SMS off-device unexpectedly.
3. **Production parser catalogue:** the production database audit found zero active parser patterns. The conservative fallback prevents total failure, but issuer-specific patterns still need seeded, versioned coverage and telemetry-based promotion.
4. **Historical reward reconciliation:** statement rows are confirmed spend and appear in Activity/Insights totals, but precise historical cap-aware reward reconstruction requires chronological replay within each old billing cycle. Do not fabricate those reward values from today's cap state.
5. **Legacy duplicate audit:** the new logic protects new writes. Run a dry-run report over pre-migration active rows, review the proposed pairs, then migrate provenance/suppress rows only after approval.
6. **IMAP production decision:** either enable and monitor `IMAP_POLL_INTERVAL_MINUTES` with encrypted credentials, or remove the setup UI and standardize on forwarding. Do not label a login-only deployment as syncing.

## Deployment and verification

Required migrations:

- `20260908195414_canonical_transaction_ingest.sql`
- `20260908201228_statement_transactions_ingest.sql`

Apply migrations before deploying the API and app. The API expects the new columns/table immediately.

Verification performed locally:

- backend suite: 235 tests passed;
- focused transaction/parser tests include exact retries, conservative parsing, contradiction rejection, time windows, source families, and candidate selection;
- 52 focused Flutter tests passed, covering outbox identity/migration, Quick Add retries, background queue, statement parsing/import, and credit-row exclusion;
- end-to-end local API/database check submitted the same ₹499 event through manual entry, forwarded email, SMS, and statement: one active ₹499 transaction, one points entry, four observations, and all observations attached to the selected canonical transaction after review;
- a second live check delivered the same forwarded email twice with different provider IDs, then submitted the same purchase manually and by SMS: one active ₹499 transaction and one reward entry remained; manual/SMS copies were reviewable suppressed candidates, and an exact SMS retry added no row;
- decimal reward/cap values such as ₹24.95 are explicitly bound as PostgreSQL numeric values, avoiding the previous integer-inference rollback.
