# Bounded OTP work and delivery — 25 October 2026

The first [next launch batch](security-next-launch-batches-2026-10-25.md) is implemented and locally verified. Auth now bounds concurrent OTP issuance/verification and email/SMS sends, shares pending dummy-hash initialization and returns retryable capacity errors. This is a source improvement for LP04/LP06, I09/I12 and G05/G06; actual provider quotas and unrestricted launch remain unaccepted. It adds no vulnerability count and closes no whole finding or package.

## Runtime behavior

| Limit, per auth process | Default | Scope |
| --- | --- | --- |
| `OTP_WORK_MAX_CONCURRENT` | 2 | One shared admission limit for all legacy/V2 issuance and verification, across phone/email and signin/recovery/replacement. A slot covers the service operation including database work and bcrypt. |
| `OTP_EMAIL_MAX_CONCURRENT` | 2 | Actual concurrent Nodemailer OTP sends, shared by signin, recovery and replacement. |
| `OTP_SMS_MAX_CONCURRENT` | 2 | Actual concurrent Twilio OTP sends, shared by the same flows. |

Configuration accepts integer strings **1 through 16**; empty/unset uses the default. Invalid values fail initialization rather than creating an unlimited stage. The production/staging examples explicitly pass the defaults only to auth. These are conservative starting bounds, not measured capacity recommendations. Changing them requires matching release inputs and fresh workload acceptance.

There is **no waiting queue**, per-recipient map or unbounded timer set. Admission checks and takes a slot synchronously before invoking work. It releases a slot only when the underlying operation settles, including synchronous exceptions and asynchronous failures. A caller abandoning its HTTP wait does not free a slot while native hashing or provider I/O is still active. Existing database and provider timeouts remain; no artificial timer starts duplicate replacement work.

Work rejected at the OTP-service boundary makes no OTP query, claim, attempt increment, code issuance or consume. Earlier HTTP validation and shared abuse admission can already have run; the local gate is not a bound on every database call in an authentication route. Existing active-code, recipient/IP/global and replacement budgets still apply and can reject earlier with 429. A service slot ends after its operation; later account/session creation and route-level work remain covered by their existing controls and still need full workload acceptance.

If provider capacity is exhausted **after issuance**, the provider service returns a fixed failure without invoking its SDK. The route discards the exact undelivered challenge and clears only its marker before responding. Normal request/send budgets are not refunded: repeated failures must not bypass spend/abuse limits. If cleanup storage is unavailable, the request stays unsuccessful and the bounded marker expires normally; the route does not pretend delivery succeeded. No provider retry or extra OTP is introduced. An accepted provider response remains transport acceptance, not proof that the user received the message.

Capacity responses use HTTP **503**, `Retry-After: 2`, `Cache-Control: no-store`, a fixed human-readable error and `code: otp_capacity_unavailable`. They reveal no account state, OTP, recipient, queue length or deployment limit. The short retry hint is not a guarantee of recovered capacity. Clients retain the code/draft and can retry; no automatic resend or new customer password is added. Busy known/missing OTPs use the same admission path. Admitted missing-code requests still compare against a shared dummy hash; real bcrypt cost remains 10. This reduces a source of timing variation without claiming the full database/HTTP flow is constant time.

The admission module offers bounded count-only in-process snapshots for tests/future private monitoring; it stores no identities and exposes no new HTTP endpoint. The counters saturate rather than overflow. They are not durable, multi-instance quotas or an installed monitoring system.

Sources: [admission](../auth/src/services/otpWorkAdmission.js), [OTP operations](../auth/src/services/otpService.js), [email](../auth/src/services/emailService.js), [SMS](../auth/src/services/smsService.js), [auth routes](../auth/src/routes/authRoutes.js), [contact replacement](../auth/src/routes/recoveryContactRoutes.js). Asynchronous bcrypt still uses native worker resources; limiting admitted work supplements existing security rather than lowering its cost. [bcrypt guidance](https://github.com/kelektiv/node.bcrypt.js#why-is-async-mode-recommended-over-sync-mode), [Node worker-pool setting](https://nodejs.org/docs/latest-v22.x/api/cli.html#uv_threadpool_sizesize).

## Release integration and rollout

`release_security_check.js --template` now includes credential-free `otpCapacity` values:

```json
{
  "workMaxConcurrent": 2,
  "emailMaxConcurrent": 2,
  "smsMaxConcurrent": 2
}
```

These must exactly match auth's `OTP_*_MAX_CONCURRENT` environment. A malformed runtime value or missing/mismatched manifest keeps `otp_capacity_limits` missing. The configuration digest includes this manifest. The existing hash-checked evidence flow now also requires `checks.otp_capacity_acceptance` with `status: passed`, `failed: 0`, the exact candidate hash and proof-file hash; full evidence binds the exact configuration digest. Old partial or differently configured test records do not satisfy it. The proof must document the intended replica count, total provider quota and workload envelope; an operator's JSON label is not independent provider verification.

The separate physical-cluster budget and all actual-data/provider/mobile/custody/release gates remain required. Do not add replicas to bypass a local limit without updating aggregate connection, OTP/spend and provider budgets. Two instances each admitting two sends can have four sends active; there is no claim of distributed concurrency coordination in this batch. Do not raise limits to hide rejected legitimate signups.

Build and test the exact auth image, keep existing keys/schema/feature settings, validate current clients and perform isolated burst/shared-NAT/provider-outage tests. Then use the existing reviewed rollout procedure. The code adds no migration, cipher change, key rotation/backfill, data deletion, extra password or default-on recovery/storage conversion. It is PostgreSQL-provider portable. This batch was not deployed; selecting a previous image does not undo already-consumed OTPs or any other committed state, so preserve the normal recovery procedure.

## Local verification

- **340 auth tests passed**; **211 database-tool tests passed**; **22 deployment-script tests passed**. The focused run had 132 passes, overlapping those suites. Local Node was 24.15.0; the existing Node 22 CI/image gate was not run in this batch.
- Native bcrypt tests prove cost 10, one pending dummy initialization for two admitted misses, and immediate rejection of 18 excess operations in a synthetic 20-operation burst. Controlled stalls/failures prove no waiting callbacks, no early slot release and retry after settlement. This is a correctness fixture, not a throughput benchmark.
- Legacy/V2 phone/email request and verification HTTP fixtures, plus replacement flows, return the safe busy contract. Provider saturation reaches no SDK send in the rejected service call; issued-challenge/marker cleanup and unchanged contact values are checked.
- A newly owned loopback-only **PostgreSQL 18.4** cluster passed the real OTP purpose/legacy/V2/device/single-use/attempt-cap fixtures and shared PostgreSQL abuse-store regressions. The added saturation check compares all challenge IDs/attempts/consumption/deletion before/after rejection, then verifies the same existing code after slots return. It uses synthetic rows and keys; actual Supabase/PostgreSQL 17/customer data were not tested here.
- Auth source syntax checks, deterministic report rendering, offline HTML interactions/local links and whitespace checks passed. Test processes used empty temporary working directories and a synthetic allowlisted environment to avoid saved configuration. Loopback HTTP/SMTP/PostgreSQL tests needed sandbox permission to bind local listeners; no live provider message or live database access occurred.

[Exact scoped verification](../artifacts/security-otp-admission-2026-10-25/verification.json). Previous full API/app/native/provider evidence remains bound to its dated candidate; it was not rerun or promoted here. The next pending work is the LP01 actual-role/consumer review, independent recovery custody, verified host/provider limits and production-shaped acceptance described in the [batch plan](security-next-launch-batches-2026-10-25.md).
