# Admin application implementation review — 1 November 2026

Reviewed branch: `codex/ios-shortcuts-prototype`, HEAD `b398f72`. This is a source and local-test review. Existing uncommitted mobile/iOS work was present and was not changed. No real database, administrator account, mail provider, certificate trust, or deployed service was changed or inspected for this review.

The admin application's foundation is substantially implemented. The original product roadmap is partially implemented: its main screens and backend routes exist, but several promised workflows and operational requirements remain incomplete. Passing component tests does not establish completion of the original end-to-end acceptance criteria. A single completion percentage would hide that distinction; the plans do not provide a consistently sized, weighted set of completed requirements.

## Plans used

- [Original product scope](../admin-console-plan.md).
- [Detailed feature roadmap, AD-0 through AD-10](../adminimplementation_plan.md).
- [Current private/local admin implementation and deployment plan](admin-console-implementation-plan-2026-10-30.md).
- [Previous source verification](admin-console-source-verification-2026-10-30.md) and [operator runbook](../deploy/admin/RUNBOOK.md).

The 30 October plan supersedes the old roadmap's public-hosting, Supabase/password-login and provisioning assumptions. Those older architectural choices are not missing features to reintroduce. The existing graph was queried for orientation, but predates these changes; the conclusions below were checked against current source.

## What is implemented

- Sixteen navigation destinations, including catalogue, requests, errors, support, policy alerts, merchants, conflicts, acceptance/rates, quality, SMS AI, privacy audits, parser patterns, rule approvals, sources, scrape review, and referrals: [console shell](../console/lib/main.dart).
- Catalogue browsing, eight rule-family tabs with typed controls, and draft/review/publish/archive transitions. The reward-rule editor currently edits existing rates; it is not a complete rule-definition editor.
- Request grouping and source creation; error-report review; support resolution; merchant inspection, override and unpublish; conflict review and device blocking; acceptance publication and effective-rate summaries.
- Source registry and ToS/enable controls; static scraping, robots checks, request pacing, extraction, content hashes, snapshots, meaningful-change detection, and extraction proposals. Optional LLM extraction with heuristic fallback exists in [llm_extraction.py](../scraper/pandapay_scraper/llm_extraction.py); it should not be counted as entirely absent.
- SMS AI queue/quota/rollout views, learning-candidate controls, rule approvals and bundle rollback; referral operations and holds.
- Private verified-email plus WebAuthn login/enrollment, CSRF, server-held upstream credentials, step-up, logout, durable sessions/challenges, revocation and a restore epoch.
- Separate private gateway/API entrypoints, explicit public-route denial, and **92 classified method/path policies: 39 reads and 53 mutations; 18 require fresh MFA**. Registration counts include unavailable operations and are not counts of accepted business workflows.
- Forward migrations, dedicated runtime identities, and resumable provisioning with reviewed previews, receipts, pending enrollment, enable/revoke and audit-ID preservation.
- PC launcher/install/start/stop tooling, loopback TLS proxy, SSH and opt-in private Compose templates, plus a deployment/recovery runbook. Installation and target acceptance are separate from delivering these files.

## Original roadmap coverage

| Workstream | Current assessment | Remaining requirements/examples |
| --- | --- | --- |
| AD-0 Foundation | Substantially implemented; acceptance incomplete | Permission-aware navigation/actions, global search/backlog badges, complete expired-session handling. Shared domain/engine package exists, but the console does not implement the planned engine-backed impact preview. |
| AD-1 Catalogue | Partial | Before/after recommendation preview, field-level save diff, YAML import/export with dry run and round trip, catalogue-change history UI, staleness colouring, full card/reward-rule authoring. [Editor](../console/lib/features/catalogue/catalogue_screen.dart) explicitly lists several omissions. |
| AD-2 Request/error queues | Partial | Unified `user_report` alert evidence, current-live-value/attachment review, full-field corrections through one publish workflow, and the unsupported-field bug below. Grouping, source creation and the reward-rate correction path exist. |
| AD-3 Scraper | Partial | Playwright fallback, console source-page management/run-now dispatch, per-source scheduling/retention acceptance, real reviewed pilot coverage and delivered failure alerts. Weekly timer and CLI exist; real installation/runs were not verified. |
| AD-4 Diff/extraction review | Partial | Highlighted old/new diff UI, editable proposals mapped to actual rule fields, and field-level alert association. Current scrape UI shows snapshot text side by side; alert proposals are rendered as text. Backend diff and optional LLM extraction exist. |
| AD-5 Unified alerts and propagation | Major end-to-end gap | Approval currently closes an alert without publishing a correction. Cross-signal field keying, email/user-report evidence ingestion, urgent-sync integration and the seven-step device-recomputation acceptance scenario remain incomplete. |
| AD-6 Merchant visibility | Partial | Interactive clustered map, region/date filters, complete confidence explanation, merge/bulk-revert and quota-management workflows. Current filtered list/detail, override, conflict and block controls exist. |
| AD-7 Acceptance/rates | Partial | Acceptance map, charted rate history, full detail workflow and actionable navigation to the linked alert. Rate/sample/device/cap-ceiling values and publication controls exist; the alert indicator is a non-interactive `Chip`. |
| AD-8 Quality dashboard | Partial | Time-series capture/trend charts and threshold notifications. Current dashboard is explicitly a snapshot. |
| AD-9 Anonymization audit | Source and CI wiring present; full acceptance open | History/manual run and reusable deploy-gating workflow exist. Nightly job is defined in legacy cron SQL; actual scheduled execution, delivered alerts, new-table coverage and the complete privacy acceptance scenario were not verified. |
| AD-10 Operations/coverage | Partial/ongoing | Reviewed source expansion, delivered extraction-failure alerts, capacity/resource evidence, admin-specific restore/revocation acceptance, exact private release evidence and target activation. Runbooks and general recovery CI exist. |

## Most important findings

### P1 — Policy approval does not apply or publish the correction

AD-5.3 requires one transaction to apply the typed correction, bump the catalogue version, record the linked catalogue change, audit and optionally request urgent sync. [The actual decision endpoint](../api/src/admin/inline_routes.js#L651) only updates `policy_change_alerts` and inserts an audit entry. The [UI](../console/lib/features/alerts/alerts_screen.dart) explicitly describes this reduced behavior.

A synthetic HTTP probe through the real private API factory and actual transaction helper, with an in-memory database fixture, returned 200 for approval with zero catalogue writes. This is a feature gap, not evidence that ordinary catalogue editing is absent. The older SQL `approve_policy_alert` definition also does not consume its `p_apply` argument to apply a rule update, so simply exposing that function would not complete the workflow. No app/API consumer of `force_catalogue_sync_after` was found in the searched source. Complete and test the seven-step AD-5.3.5 scenario, including a previously synced device and recommendation recomputation.

### P1 — Signals do not yet converge on the same changed field

[Scraper alerts](../scraper/pandapay_scraper/alerts.py#L37) use `page_content:<page_role>`, while the bounded [empirical-divergence job](../db/supabase/migrations/20261024111632_bounded_operational_maintenance.sql#L162) uses `reward_rules.<category-or-all>.rate`. These keys do not merge a page change and a rate divergence into one field alert as planned. News pages use the scrape pipeline, but a page without a card association is skipped. Email keyword detection/storage exists; no email-keyword or user-report evidence insertion into the unified queue was found in the searched application writers.

### P1 — Unsupported error reports can be resolved despite an error response

In [error approval](../api/src/admin/inline_routes.js#L491), a field outside `reward_rules.<uuid>.rate` is marked resolved and audited without a correction. That branch returns `{ok, resolved}` without `status`. The transaction commits, then the handler attempts `res.status(undefined)` and returns 500 from its catch block. The synthetic HTTP probe reproduced both the committed resolution and the 500 response. Add explicit supported-field handling and consistent outcome/status semantics before considering this queue complete.

### P2 — Parked alerts cannot continue through the review flow

The decision endpoint only updates rows whose state is `open`; the UI also only shows decision controls for `open`. After choosing `needs_more_evidence`, a later approval returns 404, reproduced through the real factory. The scraper's lookup likewise only finds `open` alerts. Implement the intended parked/reopen/review lifecycle and ensure new evidence reinforces the existing unresolved alert.

### P1 — Broadcast and learning dispatch are deliberately unavailable

The private registration supplies no notification provider adapter. [Broadcast](../api/src/admin/inline_routes.js#L685) consequently returns 503. The [direct learning-cycle endpoint](../api/src/admin/routes.js#L154) returns 409 (`autonomous_cycle_is_worker_only`). Reviewed durable, audited, idempotent worker dispatch remains to be implemented; the existing worker modules and rule-management controls do not complete those console operations.

### P1 — The newer security plan still has source and target requirements

Its remaining checklist is consistent with this review: populated-schema/role/mutation acceptance; distributed renewal/revocation and provisioning failures; factor replacement/recovery and key rotation; pagination/concurrency; shared mail/provider/connection budgets; auth-state retention; monitoring; complete versioned contracts and exact private-release evidence. Legacy reads include unpaginated catalogue/alert/error queries and fixed-limit lists without continuation. Dockerfiles still use floating `node:22-alpine` tags rather than exact pinned base images.

The UI receives permissions from `/admin/me` but its membership helper reduces the result to a boolean, and the shell/editor do not use a shared permission model to gate actions. Server-side policy enforcement exists; permission-aware UX remains open. The private browser store has no refresh token, while the shell's periodic refresh exits when no refresh token exists; definitive expiry/retry behavior needs dedicated browser-flow acceptance rather than relying on the old native refresh path.

## Verification executed for this review

| Command/check | Result |
| --- | --- |
| `cd console && flutter test --reporter expanded` | **57 passed** |
| `cd console && flutter analyze --no-fatal-infos` | **No issues** |
| `cd console && flutter build web --release --csp --no-web-resources-cdn --dart-define=PANDAPAY_PRIVATE_ADMIN=true` | **Passed** |
| `cd auth && npm test` | **362 passed** |
| `bash scripts/test_private_admin.sh` | **Passed**: real PostgreSQL protocol scenario, full clean/repeated schema rehearsal, 15 provisioning tests, 12 boundary/factory tests, 3 packaging tests, contract synchronization |
| `cd scraper && .venv/bin/python -m pytest tests -q` | **40 passed**; no real crawl/provider delivery attempted |
| `cd api && npm test` | **1,371 passed, 3 failed, 3 skipped** |
| Three synthetic HTTP workflow probes | Confirmed approval-without-publish, parked-alert 404, and unsupported-error resolution committed before 500. Real factory/transaction helper; simulated DB, not target-data acceptance. |

All three full-API failures are in `account_lifecycle_journal.test.js`, reporting `Journal disk reserve unavailable`. Node's filesystem measurement showed **4.967% available blocks** at diagnosis, below the journal's enforced 5% reserve (about 22.87 GiB available). This explains the observed failures; the suite is still recorded as failing. No disk cleanup, reserve bypass or unrelated code changes were performed. Logs are in `/tmp/pandapay-admin-review-*-20261101.log` for this local session.

The older verification report is useful historical evidence, but its earlier all-pass API count is not the current run's result. Physical authenticators, real owner enrollment, restored populated databases, multi-replica/network exposure, live provider delivery and independent security review were not exercised. `age` is unavailable on this Mac, so the separate encrypted recovery rehearsal was not rerun. The repository records owner enrollment/admin activation as pending; this review does not establish current live account or deployment state.

## Recommended completion order

1. Fix the error-report outcome bug and parked-alert lifecycle, then implement one typed transactional policy publish path with full cross-signal field association and device-sync/recommendation acceptance.
2. Finish essential catalogue authoring, change history, editable proposals, diffs and engine-backed preview; add lossless bulk import/export if needed for the initial operational catalogue.
3. Finish private mutation/role acceptance, supported recovery/rotation, bounded reads/jobs and permission/expiry UX; implement durable dispatch for enabled operations.
4. Add real scraper pilot/page management/JS support and delivered operational alerts; complete dashboard trends. Maps and further coverage can follow the core correctness work unless required for the first operating scope.
5. Complete paired local setup and real primary/backup enrollment, then separately accept the actual deployment's restored data, trust, images, network denial, budgets and private release evidence before activation.

This review adds documentation only. The identified implementation defects and missing features have not been fixed by this review.

## Follow-up: authorized local startup

After this review, the user selected **local development using their real admin account**. A separate PostgreSQL instance was initialized on loopback port 55488, with the canonical current auth/product migrations, separate runtime credentials, and no seeded administrator or fake email verification. The older databases on port 5432 and the existing local API were left intact. The new product database initially contains no imported operational dataset. Ordinary auth (3211), private API (4001), gateway (4321) and local TLS proxy (8443) started successfully; every listener was verified on `127.0.0.1`. SMTP authentication passed without sending mail. The private session endpoint returns 401 before login, and public local auth denies `/admin/me` with 404.

The running console is `https://localhost:8443/`; normal local email verification is prepared at `https://localhost:8443/local-setup`. Configuration, local-only runtime wrappers, process control and the operator README are protected under `$HOME/.config/pandapay-admin/local-dev/`, outside the repository. No checked-in application source was changed for startup. `age`, `mkcert` and Nginx were installed through Homebrew. The generated local CA has **not** been installed into system trust: Chrome currently blocks it with `ERR_CERT_AUTHORITY_INVALID`. Certificate trust, normal owner email proof, pending owner provisioning, independent primary/backup authenticator enrollment and final enable remain open.

Read-only deployment checks found customer API/auth readiness at 200, deployed API `/admin/me` at 401 and deployed auth `/browser/session` at 404. The f89996e deployment run [failed its stale-source-ref guard](https://github.com/true1ck/pandapay/actions/runs/41319865294); b398f72's workflow was skipped. The successful dce78cf workflow was a read-only backup check, not a deployment. These checks do not establish the exact running backend commit or private deployment acceptance.

The subsequent real email-verification attempt exposed an ordinary-auth default that blocked loopback sign-in. An explicit `AUTH_ALLOW_LOOPBACK_SIGNIN=true` opt-in was added for development/test only; hosted/unknown environments refuse it and explicit operator IP blocks retain precedence. The separate local auth process enables it. Five regression tests and the full **367-test auth suite** pass. The user installed the local certificate trust; macOS certificate verification and the actual Chrome setup page now succeed (the Homebrew Python CA bundle does not reflect the macOS trust store). The ordinary email-OTP endpoint delivered a real verification email successfully; owner email proof and factor enrollment are still interactive steps.

Owner enrollment status: normal email verification completed successfully for the selected local owner. The canonical provisioning CLI generated and applied a version-2 `grant` plan for the isolated local pair on 55488, preserving the original 5432 databases. Operation `388284d9-f99a-4d0e-a722-f25ba3460c3a` completed and prepared a **pending** principal and disabled owner membership. A primary one-use enrollment grant was written to a mode-0600 file outside the repository; its value was not logged. No factors or privileged browser sessions exist yet, and final enable has not run. Browser control was subsequently disabled in Work settings, so actual enrollment and authenticated UI acceptance require user participation or re-enabled browser control.

After the desktop restart, browser control reconnected successfully. The live Flutter console initially rendered shapes without text: its font manifest contained only icon fonts, and the browser reported blocked external font fetches under the local-only CSP. Roboto regular/medium/bold fonts and their license were bundled from the installed Flutter SDK, declared in the console manifest and selected in the theme/fallback. Console analysis, all **57 tests**, and the release build passed; the actual HTTPS browser screenshot now shows readable login controls. A fresh admin email challenge was created through the real browser and is awaiting the user's code. Pending owner status and factor requirements are unchanged.

## Login design update

At the user's request, the Flutter login now uses PandaPay's slate/lime branding and existing logo, a desktop workspace panel, a compact single-column layout, outlined account/code/grant inputs, and an explicit Account → Email code → Security key progress indicator. Each step presents one primary action. Pending email verification transitions to enrollment without displaying an authentication error or retaining the consumed-code form. Blank/invalid account and grant input is validated before network requests; loading, success and error feedback are distinct. Desktop and compact `@Preview` annotations are included.

The console suite passes **60 tests**, including new compact keyboard submission, invalid-email rejection, and pending-enrollment/no-session checks. The initial validation-message overflow found by those tests was corrected. Console analysis and release build pass. Rendered account, email-code, enrollment and compact previews are saved under `artifacts/admin-login-2026-11-01/`. The updated release bundle is served by the existing localhost TLS proxy. Browser control again reported disabled during final review, so the final visual checks used the actual Flutter widget tree with mocked auth responses; they do not claim a real passkey registration or authenticated console session. Real owner enrollment is still pending.

The subsequent failed-registration screenshot was investigated against the isolated local database. The most recent unused primary grant was expired, and no enrollment WebAuthn challenge or credential had been created; the failure preceded authenticator registration. The form now rejects malformed grants (including email codes) before sending requests, preserves safe gateway-specific recovery messages, distinguishes browser registration cancellation/unavailability from grant rejection, and requires an explicit successful enrollment response. The two-minute sign-in window and ten-minute grant lifetime are stated in the form. The expanded console suite passes **67 tests**, including compact recovery-message rendering and denial/cancellation/no-session checks; static analysis is clean. These checks do not substitute for real primary/backup enrollment or final activation.

A user-operated everyday launcher and a separate initial-setup launcher were subsequently placed on this Mac's Desktop. The protected local helper uses the existing maintenance CLI for per-slot grant generation and reviewed activation; it never creates authenticators or automatically enables the owner. Nine isolated helper tests pass, shell syntax is valid, live read-only status confirms all four local services are ready and the owner remains pending with zero keys. See the [local access guide](admin-local-access-guide.md) for repeated login and initial setup without an assistant. No real clipboard, browser-launch or activation actions were executed by those tests.

Further grant rejection checks were added to `tests/admin_console_security/postgres.test.js` and passed against a separate disposable Unix-socket PostgreSQL cluster. Through the actual HTTP gateway, both a made-up 43-character grant and an expired issued grant return 403 after fresh fixture email proof, without creating enrollment challenges, credentials or sessions. A grant expiring after registration options were issued also fails at the atomic database credential-write boundary; a consumed grant cannot be reused. These tests use synthetic identities in the disposable cluster and do not alter the real local owner or send email.

The user subsequently completed real primary registration at 22:56:59 IST on 1 November. Live read-only checks show one unrevoked primary credential, no backup, a pending principal, the primary grant consumed, and zero admin sessions. The return to the enrollment form was remaining initial setup, rather than loss of an authenticated session. The gateway now returns registered primary/backup slots only after verified email proof and successful registration. The UI shows backup registration or pending activation accordingly, and stays on a confirmation screen after registration instead of dropping immediately to the first form. It blocks further registration when both slots exist and points to the Desktop helper for explicit activation. No privilege, TTL or factor requirement was relaxed. Full **370-test auth**, **69-test console**, analysis, release build and `scripts/test_private_admin.sh` checks pass. The updated gateway was restarted in isolation, all local services are ready, and the rebuilt bundle is served locally. Actual backup registration and account activation remain required.

At the user's explicit request, the manual grant transport was replaced for this local profile with opt-in approved browser enrollment. Forward auth migration `0014_approved_browser_enrollment.sql` adds a bounded routine that prepares an internal ten-minute grant for a missing initial slot only after current email proof and a completed, environment/current-principal-version-bound operator grant/reconcile intent. It denies unapproved pending accounts, wrong cookies/environments, expired/consumed proofs, occupied slots and stale authority after factor revocation. Runtime cannot create operator intent or activate membership. The UI receives only the mode and WebAuthn options; it omits the grant field and never receives the internal token. Explicit backup and reviewed activation requirements remain. The optional mode defaults off in the private gateway and Compose overlay; this local protected configuration explicitly enables it. Paired local database dumps were saved privately before applying the migration through the canonical runner. Full **372 auth tests**, **70 console tests**, static analysis, release build, disposable PostgreSQL migration/provisioning/security checks and **10 local helper tests** pass. The primary credential remains intact; actual backup registration and activation have not been performed by these checks.

## Follow-up: local owner activation and portal access

On 1 November 2026, the user completed backup-factor registration and then approved the exact local enable plan. The canonical helper applied that reviewed plan to the isolated local auth/product database pair on loopback port 55488. The operation completed; read-only status confirmed the owner principal enabled and both credentials registered. The user then verified a fresh email code, authenticated with the registered passkey and reached the actual console. The login is local-only; the browser header identifies the session as `PandaPay · local · owner`.

The console exposes 16 operations areas. The Catalogue currently displays “No cards found” because the isolated local product database was created without importing an operational catalogue dataset. This confirms the screen loaded, while populated-data review remains outstanding. For later sign-ins, use the Desktop `PandaPay Admin.command` launcher, enter the admin email, verify the newest email code and approve the registered passkey. No copied 43-character enrollment grant is needed.

Current checks: all four local services (auth, private API, gateway and TLS proxy) report ready; the live `main.dart.js` hash matches the local release bundle. `auth` passes 372 tests, `api` passes 1,374 with 3 skipped, and `console` passes 70 tests; Flutter analysis is clean. `scripts/test_private_admin.sh` passes its disposable PostgreSQL migration, provisioning, gateway and security scenarios.

The production check remains separate. Public API and auth health endpoints return 200; unauthenticated public API `/admin/me` returns 401 and public auth `/browser/session` returns 404. The latest branch deployment workflow ([run 41332370986](https://github.com/true1ck/pandapay/actions/runs/41332370986)) skipped every job. The prior deployment attempt ([run 41319865294](https://github.com/true1ck/pandapay/actions/runs/41319865294)) failed at “Deploy exact branch commit” after its build/test and image jobs passed. Current admin changes are uncommitted local work, so there is no evidence this admin console was deployed to production.

The feature gaps and findings above remain: policy approval still does not publish a correction; unsupported error-report resolution can commit and then return 500; parked alerts cannot resume; broadcast delivery is unavailable without its provider; direct learning-cycle requests are intentionally rejected in favor of worker dispatch. Catalogue authoring/history/import/export, permission-aware controls, scraper pilot acceptance, populated-data performance, recovery/rotation, monitoring and production deployment acceptance remain incomplete.

## Follow-up: admin console UI refresh

The console shell and its 16 operation areas now share a PandaPay slate-and-lime visual system. Navigation is grouped by workflow and adapts across desktop, tablet and mobile widths; pages include contextual descriptions and reusable empty/error states. The release bundle was rebuilt and served by the existing localhost TLS proxy. The isolated local catalogue is still empty, so its empty state is what the local owner currently sees. This UI pass does not complete permission-aware action gating, the feature gaps above, or production deployment acceptance.
