# PandaPay full application audit

Audit date: 2026-09-19

Branch: `codex/full-app-dynamic-audit`

## Scope and method

This review covered the Flutter app, the Node API route surface, the repository/provider layer, the application router, and the current project plans/progress notes. The audit searched for hardcoded financial values, placeholder/demo copy, unlinked screens, disabled controls, local-only fallbacks, and API-backed data paths. Existing uncommitted work was treated as user-owned and was not included in this audit branch.

This is an evidence-based code review, not a claim that every possible device/vendor failure has been reproduced. Native camera, SMS, Gmail, notifications, location/geofence, and store-distribution behavior still require real-device or production-configuration verification.

## Current state: already dynamic

The following areas are wired to real providers/repositories and API or local persistence rather than demo values:

- Card catalogue, categories, card discovery, owned cards, card edit/archive/default/reorder, benefits, reward rules, points ledger, and card overrides.
- Home summary, recommendations, merchant search/nearby lookup, quick add, activity, transaction detail/edit/splits/duplicate review/needs review, and spend reports.
- Insights including caps, milestones, fee waivers, utilization, lounge usage, due dates, monthly savings, missed opportunities, portfolio audit, spend trends, budgets, subscriptions, and billing float.
- Import flows for statement PDFs, forwarded email, Gmail discovery, IMAP credential testing, SMS backup files, live SMS ingestion, export, and backup-status reporting.
- Notifications inbox, notification preferences, local trigger evaluation, account/profile settings, linked devices, support tickets, consent history, and changelog/What's New.
- Production app-status/maintenance/forced-upgrade gates and the production API environment configuration.

## Static or intentionally content-only screens

These are static by design and should not be converted to backend-driven pages merely to remove all constants:

- Welcome, onboarding tour, permission explanations, SMS consent, and the All Set walkthrough: educational copy and illustrative examples.
- Tools hub and grouped insight shells: navigation containers whose child screens are dynamic.
- Travel-mode explanatory guidance: general card-travel advice, not a live issuer-rules database.
- Legal screen: policy text is intentionally content, but it remains founder-drafted and needs legal approval before launch.
- Appearance card-art/theme status: the app currently has one visual catalogue and correctly avoids presenting a non-functional selector.
- Empty/loading/error states, labels, thresholds, quick amount presets, and accessibility copy: UI behavior/constants, not user data.

## Confirmed gaps and priority

### P0/P1: fix in application code

1. **Credit utilization edit path is not linked.** Cards without a credit limit display “Add credit limit in Cards → Edit” as non-interactive text. The user must manually navigate back to Cards. Make the card a real tap target that opens `/cards/:id/edit`.
2. **Route coverage needs regression protection.** Dynamic route siblings and deep links have historically been easy to shadow; current ordering is corrected for card and activity routes, but route tests should remain part of every navigation change.
3. **User-facing provider failures need consistent retry coverage.** Most major screens have retry states; any new repository-backed screen should follow the same pattern and should not silently replace an API failure with a zero.

### P1: production/configuration work, not safe to invent in the client

4. **Forced upgrade still opens a generic Play Store search.** A real Android listing URL and iOS listing URL are not present in `app_status`; this must be supplied by deployment/configuration before release.
5. **Legal text is embedded and founder-drafted.** The screen is no longer a placeholder, but legal review and synchronized hosted copy are still required.
6. **SMS live listener, camera/QR scanning, notifications, geofence behavior, and widgets need physical-device verification.** Unit/widget tests cannot prove OS permission lifecycle behavior.
7. **Email forwarding requires DNS/provider webhook wiring.** The app/API surfaces are present, but receiving real mail depends on external mail configuration.

### P2: explicit product-scope or schema decisions

8. **My Contributions is network-wide only.** The current database deliberately has no per-user contribution identity on merchant contributions. A personal count cannot be added honestly without a privacy/schema decision.
9. **Backup screen reports status and logs a backup request; it is not a self-service restore engine.** Full restore would overwrite the backing store and must remain an operational/admin process unless product scope changes.
10. **Monthly savings counterfactual is a client-side, base-rate-only estimate.** Historical cap/milestone/forex state is not modeled, so the UI correctly labels this as estimated rather than presenting a false exact figure.
11. **Lounge benefits using statement-cycle periods currently fall back to calendar-month bounds.** A correct implementation needs statement-cycle semantics from the user card and issuer/product data.
12. **Billing float uses an explicit 20-day grace-period assumption because issuer-specific grace-period data is not modeled.** It is labeled as an assumption and must not be silently presented as a confirmed issuer term.
13. **PDF parsing and IMAP are bounded capabilities.** PDF layouts vary by issuer, and IMAP currently verifies credentials rather than running a background mail poller.

## Linking review

- The major top-level destinations are registered in `app/lib/app/router.dart`.
- Child settings, import, tools, and support pages are intentionally pushed as screens from their hubs.
- Card detail, edit-card, transaction detail, needs-review, duplicate-review, due-date statement, benefit detail, and notification links have concrete navigation targets.
- The utilization “Add credit limit” affordance is the confirmed missing link addressed by this audit branch.

## QA plan for this branch

- Add a focused widget/navigation test for the utilization edit affordance.
- Run Dart formatting, targeted Flutter tests, Flutter analyzer, and existing API tests without staging unrelated worktree changes.
- Verify the branch diff contains only audit documentation and the safe navigation fix.
- Report remaining production/device/configuration blockers separately from code defects.

## Verification snapshot

- Focused utilization widget tests: **6 passed**.
- Focused Flutter analyzer for the changed screen and test: **no issues**.
- API syntax checks and API test suite: **224 passed, 0 failed**.
- Full Flutter test run: the new utilization test passed, but the repository baseline is not green. Existing failures include router `pumpAndSettle` timeouts and test compilation errors because the current uncommitted `UserCardsRepository.logTransaction` API has a new `rail` parameter while several existing test fakes have not been updated. Those files are outside this audit change and remain unstaged.
- Full Flutter analyzer: blocked by the same pre-existing test-fake signature errors, plus untracked scratch files (`test_match*.dart`, `test_scanner*.dart`) and an unrelated unused import in the dirty worktree.
