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
