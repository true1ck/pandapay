# PandaPay auth and API security review — 9 Nov 2026

Scope: `auth/` (identity service), the token checks in `api/src/auth.js`, the deploy defaults
(`docker-compose.prod.yml`, `.env.prod.example`, `deploy/nginx/*`), and the app's sign-in,
token storage and sign-out (`app/lib/data/token_store.dart`, `auth_api.dart`,
`authenticated_http_client.dart`, `features/auth/*`).

How this was done: code reading, plus two things actually run — the `auth/` test suite
(381 tests, all pass; the `*_postgres.js` DB integration tests are not part of `npm test`, so
they were not run) and a bcrypt experiment (finding M1). Nothing was tried against production.
**Not verified:** the live server's `.env` (see "Verify on the server" below).

## Status update (same day)

Done after this review: guest login removed (H3, guest part), `/auth/refresh` fails closed (M2),
code lifetime cut to 60 seconds (affects H1, H2 and the "2 minute" wording below). Still open:
everything else. The email-phone and recovery review is in
`docs/AUTH_EMAIL_PHONE_RECOVERY_REVIEW_2026-11-09.md`.

## Verdict

The design is much better than most apps at this stage: short access tokens, rotating refresh
tokens with reuse detection, a server-side session check on every private API call, v2 OTPs
that are 6-digit, device-bound and single-use, and careful Google account linking. The risks
are not in the core token logic. They are in (1) legacy paths that may still be switched on,
(2) availability and scale limits (the sign-in path is capped at 2 concurrent operations),
(3) rate limiting that is split across three stores and absent from the API service, and
(4) account protection that depends entirely on one email inbox with no alerts.

## Verify on the server first (cannot be seen from the repo)

| Setting | Repo default | Needed |
|---|---|---|
| `AUTH_RETIRE_LEGACY_OTP` | `false` | `true` once the minimum app version is v2 |
| `AUTH_RETIRE_PUBLIC_LOOKUP` | `false` | `true` |
| `ENABLE_PHONE_OTP` | `false` in prod compose | keep `false` until SIM-swap controls exist |
| App build flag `PANDAPAY_OTP_V2_ENABLED` | `false` (app default) | `true` in every release build |
| `OTP_WORK_MAX_CONCURRENT` | `2` | see H2 |
| `AUTH_ABUSE_BUCKET_CAPACITY` | `100000` | see H2 |

## Findings

### High

**H1. Legacy 4-digit OTP is live unless the retire flag is set.**
`otpService.js:107` makes 4-digit codes for v1; `rateLimitMiddleware.js:19-40` allows 3 codes
per 10 min, 10 per day, 5 tries per code, 10 failed tries per hour per identifier. That is up to
50 guesses a day against one account: 0.55% a day, about 16% a month, on a 9,000-code space. A
single IP may request 100 codes a day (`OTP_REQ_IP_DAY_LIMIT`), so one IP gets about 500
guesses a day spread across victims, roughly a 5% chance a day of taking over some account.
v2 (6-digit) is about 100 times harder. The app's v2 flag defaults to off
(`app/lib/app/env.dart:45`) and both server retire flags default to false.
Fix: ship v2 everywhere, set a minimum app version, set both retire flags, delete the
4-digit generator.

**H2. Anyone can take sign-in down, and scale is capped hard.**
- `otpWorkAdmission.js:5` allows 2 concurrent OTP create/verify operations per process; the
  rest get 503. Each holds a slot for a bcrypt hash or compare (about 50 ms here). Verify has no
  per-IP limit (`rateLimitMiddleware.js:312-367` only counts per phone or email), so a script
  sending random identifiers keeps both slots busy and real users see "busy".
- `authAbuseStore.js:44` defaults to 100,000 buckets and fails closed (503) when full. Creating
  a new bucket takes a global advisory lock (`:209`). Unique random identifiers fill the table.
  Day-long buckets do not expire for 24 h.
- Each OTP request runs about six small Postgres transactions (active-code check, two phone or
  email counters, two IP counters, the code claim), each with BEGIN, two SETs, a locking SELECT,
  an UPDATE and COMMIT, on a pool of 10 connections.
Fix: edge limits first (nginx `limit_req`, Cloudflare or a WAF) keyed on IP and `/auth/*`;
replace OTP bcrypt with HMAC-SHA256 using a server-side key (the code lives 2 minutes, is
single-use and attempt-capped, so slow hashing buys nothing); then raise or remove the
concurrency gate; move counters to Redis (M4).

**H3. Unlimited guest tokens and a paid-API path that accepts them.**
`POST /auth/guest-login` (`authRoutes.js:418`) needs no auth and no limit, creates no database
row, and gives a 24-hour token that cannot be revoked. The app never calls it (no match in
`app/lib`). `POST /merchants/nearby/google` (`api/src/index.js:764`) uses `requireValidJwt`,
which checks the signature only, so a guest token works, and the route has no per-user quota
(cache is per process, 150 m reuse, `nearby_google.js:12`). Vary latitude and longitude and each
call is a billed Google Places request.
Fix: delete `/auth/guest-login`; switch that route to `requireAuth`; add a per-user daily quota.

**H4. Account takeover would be silent, and one mailbox is the only lock.**
Prod sign-in is email OTP or Google, so whoever controls the mailbox owns the account (phone OTP
is off, which is right while SIM-swap controls are missing). No code path notifies anyone: no
email or push for a new-device sign-in, a contact change, or logout-all. There is no device cap.
Step-up is weaker than it reads: the `high_assurance` claim is baked into the access token for
its whole 15 minutes (`stepUpAuth.js:48`), and the 5-minute database fallback (`:53`) matches
any recent `otp_verify` for the user on any device, and ignores email and Google sign-ins.
Fix: security emails or push to all other sessions on new device, contact replacement and
logout-all with a one-tap "sign out everywhere"; cap devices (for example 5); make step-up a
single-use, per-session, recent proof.

### Medium

**M1. The refresh-token hash proves nothing and costs CPU.** `tokenService.js:129` and `:187`
store and compare `bcrypt(refreshJWT)`. bcrypt only reads the first 72 bytes, which is the JWT
header plus the first part of the payload. Tested: a token with a garbage signature and the
first 72 characters alone both "matched" the stored hash. The real check is the JWT HMAC, so
this is not an exploit, but the hash layer adds no safety and uses about 50 ms of CPU per
operation (about 75 operations a second on a Mac with 4 libuv threads). A refresh does a compare
and a hash, so on this Mac one process tops out near 35 refreshes a second before any other work. Fix: store
`SHA-256(token)` and compare in constant time; add `algorithms: ['HS256']` to
`jwt.verify` at `:161` (and `api/src/auth.js:26`).

**M2. `/auth/refresh` does not fail closed.** It reads the user without `deleted = FALSE` or
`is_active` (`authRoutes.js:1287`), never checks the device is still active, and treats an
unknown user as a guest (`:1293`). Downstream checks reject the access token, so the damage is
limited, but a disabled account keeps rotating tokens. It also has no rate limit, like
`/auth/google`, `/auth/signup`, `/auth/logout` and `/auth/validate-token`.

**M3. `/auth/signup` issues a token without `device_id`** (`authRoutes.js:1661`). The
per-device revocation check only runs when the claim exists (`authMiddleware.js:47`), so that
15-minute token survives a device sign-out, and it opens a second refresh chain for the device.

**M4. Rate limiting is three systems, and the API has none.**
- OTP and abuse counters: Postgres, durable, shared across instances (good, but see H2).
- User-route limits and enumeration counters: Redis if present, else a per-process Map. Prod
  compose has no Redis, so these reset on every deploy, do not add up across replicas, and
  user limits fail open on error (`userRateLimit.js:160`).
- `api/`: no rate limiting except feedback and test notifications; nginx limits only `/catalogue`.
Fix: one Redis (or Valkey) with atomic counters, enforced at the edge and in the app.

**M5. IP-keyed blocks will hit real users on shared mobile networks.** Enumeration limits are
2 per 10 minutes and 5 per hour per IP, then a one-hour block (`rateLimitMiddleware.js:37-39`).
Indian carrier NAT puts thousands of phones behind one address. Use identifier and device
signals first, IP as a soft score, and group IPv6 by /64.

**M6. One shared signing secret.** `api/` holds the HS256 secret (`api/src/auth.js:20`), so
compromising the much larger API service lets an attacker mint a token for any user.
Fix: ES256 or EdDSA signed by `auth/` only; `api/` keeps the public key (the `kid` rotation
you already built carries over).

**M7. Every private API call costs an auth round-trip plus two queries.** `api/` calls
`/internal/session/verify` (5-second per-process cache of 1,000 entries, `api/src/auth.js:8`),
and `authMiddleware.js:25-56` runs two queries per request. If `auth/` is slow, the whole app
is. Cache session state in Redis with explicit invalidation on logout, ban and token_version
change.

**M8. Account-existence oracles remain on legacy paths.** `/auth/check-user` answers 404 vs 200;
legacy `request-email-otp` answers 404/409 with text that reveals phone-email links
(`authRoutes.js:827-841`). The retire flags remove both.

**M9. Smaller correctness bugs.** `logout-all-other-devices` trusts a device id from a header or
body instead of the token's own (`userRoutes.js:326`); `PUT /users/me` has no validation (a
non-string name returns 500, no length cap, `:195`).

### Low

- Access tokens carry the phone number (PII in every request).
- When the `token_version` column is missing, `authMiddleware.js:59` skips the version check.
- No certificate pinning (acceptable; if added, ship backup pins and a kill switch).
- CORS sets `credentials: true`, unnecessary for bearer tokens.
- `app/android/app/google-services.json` is tracked: confirm the Firebase and Google API keys
  are restricted by package name and API.
- The rules signing key exposed on 7 Nov (see memory note) is still the owner's rotation call.

## App side (UI)

Good: tokens live in Keychain/Keystore (`first_unlock_this_device`, not synced), Android backup
off, cleartext denied, access token refreshed once and shared by concurrent requests, refresh
retry is idempotent via `refresh_request_id`, sign-out revokes on the server (refreshing the
access token first if needed) then wipes database, keys and files.

Gaps:
- Email check is `contains('@')` and phone is "10 or more digits" (`login_screen.dart:198-224`).
  The server validates properly, so this is only UX, but a single email-format check would help.
- Log-in asks for a phone number that is never sent (`:357` sends it only on sign-up), and in v2
  the sign-up phone is not sent either. The form promises a phone link the server does not make.
- The "attempts left" counter is client-side only; the server is the real limit (fine, but the
  UI should not imply otherwise).
- Offline sign-out wipes the phone but leaves the server refresh token alive until it goes idle
  (90 days). Queue a revoke for when the network returns.
- The device id is a random UUID in SharedPreferences (`device_identity.dart`). It identifies,
  it does not authenticate.

## Your questions, answered

**Is the phone number attached to the email and the right user kept?** Identity is a user row
with a UUID. Email and phone are each unique among live accounts, a phone only counts once
verified, and linking a second contact needs proof of the first (`existing_factor_required`).
`POST /profile` takes email and phone only from the auth service's verified record, never from
the request (`api/src/index.js:221-290`). In v2 sign-up the phone is not linked at all; it can
only be added later through the recovery-contact flow, which needs a fresh code on the other
channel.

**Forgot password.** There is no password. Recovery is a code sent to a contact you can still
reach (`recovery_only`), which gives a 15-minute token with no refresh token; the app then asks
for the last 4 characters of the other contact and can replace it using a signed challenge plus
a second code (`recoveryContactRoutes.js`). The "recovery only" limit is a UI convention, not a
server boundary — the 15-minute token works like a normal one — which is fine because the same
code would also sign you in normally.

**Sign up, sign in, sign out across devices.** Each sign-in creates a device row and its own
refresh-token chain; devices are independent, with no cap and no alert. Signing out revokes that
device's refresh tokens and marks the device inactive, so its access tokens stop within the
next request. "Sign out other devices" and "sign out everywhere" (bumps `token_version`) both
need step-up. Reusing an old refresh token revokes that device's tokens.

**Target model:** cap devices at about 5; alert every other session on a new sign-in; give new
devices a cooling-off for exports, contact changes and deletion; bind the refresh token to a
device key held in Keychain/Keystore so a stolen token alone is useless; absolute 180-day
session limit with 30-day idle.

**Rate limiting and Redis.** OTP and abuse limits use a Postgres table, not Redis. Redis code
exists for user-route and enumeration limits but is not deployed, so those are per-process
memory. Details in H2 and M4.

## Fix order

1. Set both retire flags and ship v2-only builds (H1, M8) — config, hours.
2. Delete `/auth/guest-login`; protect `/merchants/nearby/google` (H3) — small code change.
3. nginx `limit_req` on `/auth/*` and the API, then Redis for counters (H2, M4).
4. Replace refresh and OTP bcrypt with SHA-256 / HMAC (M1, H2); pin `algorithms`.
5. Security emails, device cap, real step-up (H4).
6. Fix `/refresh` fail-closed and `/signup` device claim (M2, M3).
7. Move to asymmetric tokens and Redis session cache (M6, M7) — plan as a project.

## Not reviewed

`account_recovery_screen.dart` and `product_activation_screen.dart` in detail; the private admin
gateway and console sessions; SMS v2 rule signing; IMAP credential storage in `api/`; Postgres
row-level security policies; the Twilio and email provider setup; the routes registered in
`api/src/sms_v2` and the account-lifecycle files.
