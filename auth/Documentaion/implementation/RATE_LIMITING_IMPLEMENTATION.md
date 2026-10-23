# Rate Limiting and OTP Throttling

This document describes the OTP-related rate limits and their storage behavior in the auth service. Redis remains in use by other legacy admin, user, and general-purpose rate limiters; those paths are outside this OTP storage change.

## OTP limits

`POST /auth/request-otp` applies the configured phone or email limits and IP limits:

| Scope | Window | Default |
| --- | --- | ---: |
| Phone or email | 10 minutes | 3 requests |
| Phone or email | 24 hours | 10 requests |
| IP address | 10 minutes | 20 requests |
| IP address | 24 hours | 100 requests |

An active OTP marker also prevents another challenge for the same identifier and purpose. The marker is claimed atomically before the OTP row is changed or inserted. A competing request receives HTTP 429. If the abuse store is unavailable, the request receives a controlled HTTP 503 before the OTP provider is called. Storage errors never fail open.

Each OTP has a 2-minute default lifetime and at most 5 verification attempts. The failed-verification quota is 10 attempts per identifier and purpose per hour. Replacement-contact requests also consume stable per-account quotas: the configured phone/email request limits per 10 minutes and day, and the failed-verification limit per hour. These replacement buckets use the authenticated account ID and channel, so creating another replacement identifier does not reset the quota.

Quota refusals use HTTP 429. Storage or capacity failures use HTTP 503. A successfully verified OTP is consumed by the OTP service; its active marker is cleared by a compare-delete operation tied to that OTP's request ID. Delivery cleanup can clear only the marker created by that request, so a late failure cannot clear a newer challenge.

## OTP abuse store

In production and staging, OTP rate counters, active markers, and replacement quotas use the PostgreSQL `auth_abuse_buckets` table. `AUTH_ABUSE_STORE` cannot select memory storage in hosted environments. Development and tests can explicitly set `AUTH_ABUSE_STORE=memory`; the default in those environments is the process-local memory store.

PostgreSQL keys are domain-separated HMAC-SHA256 digests using the existing `PHONE_LOOKUP_HMAC_KEY`. Raw phone numbers, email addresses, IP addresses, and account IDs are not stored in the bucket key column. TTL comparisons and expiry updates use the database clock. Counter updates saturate at the configured limit plus one, enough to keep returning a refusal without unbounded counter growth.

The default `AUTH_ABUSE_BUCKET_CAPACITY` is 100000 rows. It bounds live bucket records, not physical database bytes. When creating a new bucket at capacity, the store deletes at most 200 expired rows using bounded cleanup; if capacity remains exhausted, it refuses the operation with HTTP 503. Monitor database disk usage and table/index bloat separately: PostgreSQL may retain dead tuples and free-space overhead after expired rows are deleted, so this row cap is not a physical storage cap.

The runtime database role needs `SELECT`, `INSERT`, `UPDATE`, and `DELETE` on `auth_abuse_buckets`. Use the canonical migration setup or provision those narrow privileges explicitly for a distinct runtime role. Keep `PUBLIC` access revoked. The readiness check should report missing table privileges before accepting OTP traffic.

## Configuration

```dotenv
OTP_REQ_PHONE_10MIN_LIMIT=3
OTP_REQ_PHONE_DAY_LIMIT=10
OTP_REQ_EMAIL_10MIN_LIMIT=3
OTP_REQ_EMAIL_DAY_LIMIT=10
OTP_REQ_IP_10MIN_LIMIT=20
OTP_REQ_IP_DAY_LIMIT=100
OTP_VERIFY_MAX_ATTEMPTS=5
OTP_VERIFY_FAILED_PER_HOUR_LIMIT=10
OTP_TTL_SECONDS=120

# Maximum number of abuse-bucket rows; default 100000. This is not a byte cap.
AUTH_ABUSE_BUCKET_CAPACITY=100000

# Local development/test only. Hosted environments always require PostgreSQL.
# AUTH_ABUSE_STORE=memory
```

`PHONE_LOOKUP_HMAC_KEY` must remain stable across auth instances and restarts. It must contain at least 32 bytes. Rotating it changes bucket digests and effectively starts new rate-limit buckets; coordinate rotation rather than changing it casually.

`REDIS_URL` and `REDIS_HOST`/`REDIS_PORT` remain relevant to other legacy limiter components. They do not select the OTP abuse store.

## Request path and failure behavior

For ordinary OTP requests, the phone/email active-marker check and phone/email/IP request limits run before OTP creation. OTP creation then atomically claims the active marker before retiring or inserting OTP rows. If database writes fail after claiming, cleanup compare-deletes only that request's marker. An active marker belonging to a different request remains untouched.

Replacement OTP requests and verification attempts consume account-scoped quota before proceeding. These increments are atomic and occur before each attempt, including when the request is later refused. Stable account IDs and channels are bounded before key construction; the HMAC store prevents those identifiers from appearing in database keys.

If PostgreSQL is unavailable, the pool times out, the table is full, or a required permission is missing, affected OTP operations fail closed with a generic 503. They do not send an OTP through email or SMS while storage is unavailable. Other limiter implementations that still use Redis are not covered by this guarantee.

## Operational checks

- Confirm the auth migration has created `auth_abuse_buckets` before enabling OTP traffic.
- Confirm the runtime role has the four narrow DML privileges and `PUBLIC` has none.
- Monitor `auth_abuse_buckets` row count, database storage, and table/index bloat. The configured row cap does not cap physical bytes.
- Treat changes to `PHONE_LOOKUP_HMAC_KEY` as rate-limit state rotation.
- Test OTP request and verification flows with synthetic identities in development or a disposable test database. Do not put real contact values in logs or test output.
