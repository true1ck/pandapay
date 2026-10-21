# Luna handoff: implement PandaPay invitations and referral rewards

Use this prompt with the repository open. The implementation and test documents are the source of the detailed contract; the earlier chat plan contains corrected assumptions.

## Copyable implementation prompt

Implement the PandaPay invite-only activation and referral program defined in:

- docs/referral-only-implementation-plan-2026-10-21.md
- docs/referral-only-test-plan-2026-10-21.md

Read both completely, inspect the current checkout/instructions, and revalidate any source assumption that changed since audited HEAD d95aa29. Preserve unrelated working-tree edits. Use the documented P0–P8 dependency order and produce a reviewable result for each package.

The requested experience is invitation -> authenticated product activation -> three consecutive eligible app-use dates -> permanent Bamboo qualification -> one independent reward entitlement for each person -> server-selected spin -> durable subscription credit -> supported subscription benefit redemption.

Use these implementation constraints:

1. Enforce membership on private product APIs and invitation validation during first product activation; a valid auth token or client signup flag alone cannot grant access. Preserve existing member login/recovery. It is acceptable for a verified auth identity to remain pending product activation.
2. Start with the identity prerequisites and six focused Flutter test failures documented in the test plan. Existing API/auth tests passing does not establish these security cases are resolved. Repair identity/session/proof invariants before enabling rewards. Add a trusted current-session/verified-identity bootstrap contract.
3. Keep activation, attribution, campaign snapshot and reward-budget reservation in one product-DB transaction. No assumed cross-database transaction. Obtain trusted auth state before taking product locks. Retry bootstrap without reusing a consumed OTP.
4. Existing onboarding completion is mostly local. Add an idempotent server completion contract and reconcile required consent recording with activation. Optional SMS/card/notification/marketing choices cannot become hidden mission requirements.
5. Bamboo uses server-confirmed foreground activity on three consecutive India campaign dates. Do not reuse transaction occurred_at streaks, historical import dates, anonymous analytics or background SMS/sync as app-use evidence.
6. Preserve the spinner requirement with a configurable fixed/weighted mode. Select value using secure server randomness, freeze the distribution version, and commit spin, ledger award, account update and budget settlement atomically. A repeated claim always returns its saved result.
7. Use separate subscription-credit accounts and append-only integer-paise ledger events. Keep current card Wallet/points separate. Implement real database constraints, owner isolation, privileged writes and concurrency tests; button disabling alone is insufficient.
8. Keep new financial objects in the restricted promotions schema, correct legacy/public grants, and verify role restrictions after every setup runner. Do not assume a migration's revokes survive setup_app_role.sql.
9. Wire the real domain/native invitations, preserve the existing assistant link handler and include manual-code/return-link fallback. Play Install Referrer is Android-specific. Do not add Firebase Dynamic Links or promise automatic iOS deferred attribution.
10. Implement an explicitly installed durable worker for outbox/reconciliation/expiry. Do not depend on the skipped pg_cron migration or a foreground app process. Honor valid pre-deadline activity receipts through their short submission grace before releasing reservations.
11. Prototype the actual platform subscription benefit before enabling redemption. Earned-points policy differs between Google and Apple. Do not invent an API to deduct arbitrary INR from a store renewal. Unsupported or unbound offer-code flows stay disabled; never refund an externally pending code merely because the app timed out.
12. Use immutable campaign versions, separate admission/enrollment/fulfillment/redemption switches, and disabled production defaults. Preserve valid already-enrolled promises when routine new enrollment is paused.
13. Treat old qualified referral rows as unfunded legacy state until adjudicated; never mint credits automatically from them. Existing testers can be grandfathered as members and inviters; they cannot become newly referred accounts.
14. Implement the companion matrix in appropriate layers, especially real PostgreSQL locking/RLS/migration and HTTP E2E tests. Add signed Android/iPhone, real three-date and store-sandbox evidence before claiming online readiness. No public time/prize override endpoint.
15. Keep test credits synthetic and isolated from production. Use approved campaign configuration for real amounts/odds/caps/terms; the INR 10/20/50 distribution is only a test fixture, and the old INR 100 seed is not an approved new offer.

Do not run live migrations, enable a real campaign, push/merge master or publish tester builds merely to complete this local implementation request. Those release actions need the applicable user instruction and the documented release evidence. The repository's master CI can deploy the backend automatically.

For each package report: files changed, migration IDs, behavior delivered, exact verification results, matrix IDs covered, capability flags, and remaining device/store/business decisions. Keep moving on authorized local implementation/testing that does not depend on an unanswered commercial value. Do not invent prices, probabilities, production credentials, store identifiers, identity proofs or passing results.

## Suggested review packages

| Package | Review outcome |
|---|---|
| P0 | Identity/session safeguards and repaired existing signup/recovery test baseline |
| P1 | Additive schema, roles and disabled campaign configuration, empty/upgrade migration tests |
| P2 | Server membership/activation and immutable referral attribution with app retry state |
| P3 | Working installed/new-install invitation entry on the actual signed apps/domain |
| P4 | Persistent Bamboo engagement/check-in and once-only qualification |
| P5 | Independent spins, immutable results, credit accounts/history and budget conservation |
| P6 | Observable worker, notifications and audited operator controls |
| P7 | Verified platform benefit redemption and purchase/access lifecycle |
| P8 | End-to-end pilot and evidence-backed enablement/runbook |

## Values that must be explicit before live campaign enablement

- Random versus fixed production reward mode, per-role amounts/weights and disclosed rules.
- Total campaign liability budget and the exact meaning/value of inviter caps.
- Final mission window/calendar/expiry policy if changed from proposed defaults.
- Subscription benefit/credit conversion, availability timing and platform eligibility.
- Supported release/domain/store identifiers and approved terms/privacy copy.

These are enablement/configuration decisions. They do not prevent implementing the disabled feature and its synthetic fixtures/tests.

## Honest completion levels

“Code complete” means implemented behavior and the appropriate local/CI tests pass. “Device validated” additionally means the signed native flows passed. “Online verified” additionally requires the exact deployed schema/services/campaign and witnessed end-to-end evidence. Keep those claims distinct in the completion report.
