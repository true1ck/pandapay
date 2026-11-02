# Foreign payments — release verification, 2 November 2026

The complete feature is one update, version **1.0.16**. The iPhone candidate
uses build **105**. The implementation plan is
`foreign-payments-complete-release-plan-2026-11-02.md`.

## Delivered behavior

Foreign purchase evidence has its own durable account-scoped storage until an
actual INR posting is known. Activity, Home, detail and review show original
currency, frozen historical INR estimates, missing-price states, rate date and
source. Categories remain purchase-purpose categories. Estimates never enter
the INR transaction ledger, reward caps, milestones or confirmed spending.

Editing the original amount, choosing its category, entering actual billed INR,
dismissing and restoring work through a durable local outbox. Independent
payments continue syncing when another payment fails. Replays preserve manual
corrections. Later bank/statement evidence links one purchase only when source
amount evidence or an exact reference and saved account identity support it.
User confirmation uses the canonical INR writer atomically and idempotently.
Its distinct confirmation key cannot resurrect an old ignored credit-limit row.

Statement rows with both original currency and explicitly billed INR preserve
both amounts; a foreign-only amount is never relabelled as INR. Refunds are
separate non-income movements, with optional original-purchase linkage, rather
than additional expenses. Pending estimated refunds do not reduce confirmed
spending. Reference estimates exclude any unconfirmed issuer fees.

Bank limits, balances, outstanding amounts and obligations cannot replace a
purchase price in built-in, downloaded or AI parsing. Limit-change notices with
no payment verb are included in existing-data correction. Untouched source-backed
rows use the normal reversible ignore/state-reversal path. A separate typed-fact
server audit pages through history with durable account-specific progress and
reports unavailable evidence explicitly. Notes, tags, overrides and pending edits
are protected. Corrected ledger state invalidates dependent views, and stale
automatically detected subscriptions lose unsupported historical charge evidence.

Rates are retrieved from a fixed public Frankfurter endpoint using currency and
historical date only. Bounded requests, validation, a database cache, retry delay
and immutable rate snapshots handle outages without inventing amounts. Currency
accounting precision uses the shared SIX ISO 4217 list, not locale display/cash
rounding. Raw SMS stays on the device. `USD .00` remains an unknown original
price; a daily reference rate cannot recover its missing digits.

Portable server backups include current foreign payments and source aliases.
Correction-event history remains in paired PostgreSQL backups. Existing archives
without the additive sections remain accepted. Pending local foreign mutations
block a backup from being incorrectly labelled complete.

## Validation before release

- Full Flutter suite: **2,672 passed**, two opt-in private-data replays skipped.
- Final focused foreign-data/review/widget suite: **67 passed**.
- Full API suite: **1,414 passed**, four optional database checks skipped in the
  ordinary run. The new PostgreSQL check runs separately and is also enabled
  in the API CI job with an isolated PostgreSQL 17 service.
- Real PostgreSQL 17: migration and reapplication, RLS across accounts,
  immutable estimates, protected corrections, concurrent confirmation retry,
  canonical-write rollback, statement reconciliation, refunds and ledger edits
  passed.
- Deployment order tests: **22 passed** in Linux with the production Bash
  semantics. macOS system Bash 3.2 does not support the deployment script's
  empty-array/nounset behavior and is not a production execution target.
- Migration inventory/diagnostic checks: **9 passed**.
- Native iPhone SMS/history/background recovery regression checks passed.
- App analysis: no errors or warnings; existing informational lints remain.
- Historical provider contract: a real USD/INR response validated against its
  requested date and pair.

Build, installation and hosted deployment outcomes must be recorded from their
actual results. This document's source validation alone does not assert that a
mobile-store rollout or production deployment has finished.
