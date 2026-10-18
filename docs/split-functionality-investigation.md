# Split functionality review — 18 October 2026

## Local-first follow-up

Expense splits now use an account-scoped SQLite repository. The displayed document and its pending flag live in one durable row; a single statement commits both. The old response blob is migrated once, rather than maintained as a second writable source of truth. The card planner already computes locally and needs no new server calculation endpoint.

Reads return saved documents immediately. A clean document older than five minutes refreshes in the background when opened; fresh and pending reads do not issue a GET. Concurrent reads are deduplicated. A manual Refresh split action is available. A split never loaded before requires an initial online read, because an unknown server split cannot safely be assumed empty.

Saving or clearing commits locally first, then schedules a debounced push after 750 ms. Multiple edits to the same expense coalesce into its latest whole split. Pending documents drain on app startup, reconnect, resume and manual sync. No periodic clean-document polling is added. Transport requests time out after 20 seconds; temporary failures back off the entire pending set (5 seconds through 5 minutes), rather than retrying every bill against an unavailable server. Pending edits are retained indefinitely, including across sign-out; other accounts cannot read or send them. Actual OS execution while the app is terminated is not implemented; the queue resumes when the app runs again.

Each server response includes a content fingerprint. The next replacement carries that baseline. Under the parent transaction lock, the server rejects a changed baseline with HTTP 409. Identical retries are acknowledged without deleting/reinserting rows, including a retry after a lost response. Acknowledging an older in-flight save advances the baseline without removing newer local edits. GET responses cannot overwrite pending documents.

Conflicts and permanent validation failures stay local with a visible attention state. The user can review the server shares before explicitly keeping local shares or accepting the server version. Keeping local shares uses the version actually reviewed, so a further concurrent server edit produces another conflict. Pending splits count toward Sync & Backup's waiting-to-sync total. The ordinary transaction edit and generic offline transaction-sync path both reject amounts below saved server shares.

This is a whole-document outbox beside the existing generic field-edit queue: splitting individual rows through per-field last-writer-wins could merge independently valid sets into an invalid total. No additional database service or new server schema is needed. Deploy the updated API before distributing the updated app; older API versions do not enforce the new fingerprint precondition. Live PostgreSQL/phone verification remains a release check. Server load savings depend on actual usage; no benchmark or percentage reduction is claimed.

The repository boundary and local-write/background-sync approach follow [Flutter's official offline-first guidance](https://docs.flutter.dev/app-architecture/design-patterns/offline-first). The five-minute freshness interval, coalescing window and whole-document conflict policy are app-specific choices.

Follow-up verification: 15 local repository/transport tests and 15 planner/transaction-detail widget tests pass (30 total). Five API split tests pass, including actual registered route handlers with a mocked PostgreSQL client for read/save/clear, conflict/no-op handling, ownership, totals and reference validation. The latest full API run had 386 passes and one unrelated failure in `statement_import.test.js` calendar/date/precision validation while other workspace changes were ongoing. These route tests do not replace a live PostgreSQL locking/concurrency check.

Two independent features exist:

- Transaction detail records expense shares. Partial shares leave the remainder with the payer. Save replaces the entire share set; clear saves an empty set. Shares do not change the original payment, reward state, caps, or reporting totals.
- Tools and Account open the multi-card purchase planner. The big-purchase calculator also opens it, now passing the entered purchase amount. The planner estimates card allocations; it does not execute payments.

## Fixes

- Clamp each optimizer allocation to the actual remaining utilization headroom, compare candidate rewards per paise when their candidate amounts differ, and stop at zero/negative headroom.
- Keep separate optimizer state and utilization ceilings for owned cards sharing a catalogue product. Build their snapshots from their own consumed caps.
- Allocate tiny amounts down to one paise, reject invalid search step counts, and preserve category slug during marginal ranking.
- Restore the planner amount into its input on reopening and prefill purchases from the calculator. Reject malformed decimal input.
- Expense-share editing rejects negative, non-finite, zero, excessive-precision and over-total amounts. Blank rows remain optional. Preserve existing card/category references when editing and limit notes to the API's 2000 characters.
- Validate API payload types, precision, share count, note length and reference syntax before writing. Check card ownership and category existence before replacement.
- Lock the parent transaction during split replacement so concurrent writes cannot append competing share sets. Compare totals in integer paise.
- Reject transaction amount reductions below saved shares before reversing reward state.

## Verification

- API: `npm test` — 367 passing tests, including new split validation/decimal tests.
- Domain: `dart test` — 227 passing tests, including new small-headroom, one-paise, invalid-step-count and duplicate-product regressions.
- Planner widgets: 4 passing tests covering empty wallet, amount entry, prefill and malformed input.
- Transaction-detail widgets: 11 passing tests covering share save, edit, clear, validation, metadata preservation and read errors, alongside other transaction actions.
- Screen analysis: no errors or warnings; existing informational style/deprecation findings remain outside the split changes.

## Verification limits

No phone/emulator or live PostgreSQL end-to-end run was performed. API tests exercise validation; database locking, reference queries and transaction-edit guards were reviewed in code and syntax checked, but were not exercised against a running database. The planner remains a bounded greedy estimate, not a guarantee of the mathematically optimal allocation. Its utilization data is tracked app spend, not an issuer balance. Purchase category selection is not forwarded to the category-agnostic planner.
