# Admin console — focused plan, 5 November 2026

Builds on the [1 Nov review](admin-console-review-2026-11-01.md) and the [30 Oct private-admin plan](admin-console-implementation-plan-2026-10-30.md). Those remain the source of truth for the security architecture; this document decides **what to build next and what to leave out**, using three lenses: product, engineering and security.

## 1. Where things stand (checked today)

| Area | State |
| --- | --- |
| Login | Verified email code, then a registered passkey or security key. There is no sign-up page; accounts are created only by the offline provisioning tool (`db/scripts/admin_access.js`) with a reviewed plan hash. |
| Public exposure | Production `api.pandapath.site/admin/*` and `auth.pandapath.site/{admin,browser}/*` return **404** (checked 5 Nov). The public services contain no admin handlers. |
| Local console | Runs at `https://localhost:8443` through the local gateway; owner account active with primary and backup keys. |
| Production console | **Not deployed.** The SSH-tunnel launcher and private Compose profile exist, but the private backend profile has not been started on the server. |
| Screens | 16 operational screens. The landing page was Catalogue, and there was no overview of pending work. |
| Known defects | Error-report approval on non-rate fields closed the report and then returned a 500 error. Parked ("needs more evidence") policy alerts could never be decided. Policy approval does not publish a correction (AD-5). |

## 2. Three lenses

**Product (what an admin does every day).** An admin opens the console to answer three questions: *What is waiting for me? Is anything broken? Am I about to change production?* Every pixel on the home screen should answer one of those. Deep analytics, maps and trend charts are useful later, but they do not change today's decisions.

**Principal engineer (cost and risk).** Reuse existing read endpoints and the providers the screens already use, so opening a screen after the overview costs no extra requests. Add no new backend route on this pass: every new route must be classified in the route manifest, synced to contracts and re-tested against the private database. Fix correctness bugs before adding features.

**Security engineer.** Keep the server as the only authority: the UI may hide what a role cannot do, but never grants anything. Make the environment impossible to misread, because the same `localhost:8443` address serves both local and production (via tunnel). Do not weaken anything for convenience: no OTP-only login, no web sign-up, no public admin host.

## 3. What the overview shows (and what it leaves out)

Shown, in priority order:

1. **Environment and identity.** Local, staging or production, plus role and email. Production gets a persistent clay-coloured banner across the whole console.
2. **Needs attention.** Open policy alerts, pending error reports, support tickets, card requests, merchant conflicts and SMS rule approvals (category, parser, AI-learning and correction cases). Each tile opens its queue.
3. **Health.** Scraper failures (7 days), cards not verified in 180 days, SMS AI queue (queued, failed in 24 h, oldest waiting), latest privacy audit result.
4. **Catalogue at a glance.** Published cards, published and high-confidence merchants, locations.

Left out on purpose: charts and trends (no time-series table exists yet; drawing fake trends would mislead), maps, revenue/user analytics (not the admin's job here), raw SMS or personal data (privacy rule), and any action buttons on the overview (actions stay in their screens, where context and confirmation live).

Sections the signed-in role cannot read are hidden rather than shown as errors. Lists that the API caps (for example 500 category proposals) display as "500+" instead of a misleading exact number.

## 4. Local and production

How the switch works today, and stays:

- `scripts/admin_console/start.sh --target local|staging|production --config <protected file>` chooses the backend. Local uses the services on this Mac; staging and production use a forwarding-only SSH tunnel to the server's `127.0.0.1:4321` gateway. Only one target runs at a time because the launcher refuses an occupied port.
- The gateway reports its configured `ADMIN_ENVIRONMENT`, and the console now shows it everywhere (banner, sidebar, top bar).
- Each environment has its own auth database, so a local passkey, session or account grants nothing in production. A production admin must be provisioned separately with the reviewed CLI flow and a target fingerprint.

Still required before production can be used (deployment, not code — each needs your explicit go-ahead):

1. Restore a copy of production data and rehearse the private-admin migrations against it.
2. Start the private Compose profile on the server (gateway on server loopback only; admin API with no host port).
3. Create the forwarding-only SSH account, pin its host key, and prove that LAN, IPv6 and direct-origin access are refused.
4. Provision the production owner (plan → review → apply), enroll two independent keys, then enable.

## 5. Security findings

| Check | Result |
| --- | --- |
| Can an outsider create an admin account? | **No.** No sign-up route exists. Login start always returns the same response and only emails existing, verified, provisioned admins. Enrollment needs an operator-issued grant or an operator-approved intent bound to that user, environment and current version. |
| Can a customer token reach admin routes? | **No.** Public listeners 404 every `/admin`, `/browser` and `/internal/admin` path, including encoded variants. Verified live on production. |
| Can a guessed or forged request act? | Gateway pins host and origin to `https://localhost:8443`, requires CSRF and custom headers on writes, forwards only the 92 allow-listed routes, re-checks membership on every request, and requires a fresh key touch for 18 high-risk mutations. Rate limits: 120 requests per minute, 20 writes per minute, 5 login emails per address per 15 minutes. |
| Session theft | HttpOnly cookie; upstream token encrypted server-side and never sent to the browser; idle and absolute expiry; revocation on logout or membership loss. |
| Residual risks | Production deployment not yet accepted (section 4). No self-service key recovery (by design: recovery is a reviewed maintenance action). Docker base images use floating tags. Permission-aware UI was missing (fixed in this pass; server enforcement unchanged). |

## 6. Roadmap

**Done in this pass**

- Overview home screen as the landing page, built from existing endpoints and providers.
- Environment banner (production in clay, staging in amber, local in jade) on every screen.
- Role-aware navigation: screens the role cannot read are hidden; the server still enforces every permission.
- Error-report approval returns a clear 422 for fields it cannot apply automatically and leaves the report pending; the screen explains the manual path.
- Parked policy alerts can be approved or rejected later.

Verification for this pass: console `flutter analyze` clean, **76 console tests** pass (new: overview counts and navigation, production and readonly gating, missing-environment fallback, manual error-report path), `api` suite **1,417 passed, 4 skipped, 0 failed** (new: `admin_review_lifecycle.test.js`), and the CSP release build succeeds and is what `https://localhost:8443` now serves. The running local private API must be restarted to pick up the two backend fixes. Real passkey sign-in against the new UI was not exercised.

**System status (added the same day)**

- New **System Status** screen (`operations.read`) backed by `GET /admin/system/status`: the 12 production services and what each does, live health where a signal exists (public readiness checks for the customer API and auth, database latency, SMS AI queue), scheduled-job freshness (backup, SMS learning worker, privacy audit, scraper; "overdue" when a job misses its window), the code this admin API runs, and the branch list from a git checkout with local/GitHub sync state.
- Probe targets come only from `ADMIN_HEALTH_PROBES` (https or loopback http, no credentials, max 12, no redirects, bodies never read, 3 s timeout, 15 s cache). Job rows are shown only to roles that can read them. Deployed builds report `PANDAPAY_GIT_SHA`, `PANDAPAY_GIT_REF` and `PANDAPAY_DEPLOYED_AT` (passed through `deploy/admin/compose.private.yml`); they have no branch list because images carry no git metadata.
- Overview gains a "Service problems" tile linking here. Services without a health signal (rewards worker, maintenance jobs, migrations) say "Not monitored yet" rather than guessing.

## 7. App errors and user feedback

What is captured today:

| Signal | Captured centrally? | In the admin? |
| --- | --- | --- |
| User bug reports, feedback, card requests | Yes, `support_tickets` with bounded diagnostics | Support Tickets |
| "This card detail is wrong" reports | Yes, `data_error_reports` | Error Reports |
| Usage events (app opened, screens viewed) | Yes, allow-listed `analytics_events`, no content | Not shown |
| App crashes and uncaught errors | **No.** `app/lib/app/error_handling.dart` keeps them in an in-memory `CrashLog` on the phone by design | No |
| Server errors (500s) | Only as container log lines | No |

What large apps do: a crash SDK (Firebase Crashlytics, Sentry, Bugsnag) groups crashes by stack, counts affected users, and tracks "crash-free users %" per app version; backend monitoring (Datadog, Grafana, New Relic) tracks error rate and latency; alerts page an on-call person; staged rollouts stop a bad release early; in-app "report a problem" attaches logs. The admin view is usually a release-health page: crash-free rate by version, top error groups, new-in-this-release errors.

Recommendation (needs an owner decision, because crash data can contain personal or SMS-derived text):

1. **First-party, privacy-safe error events** (recommended): the app sends error type, a fingerprint of the top stack frames (file:line only, no messages), app version, OS and screen to a rate-limited endpoint; the admin gets an "App errors" screen grouped by fingerprint with counts, affected installs and versions. No third party sees the data. Medium effort.
2. **Firebase Crashlytics**: fastest and richest (the app already uses Firebase for push), but stack traces and device data go to Google, and messages must be scrubbed before sending. Small effort plus a privacy review.
3. Count server-side 500s per route in the admin API's status endpoint (small; useful with either option).

## 8. Monitoring and crash-reporting stack (recommendation)

**What production actually is:** one Oracle Cloud VM running Docker containers, plus a separately hosted PostgreSQL. Always on: customer API, auth, rewards worker, backup, SMS AI worker, SMS learning worker. Database migrations run once per deploy. The two maintenance tools are manual and off by default. The admin gateway and admin API are not in production yet. The admin screen lists 12 *programs*, not 12 machines.

**Principles**

1. Monitoring must not live only on the machine it watches; if the VM dies, its own dashboards die with it.
2. Watch four things first: is it up, are users hitting errors, is it slow, are background jobs running.
3. No SMS text, phone numbers or card data in telemetry. Scrub at the source, before anything leaves the device or server.
4. Every tool is something to patch, back up and secure. Few tools, open standards (Prometheus metrics, the Sentry SDK protocol, OpenTelemetry), so hosted and self-hosted stay swappable without code changes.

**Recommended stack**

| Need | Tool | Effort |
| --- | --- | --- |
| Uptime and alerts | Uptime Kuma (open source, one container) on a second machine, or a free external checker; Telegram/email alerts when `/ready` fails | Hours |
| App crashes and server errors | **GlitchTip** (open source, Sentry-compatible), self-hosted; `sentry_flutter` in the app, `@sentry/node` in API/auth, strict scrubbing | 1–2 days |
| Metrics, dashboards, alerts | Prometheus + Grafana with node-exporter and cAdvisor; `prom-client` request/error/latency metrics in the Node services | 2–3 days |
| Logs | Loki + Grafana, only after logs are confirmed free of personal data | Later |
| Tracing | OpenTelemetry + Grafana Tempo | Later |

Host GlitchTip, Prometheus, Grafana and Uptime Kuma on a second small VM (Oracle's free ARM tier may cover it), reachable only over a private network or VPN, with 2FA, never public. The admin portal shows summaries (crash-free users for the latest version, new errors, uptime) and links out; it does not rebuild Grafana.

**Why GlitchTip over Crashlytics or building our own:** Crashlytics is free and polished, but mobile-only (no server errors) and sends data to Google. Building our own means reinventing grouping, release health and symbol upload. GlitchTip gives the Sentry feature set with data on our own machine, and can move to Sentry's hosted service later by changing one address.

**Status (5 November):** server side built, off until configured. `api/src/telemetry.js` (identical copy in `auth/`) sends privacy-safe error reports in the Sentry envelope format and serves Prometheus metrics on a private port, with no new dependencies; `deploy/monitoring/` holds the monitoring-VM stack, the app-VM agent, 11 alert rules, a Grafana dashboard and the setup runbook. Verified: unit tests, promtool/amtool/Caddy validation, a live Caddy routing test, and real reports accepted by GlitchTip 6.2.6 without message text. Mobile app: `app/lib/app/crash_reporter.dart` sends the same kind of report (class name and code location, no message), queued offline, capped per session; verified against GlitchTip 6.2.6. Remaining: provisioning the monitoring VM (owner), native-crash capture, worker metrics.

**Targets to track:** crash-free users ≥ 99.5% per release, API error rate < 0.5%, p95 latency < 500 ms, backup age < 26 h, alerts acknowledged within 15 minutes.

**Next (highest value, small to medium)**

1. AD-5 policy approval that applies a typed correction, bumps the catalogue version and records the change in one transaction.
2. Catalogue change history view (the `card_catalogue_changes` and `admin_audit_log` data already exist).
3. A `parked` count in `v_data_quality_dashboard` (append-only view change) so parked alerts show on the overview.
4. Scraper reinforcement of parked alerts instead of opening duplicates.

**Later**

- Daily snapshot table for real trend lines; threshold alerts.
- Full rule authoring, YAML import/export, engine-backed before/after preview.
- Production deployment acceptance (section 4), pinned base images, key rotation runbook.

**Not doing**

- Any public admin website, email-only login, password login, or in-app admin sign-up.
- Client-side permission checks as a security control.
