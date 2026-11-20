# API and sign-in security check — 20 Nov 2026

Scope: every route the product API registers (`api/src`), the sign-in service's token handling (`auth/src`), how the
app stores and refreshes tokens, and live probes against production (no credentials used, nothing changed).

## 1. How sign-in works today (verified)

| Step | What happens | Evidence |
|---|---|---|
| Sign in | The app gets a 60-second code by email or phone from the sign-in service (`auth.pandapath.live`) and exchanges it for an **access token (15 min)** and a **refresh token (90 days)**. | `auth/src/config.js` (`JWT_ACCESS_TTL` 15m, `JWT_REFRESH_TTL` 90d) |
| Storage on the phone | Both tokens are kept in the iOS Keychain / Android Keystore (`flutter_secure_storage`), not in plain preferences. | `app/lib/data/token_store.dart` |
| Every API call | `Authorization: Bearer <access token>`. The API checks the signature (HS256 only), issuer, audience and expiry, and accepts rotated keys by key id; then it asks the sign-in service whether that session is still active, not revoked, and on the right device and token version (answer cached 5 s), and checks membership. | `api/src/auth.js` (`verifyAccessToken`, `verifyMemberRequest`) |
| Expired access token | The API answers 401; the app refreshes once (one refresh shared by all waiting calls) and retries. | `app/lib/data/authenticated_http_client.dart`, `SessionRefreshCoordinator` |
| Refresh | The refresh token is stored only as a bcrypt hash, bound to user and device, **rotated on every use**; reusing an old one is treated as theft and revokes the chain; a lost response is recovered by request id instead of logging the person out. | `auth/src/services/tokenService.js` |
| Data isolation | Every user query runs as the `app_user` database role with the person's id set, under forced row-level security, so even a wrong id in a request cannot read another person's rows. Direct, unscoped database access is used only for health checks and signed webhooks. | `api/src/db.js` (`withUserClient`) |

Live probes (20 Nov, production):

| Request | Result |
|---|---|
| `GET /user-cards`, `/sms/v2/sync`, `/transactions` with no token | 401 |
| the same with a forged token | 401 |
| `POST auth/auth/refresh` with a junk refresh token | 401 (nothing revoked) |
| `POST /internal/recovery/card-fact` with no service secret | 401 |
| `GET /.env` | 404 |
| `POST /analytics/events` with no token | **202 (accepted)** |

## 2. Route coverage

257 route registrations. 221 require a signed-in session (`requireAuth` 136, `requireAdmin` 58 behind a separate
admin gate, `requireMember`/`requireSmsV2`, `protect`). The 36 without a session guard:

| Routes | Why open | Verdict |
|---|---|---|
| `/health`, `/ready`, `/app-status` | probes | fine |
| `/catalogue`, `/categories`, `/changelog`, `/issuer-emergency-contacts`, `/access-policy` | public reference data, no personal data | fine; rate limit |
| `/i/:code`, `/split/join/:token`, `/.well-known/assetlinks.json`, `POST /invitations/validate` | invitation links and app links | fine (no-store, no-referrer, CSP on the pages) |
| `/avatars/:profileId*` | gated inside (`gate`): only people who share a Split context; others get 404 | fine |
| `POST /inbound-emails/webhook` | constant-time shared secret | fine |
| `POST /partner-conversions/webhook` | HMAC signature | fine |
| `POST /internal/recovery/card-fact`, `POST /internal/referral-outbox-event` | shared service secret | works, but reachable from the internet: block `/internal/` in nginx |
| `/merchants/nearby*`, `/merchants/search`, `/merchants/resolve` | shop lookups | **no session and no rate limit**; discovery can call Google Places (paid) when `NEARBY_DISCOVERY_USE_GOOGLE=true` and public OpenStreetMap servers otherwise |
| `POST /analytics/events` | anonymous analytics | **writes a database row per event for anyone**, no rate limit |
| SMS rules admin (`/rules*`, `/bundles`) | guarded at router level (`requireSmsV2`, `requireAdmin`) | fine |

## 3. What to fix (most important first)

| # | Gap | Risk | Fix |
|---|---|---|---|
| 1 | API answers carry no `Strict-Transport-Security` and no `X-Content-Type-Options`, and announce `X-Powered-By: Express` (the sign-in service already sends all three) | downgrade/sniffing hardening missing; server fingerprinting | `app.disable('x-powered-by')`, `nosniff`, and HSTS (API or nginx); `Cache-Control: no-store` on signed-in JSON (financial data) |
| 2 | `/internal/*` reachable from the internet | only a shared secret stands between the internet and internal writes | nginx: `location ^~ /internal/ { return 404; }` (the workers call the API on localhost) |
| 3 | Shop lookups and analytics have no session and no rate limit | paid Google calls or OpenStreetMap bans driven by anyone; analytics table flooding | per-IP limit (nginx `limit_req` or the existing limiter); require a session for the Google-backed routes |
| 4 | `POST /merchants/nearby/google` checks only the token signature (`requireValidJwt`) | a signed-out or revoked session keeps using a paid API until the token expires (15 min) | use `requireAuth` like the other signed-in routes |
| 5 | Refresh tokens are verified without pinning the algorithm, issuer or audience | not exploitable with jsonwebtoken 9 (it refuses `none`), defence in depth only | `algorithms: ['HS256']` (+ issuer/audience) in `verifyRefreshToken` |
| 6 | nginx allows TLS 1.0 and 1.1 in its http block | old protocol versions | `ssl_protocols TLSv1.2 TLSv1.3` (confirm the certbot include) |
| 7 | The rules signing key printed into a session on 7 Nov is still the active key | anyone with it could sign a rule bundle | rotate to the spare key (owner's decision, see memory note) |
| 8 | Refresh tokens live 90 days with no inactivity limit | a stolen phone backup stays useful long | consider a 30-day idle limit (product decision) |
| 9 | Bots probe `/.env`, `/.git/config`, `/.aws/credentials` | noise only (404) | nginx deny for dotfiles plus a per-IP limit |

Not found: SQL built from request text without parameters in the routes reviewed, tokens in URLs, tokens in logs
(request logs carry route templates and request ids only), or a route that returns another person's data.

Not covered here: a full OWASP Mobile review of the app, and penetration testing with a real signed-in account.
