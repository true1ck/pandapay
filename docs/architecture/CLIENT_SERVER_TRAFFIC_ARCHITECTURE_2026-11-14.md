# Client–server traffic architecture (design)

Status: proposed, 14 Nov 2026. Written after profiling the API and auditing the app's networking.
Owners: **api/** = backend-performance session, **app/** = offline/online-mode session, deploy config = release manager.
Public repo: all numbers below come from synthetic benchmark data (`api/scripts/bench_*.js`).

## 1. What we found

| Finding | Evidence |
|---|---|
| A device uses ~8–12 separate HTTP clients, each with its own socket pool | `main.dart:51` factory builds a new `IOClient` per `http.Client()`; ~50 repositories default to `client ?? http.Client()` |
| Nothing caps total in-flight requests; cold start ≈ 12–20, resume ≈ 12–18 | code reading (estimate, not measured on a device) |
| HTTP/1.1 only: N parallel requests = N sockets and N TLS handshakes | `dart:io HttpClient` has no HTTP/2; nginx already has `http2 on` |
| No jitter at start/resume; redundant calls on every resume/sync (`/auth/refresh`, `/user-settings`, `/self-transfer-rules`, `/transaction-tags`, `GET /sms/v2/sync`) | sync_engine.dart, providers.dart |
| App never sends `If-None-Match`, although `/catalogue` has ETag/304 | grep of app/lib |
| Server: Node is not the limit (event-loop delay p99 ≈ 12 ms, max ≈ 35 ms at 300 users, ~0.7 core); the database is (≈ 11–15 ms Postgres CPU vs ≈ 4 ms API CPU per request) | `bench_http.js --conc 100 --users 200` |
| Realistic burst: 100 different users × 13 calls finish in ~6–8 s with no failures. Earlier "60 s" numbers came from all users sharing one 40k-row account | same bench |
| 1 API process saturates at ~1 core ≈ 130–200 req/s; 2–3 instances ≈ 1.5–2.2×; beyond that Postgres is the limit on the test machine | `--instances K` |

## 2. Target architecture

```
 Feature code ─► Request scheduler ─► ONE shared HTTP client ═ one HTTP/2 connection ═► nginx ─► API replicas ─► Postgres
                 priority, cap 3–4,    (cronet_http / cupertino_http;       http2, gzip,   admission line,   pool / PgBouncer
                 coalesce, jitter,      HTTP/1.1 fallback elsewhere)         upstream       per-user lanes,
                 ServerBackoff pause                                         keepalive      class caps, deadline
```

"One device = one connection" means **one multiplexed HTTP/2 connection to the API host (plus one to the auth host)** carrying a
few concurrent streams. It does not mean one request at a time: on HTTP/1.1 that would block everything behind the slowest call.

## 3. Decisions

**D1. One shared transport per origin.** `http.runWithClient` returns a single shared instance (not a new one per call); repositories stop
creating their own clients; closing is owned by the provider only. On Android use `cronet_http`, on iOS `cupertino_http` (both implement
`package:http` `Client`, HTTP/2, HTTP/3 where available); keep `IOClient` as the fallback. Spike first: verify the 401-refresh wrapper,
timeouts, certificate behaviour and the debug SMS rig still work.

**D2. A client request scheduler** in front of the shared client (inside `ApiRequestHeadersClient`, the one wrapper every client already uses):
- priorities: P0 auth + user-initiated writes, P1 reads the visible screen needs, P2 background sync, P3 telemetry/analytics;
- max in-flight 4 (P2/P3 share at most 2); timers for header/body/overall timeouts start at dispatch, not at enqueue;
- single-flight for identical in-flight GETs; cancel queued requests for a screen that was left;
- random 0–30 s delay for background work on cold start and resume (unscheduled starters today: settings sync, SMS v2, shared expenses, push registration, Home refresh); keep `ServerBackoff` as the reactive pause.
- throttle redundant calls: `/auth/refresh` only when the token is near expiry (not on every resume), `/user-settings`, `/self-transfer-rules`, `/transaction-tags` at most once per N minutes unless a change is known.

**D3. Fewer, bigger calls: a sync-session/bootstrap endpoint** (additive, versioned). One request returns the sections Home needs
(cards, overrides, home summary, settings, user-state delta, tags delta, self-transfer rules, change cursor), each with a version token; the
client sends the tokens it has and the server answers "unchanged" per section. The server builds it in one transaction: one auth check,
one membership check, one connection. Replaces Home's 6 parallel calls and the per-sync GETs. Design the response shape with the app session before building.

**D4. Caching only where it pays.**
- shared reference data (catalogue, categories, app status, changelog, merchants): conditional GET (ETag / `If-None-Match`), long `Cache-Control`; nginx `proxy_cache` optional;
- location data: already cached (server in-process with request sharing; device cache); revisit a shared cache when there is more than one API instance;
- per-user data: **no server-side data cache** (low hit rate, correctness risk). The app is local-first, so the win is "skip the work when nothing changed" (D3 version tokens), not Redis.

**D5. Overload contract (server → client).** Implemented in `api/src/admission.js`:
- bounded first-come-first-served line in front of the database: overall cap = pool size, caps for `/sync/push` and heavy reads, one `/sync/push` per user, 13 s max wait (the app gives up at 15 s), a client that disconnects while waiting leaves the line;
- refusal = **503 + `Retry-After`** (whole seconds, 5–60, ±50% random jitter), small JSON body `{"error":"server_busy","retryable":true}`; pool-timeout 500s are converted to 503. **Never 500 for load**: the app parks a change for an hour after repeated 500s on the same row;
- client: honour `Retry-After` with extra jitter, cap 10 minutes (offline session, `server_backoff.dart`).

**D6. Writes.** Every mutation idempotent (client mutation id or natural key); per-user ordering; `/sync/push` becomes **set-based** (one database call for many changes instead of SAVEPOINT + call + RELEASE per change) with savepoints kept only as the fallback for a failing item. Cross-user batching only through a privileged worker role (row-level security binds a transaction to one user): later, if numbers justify it.

**D7. Scale-out.** Stateless API replicas behind nginx (`upstream` with `keepalive`, JSON gzip), pool budget `DB_POOL_MAX × replicas < max_connections` (PgBouncer in transaction mode if needed), a database-level per-user lock for pushes (admission lanes are per process), background workers already use locks/leases.

**D8. Observability and SLOs.** Admission stats are logged every 30 s while busy (`msg:"admission"`: active, queued, refused, pool waiting). Add per-route p95, 503 rate and queue wait to the dashboards. Starting SLOs: 100 simultaneous users complete a screen open in < 10 s with 0 non-503 errors; 503 rate < 1% in normal traffic.

## 4. Status codes → client behaviour

| Status | Meaning | Client |
|---|---|---|
| 200/201 | done | clear from queue |
| 304 / section "unchanged" | nothing new | keep local copy |
| 400/413/422 | this request is wrong | isolate/park, user-visible |
| 401 | session | one refresh + retry |
| 429/503 + `Retry-After` | server busy | pause queues for that many seconds + jitter, keep data |
| 500 | bug/unknown | retry with backoff; head row held only after repeated failures |

## 5. Plan, owners, acceptance

| # | Work | Owner | Done when |
|---|---|---|---|
| 1 | Admission line, 503 contract, jitter, stats log | api (done) | `test/admission.test.js`; 100-user burst: 0 × 500 |
| 2 | Shared client + scheduler (D1, D2), throttle redundant calls | app | one client instance; ≤ 4 in flight; resume makes ≤ 6 requests; resume jitter test |
| 3 | HTTP/2 transport spike (cronet_http / cupertino_http) | app | one TCP connection per origin seen by nginx logs; no regression in refresh/timeouts |
| 4 | ETag/conditional GET for catalogue/categories | app (+ api already) | 304 on repeat opens |
| 5 | nginx: gzip JSON, upstream keepalive, `proxy_http_version 1.1` + `Connection ""` | release manager | `/transactions` page < 25 KB on the wire |
| 6 | `/sync/push` set-based | api | push of 200 changes: ≥ 3× fewer DB round trips, same result rows |
| 7 | Bootstrap endpoint (D3) | api + app | Home open = 1 request; unchanged sections answered without queries |
| 8 | 2–3 API replicas, per-user DB lock, pool budget | release manager + api | burst of 300 users: no 503 at < 15 s |
| 9 | `GET /user-cards` / `GET /recurring` stop writing on read | api | GET is read-only; no per-call repair loop |

## 6. Worst cases to keep in mind

Thundering herd after a deploy/outage/scheduled push (D2 jitter, D5 jitter); retry storms (Retry-After + client pause); one huge or newly
reinstalled account (per-user lane for heavy reads, paged pull); abandoned requests still running in the database (cancel on disconnect,
lower read timeout); auth service slow/down (every private request becomes 503: scale it with the API); multi-replica ordering; duplicate pushes
(no unique `(device, client_seq)` today); large uncompressed responses; `Promise.all` on one `pg` connection (deprecated in pg@9).

## 7. Deliberately not doing now

Redis/Kafka/SQS, WebSockets, a per-user data cache, cross-user transaction batching. Revisit when the load numbers after steps 1–8 say the database is
still the limit or when there are several API replicas that need a shared queue.

## 8. Decisions needed from the owner

1. Approve the HTTP/2 transport spike (adds `cronet_http` / `cupertino_http` dependencies).
2. Approve a bootstrap endpoint as the Home data source (changes the data flow on screen open).
3. Production `DB_POOL_MAX`, `max_connections`, number of replicas, and whether PgBouncer is acceptable.
