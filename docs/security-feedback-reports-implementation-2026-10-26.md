# Public catalogue feedback and launch statuses — 26 October 2026

This batch continues LP01 (database isolation) and LP06 (bounded public work). Both remain **Partial**. The [main report](security-and-backend-audit-2026-10-20.html#implement-or-accept-these-first) now has an explicit status column for all ten priorities: **9 partial, 1 open, 0 accepted for launch**. Every status names covered work and outstanding acceptance; the original 76 finding statuses, 14 work packages and six gates are unchanged.

## Catalogue report fix

The public `POST /data-error-reports` route had the same failure as [anonymous support submissions](security-support-ticket-bounds-implementation-2026-10-25.md#postgresql-row-policy-follow-up): its `INSERT ... RETURNING` required a SELECT policy that deliberately excludes anonymous rows. The local restricted-role fixture reproduces PostgreSQL error `42501` for that old query.

The extracted handler in `api/src/data_error_reports.js` checks that the card is visible under the caller's existing RLS context, creates receipt metadata using scalar database functions, and inserts without `RETURNING`. A 201 receipt is returned after the existing transaction commits. Its fields, database timestamp, pending state and PostgreSQL UUID format are preserved. Caller-supplied profile/state fields cannot change report ownership or moderation state. Draft and unknown cards both return 404 for ordinary callers; anonymous reports remain unreadable to anonymous callers and members see only their own reports. Operator triage uses the existing policy. No policy, grant, schema or existing row is changed by this source patch.

Validation runs before database access. The card identifier must be a UUID, field paths must be nonempty text up to 256 UTF-16 code units, shown/claimed values up to 4,000 each, source URLs up to 2,048, and attachment paths up to 1,024. Invalid types and NUL characters return 400. Optional values keep their prior empty/null behavior. URLs and paths remain stored text; this route neither fetches them nor uploads files.

## Bounded submissions

Support tickets and catalogue reports use a common limiter implementation, with separate maps for each endpoint. Each endpoint allows 5 submissions per signed-token profile/hour or 30 anonymous submissions per IP/hour. A denial returns 429 and `Retry-After` before a database transaction opens. Each map holds at most 50,000 identities; expired entries are pruned at a bounded interval. A full map cannot cause a scan of all 50,000 entries for every new request. These identities stay in process memory.

These are per-process guards and reset at restart. Shared edge/store admission, actual carrier-NAT acceptance and aggregate replica/storage budgets remain required for unrestricted onboarding. A process-local throttle does not establish 100,000/day capacity.

## Verification and scope

- Full API suite: **1,121 passed, 2 existing skips, 0 failed**; includes syntax checks. The 12 focused feedback tests overlap this suite.
- Disposable native PostgreSQL **18.4**: **9 support scenarios plus 9 catalogue-report scenarios passed**. The fixture uses a real `NOSUPERUSER NOBYPASSRLS` login with RLS enabled and forced. It covers anonymous receipts/read denial, card visibility, canonical UUIDs, member ownership, reused connection identity, foreign inserts, operator triage and historical row/count preservation.
- The fixture applies migrations 0001–0011, 0015 and 0016, plus the exact ticket/report policy section from `20261024223000_support_tickets_dashboard_and_feedback.sql`. It excludes the unrelated dashboard view and later schema, owns its temporary local cluster and removes that cluster afterward. It reads no saved credentials or customer data.
- The HTML and Markdown priority tables agree across 10 rows and five columns; evidence links resolve locally. Application behavior is unaffected by the corrected provider comment. No Flutter runtime code changed in this batch, so its suites were not rerun.

[Hash-bound verification](../artifacts/security-feedback-reports-2026-10-26/verification.json) records the final candidate and fixture migration sources. Previous evidence files retain their original candidate hashes and dates. The browser tool refused the local file URL, so HTML checking used a local parser; no visual browser acceptance is claimed.

Hosted PostgreSQL 17/provider acceptance, full current-data upgrades, independent recovery custody and production load/provider approval remain open. No production database migration, deployment, key change or feature activation occurred.
