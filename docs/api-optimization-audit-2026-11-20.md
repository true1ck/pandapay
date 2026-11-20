# API optimisation audit — 20 Nov 2026

Why: the iPhone could not finish its first SMS sync. The phone asked `GET /sms/v2/sync` with no cursor, the server
built a 1.85 MB answer, and the connection was closed before the answer started ("Connection closed before full
header was received", read from the phone's new "Last sync problem" line). The same page was asked for again on every
sync, so the AI answers in it never arrived either.

Numbers below are **measured** unless marked *estimate*:
- traffic: production nginx access log, 13–20 Nov 2026 (7 days);
- server time: the API's own request log since the 20 Nov 15:52 UTC restart (few calls, so a rough guide only);
- page contents: a read-only run of the real sync query on the owner's account inside the production API container.

## 1. What was wrong with `/sms/v2/sync`

| Finding | Evidence | Effect |
|---|---|---|
| A page held up to 1,000 rows of **each** of four kinds (facts, events, ledger rows, accounts) | page 1 for the owner: 1,000 facts + 1,000 events + 1,000 ledger + 33 accounts = 3,033 rows | one request carried a third of a two-year history |
| Nothing was compressed | nginx `gzip on` covers only `text/html`; JSON went out raw (1,736,967 bytes; the same page gzipped is 350,299) | 5x more bytes than needed on a slow link and a busy host |
| Facts are the heaviest rows | 743 bytes per fact on average, 43% of the page; the `updatedAt` map adds another 11% | |
| **A fact could be skipped for good** (data loss, pre-existing) | facts were stamped with `created_at = now()`, which is the time the upload's transaction **started**, before it waited for the profile lock. An upload that started first but got the lock second wrote facts dated before rows another phone had already read, and that phone's cursor moved past them. Reproduced in a test against real Postgres: the late fact was never sent. | a second phone silently missed facts uploaded at the same moment by the first |

## 2. What is changed (server only, no app change needed)

| Change | Where | Result |
|---|---|---|
| Gzip every compressible answer above 1 KB for clients that send `Accept-Encoding: gzip` | `api/src/response_compression.js` (the standard `compression` package), mounted before all routes in `index.js` | every phone build already sends that header and inflates (dart:io `IOClient`), so all existing builds get it. Answers a route already gzips (rules, catalogue), tiny answers, `no-transform` answers and clients that do not ask are left alone. |
| Sync pages hold **250** rows per kind by default; a phone may ask for 1–1,000 with `?limit=` | `storage.readChanges` / `syncPageSize`, `sync_route.js` | page 1 drops from 1.74 MB to about 430 KB raw, about 90 KB gzipped (*estimate* from the measured per-row sizes). Paging is by cursor, so a smaller page never skips or repeats a row; the phone already keeps asking while `X-Sms-Sync-Has-More` is 1 and saves its cursor after **each** page, so progress is kept even if a later page fails. |
| Facts are stamped with `clock_timestamp()` **after** the profile lock | `storage.insertFacts` | facts now sort in commit order like the other three kinds (they already used `clock_timestamp()` after the lock), so no phone can skip one. Rows already stored are unaffected. |

What a phone sees: the same JSON shape, the same cursor format, the same rows. Nothing is dropped, nothing is invented;
it simply arrives in more, smaller, compressed pages. A full first sync of the owner's account is now about 21 pages
of about 90 KB instead of 6 pages of 1.7 MB.

Tests: `api/test/response_compression.test.js` (6), `api/test/sms_v2/sync_route_paging.test.js` (3), two new tests in
`api/test/sms_v2/facts_pg.test.js` against real Postgres (the late-commit race, page sizes and clamping); the existing
1,000-row paging test now asks for 1,000 explicitly.

## 2b. Round 2: where the server did heavy work for nothing (measured on production, then fixed)

Rule followed: the app must see exactly what it saw before, as fresh as before, with every call it makes today.
Only work whose result is provably identical is skipped.

| Call | What the server did on every call (measured) | Fix | Freshness |
|---|---|---|---|
| `GET /user-cards` (p50 7.0 s, p90 15.4 s) | Took the **same per-account lock as an SMS upload**, so a wallet read waited for any upload in progress; then deleted and rebuilt cap and milestone state for every card (owner, 10 cards: **4.1-6.0 s**, every card came out unchanged); swept all reward facts for bank credits (0.06-0.55 s); then 4 more queries per card. | `card_state_read_gate.js`: a 22 ms fingerprint of everything the rebuild reads and writes (card row, product rules version, every transaction on the card, the stored cap and milestone rows, the India day and the server day). A card is rebuilt, under the lock, only when its fingerprint changed; same for the credit sweep (reward facts, account links, credit rows). Points totals and fee waivers: one query each for all cards instead of two per card. Milestones: "is this card v2?" answered from a shape cache keyed on the rules version instead of reloading every rule per card (`isV2Card`). | Identical. Any change to any input, or to the stored results by any other writer, forces the rebuild on that read. A restart forgets the marks, so the first read rebuilds everything, as every read did before. |
| `GET /catalogue?schema=2` | 444 cards built from heavy views every download: **10,566,380 bytes** raw, 1,342,810 gzipped, ~1.9 s of view queries + 0.4 s of gzip per download (v1 feed: 4.1 MB, 3.1 s). | The finished gzipped body of each catalogue version is built once and reused (`catalogue_route.js`); concurrent requests share one build; a failed build is not kept; only the newest version per feed is held (~2 MB). | Identical. The version check (fingerprint) still runs on every request, so a changed catalogue is built and served at once. Phones already send `If-None-Match`: on 20 Nov 39 of 54 catalogue requests were 304s. |

Expected `GET /user-cards` after the fix for an unchanged wallet: about 0.3-0.6 s instead of 7 s (*estimate* from the measured parts: 2 fingerprints at ~22 ms, cap reads ~0.2 s, milestone reads now one small query per card, 2 batched queries).

Looked at and left as they are (no wasted work found in the code):
- `GET /user-cards/:id/points-ledger` (2.3 s): one ownership check and one indexed read. The time is the overloaded host and the connection queue, not the query.
- `POST /foreign-payments/refresh` (16 s): up to 20 pending payments, each with a reference-rate lookup (cached in the database after the first fetch) and its own transaction that takes the upload lock. It can be made faster by fetching the distinct rates up front and processing the batch in one transaction, but that changes how partial progress is kept, so it needs its own change and tests.
- `POST /merchants/nearby/discover` (77% 5xx): the outside map service fails; needs a circuit breaker and a cached fallback, not a server-side rewrite.

### nginx (production config read 20 Nov)
| Finding | Change to make (owner's go-ahead, applied with `nginx -t` and a reload) |
|---|---|
| `gzip on` only for HTML | not needed for the API any more (the API compresses); leave nginx as is so nothing is compressed twice |
| No upstream keepalive: a new TCP connection to the API for every request | `upstream pandapay_api { server 127.0.0.1:4000; keepalive 32; }`, `proxy_pass http://pandapay_api;`, `proxy_set_header Connection "";` |
| Access log has no timings and was never rotated (one 91 MB file since 4 Aug) | log format with `$request_time $upstream_response_time $upstream_status`; fix logrotate for `/var/log/nginx/*.log` |
| Bots probe `/.env`, `/.git/config`, `/.aws/credentials`, `/` (~2,500 a week) and reach the API | `location ~ /\. { deny all; }` and `location = / { return 404; }` in the API server block; a small `limit_req` zone per IP |
| TLS 1.0 and 1.1 enabled in the http block | `ssl_protocols TLSv1.2 TLSv1.3;` (check the certbot include does not override it) |

## 3. Every busy API route (7 days, 13–20 Nov)

"Gave up" is nginx status 499: the phone stopped waiting. Server time is the API's own measurement today (p50 / p90
where there were enough calls).

| Route | Calls | Avg size | Max size | 5xx | Gave up | Server time | State now | What to do next |
|---|---:|---:|---:|---:|---:|---|---|---|
| `GET /sms/v2/sync` | 1,151 | 656 KB | 1.85 MB | 48 | 236 | 2.6 s | **fixed here**: 250-row pages, gzip, no skipped facts | nothing more needed for the size; see capacity below |
| `GET /catalogue` | 782 | 934 KB | 10.5 MB | 61 | 102 | 3.5 s | **fixed in round 2**: each version built once and reused; own gzip + ETag/304 | the 10.5 MB answers are the v2 body sent **unzipped** (curl/PowerShell tests and old builds). Next: send only the cards that changed since the phone's version (per-card `data_version`), which needs an app change |
| `GET /transactions` | 1,623 | 140 KB | 1.0 MB | 54 | 13 | 0.5 s / 2.8 s | paged (200, max 500); now gzipped | ask only for changes since the last list (a `since` cursor or ETag) instead of re-reading 200 rows; drop fields the list does not show |
| `GET /user-cards` | 1,294 | 2.5 KB | 9.4 KB | 111 | 123 | **7.0 s / 15.4 s** | **fixed in round 2**: rebuild only when inputs change, batched reads, no upload-lock wait when nothing changed | — |
| `GET /user-cards/:id/points-ledger` | 546 | 6 KB | 62 KB | 41 | 18 | 2.3 s | one call per card | one call for all cards, paged |
| `GET /app-status` | 3,053 | 89 B | 176 B | 190 | 648 | 0.1 s | fixed 20 Nov (cached; builds 194+ probe `/health`) | nothing; traffic falls as phones update |
| `GET /consents` | 1,780 | 391 B | 627 B | 52 | 15 | 4.1 s | read on many screens | keep it on the phone, refresh on change or with ETag |
| `GET /shared-expenses/changes` | 1,431 | 370 B | 6 KB | 34 | 35 | 0.3 s | polling | fine; poll less often in the background |
| `GET /card-overrides` | 1,121 | 93 B | 715 B | 99 | 54 | 1.1 s / 4.2 s | small, slow | fold into one app-open call (below) |
| `POST /auth/refresh` | 1,021 | 713 B | 775 B | 17 | 58 | — | fine | — |
| `GET /home-summary` | 834 | 97 B | 166 B | 83 | 52 | 3.8 s | small, slow | cache per user, refresh on change |
| `GET /sync/pull` (old sync) | 820 | 58 B | 656 B | 83 | 50 | 2.8 s | almost always empty | stop calling it from SMS-v2-only builds, or answer from an index without a transaction |
| `GET /categories` | 753 | 1.1 KB | 1.2 KB | 33 | 31 | 0.15 s | fine | ETag + long cache |
| `GET /shared-expenses/capabilities` | 696 | 104 B | 166 B | 53 | 24 | 1.2–4.8 s | read every app open | cache for the session |
| `GET /user-settings`, `GET /user-state` | 676 / 461 | ~100 B | 166 B | 54 / 44 | 36 / 16 | 2.7–2.8 s | read every app open | fold into one app-open call |
| `POST /sms/v2/facts:batch` | 454 | 7.9 KB | 194 KB | 35 | 83 | 10.3 s | 503 + Retry-After on DB timeout (20 Nov); gzip upload | send smaller batches when the server is slow; later, accept the batch and process it in a queue |
| `GET /sms/v2/ai-status` | 355 | 92 B | 176 B | 59 | 24 | 0.35 s | fine | — |
| `GET /sms/v2/rules` | 213 | 18 KB | 182 KB | 4 | 43 | — | own gzip + ETag | fine |
| `POST /foreign-payments/refresh` | 165 | 1.2 KB | 10 KB | 30 | 7 | **16.4 s** | waits on an outside rate service | refresh in the background, answer from the cache at once |
| `GET /account-summaries` | 136 | 21 B | 166 B | 14 | 3 | 4.7 s | small, slow | profile the query |
| `GET /bills/projections` | 160 | 33 B | 166 B | 9 | 3 | 4.5 s | small, slow | cache per user |
| `POST /merchants/nearby/discover` | 81 | 346 B | 7 KB | **62 (77%)** | 10 | — | outside map service fails most calls | add a circuit breaker; stop offering it while it fails |
| `POST /merchants/nearby/google` | — | — | — | — | — | 10.5 s | outside service | time-box to ~3 s with a cached fallback |
| `POST /notification-devices` | 167 | 33 B | 40 B | 8 | 2 | — | was 78% 5xx since August, now low | keep an eye on it |
| Old AI jobs: `POST /ai/jobs`, `GET /ai/jobs/source/:id` | 0 this week (60,664 + many polls since Aug, 88% 5xx) | — | — | — | — | — | old builds only | answer 410 Gone so any old build stops retrying |
| Bot probes: `GET /`, `/.env*`, `/.git/config`, `/.aws/credentials`, … | ~2,500 | — | — | — | — | — | reach nginx | deny dotfiles and unknown paths in nginx, rate-limit by IP |

## 4. Across all routes

| Issue | Evidence | Fix |
|---|---|---|
| No compression for JSON | nginx gzip is HTML-only | **done** in the API (all routes) |
| One app open fires ~50 requests in 15 s | measured 20 Nov (doc `ios-live-sms-and-connection-investigation-2026-11-20.md`) | one `GET /bootstrap` that returns consents, settings, state, capabilities, overrides and home summary in one answer, with ETag |
| The host is starved | Oracle E2.1.Micro, 954 MB RAM, 35–75% CPU steal, ~1.1 GB swap; authenticated p50 1.3 s, p90 8 s | a bigger VM (owner's decision); everything above only reduces the load |
| Small answers take seconds | `/user-cards` 7 s, `/home-summary` 3.8 s, `/consents` 4.1 s for under 3 KB | time is in the database or waiting for a pool slot, not in the bytes: EXPLAIN the slow queries, add indexes, cache |
| nginx log never rotated and has no timing | one 91 MB `access.log` since 4 Aug; combined format | logrotate, and add `$request_time $upstream_response_time` to the format |

## 4b. Round 3, 21 Nov 01:40 IST: after the deploys, the iPhone still waited (measured on production)

| Finding | Evidence | Done |
|---|---|---|
| Sync answered 429 to the iPhone | 120 sync pages an hour, 60 for a phone without App Check (every iPhone on the free Apple team); a first sync of a 2-year backlog is hundreds of 250-row pages | limit 480 an hour (240 halved) in `sms_v2/security.js`, still per phone, still halved without App Check |
| Two or three identical wallet reads at app open | `/user-cards` pairs 30 ms apart, 4.5–25 s each | `request_coalescer.js`: reads that arrive during a run share **one follow-up run that starts after they arrived** (never the earlier run's answer, so no older data); the follow-up is cheap because the read gate sees nothing changed |
| Each app open reopened the database pool | pool fell to 1 connection 10 s after each burst; a new TLS connection to the pooler costs 150–225 ms, a query on an open one 20 ms (measured from the API container) | `DB_POOL_MIN=4` for the API only (`config.js`, `db.js`, compose); the rewards worker keeps 0 |
| **The real cause of 5–20 s stalls: the VM runs out of memory** | 954 MB RAM, 887 MB in swap; the auth service holds 27 MB in RAM and 91 MB on disk, the API 28 MB and 37 MB, and every API call checks the session with auth (cached 5 s), so the first call after a quiet spell waits for both to be read back from disk; kernel pressure counters with the box idle: all tasks stalled on memory 17% and on disk 35% of the last 10 s; ~550 GB swapped in and out since boot; at 19:55–19:56 UTC even `/categories` and `/catalogue` waited 7–20 s and failed with "database unavailable" | **not fixable in code.** Owner's choice, below |

What uses the memory (in RAM + swapped, 21 Nov): dockerd ~140 MB, two admin servers ~205 MB, SMS template worker
~130 MB, auth ~118 MB, maps scraper with Playwright ~80 MB, an old PM2 `pandapal-auth-service` plus its PM2 daemon
~70 MB (still served at `auth.pandapath.in`, port 3000, running since August), API ~65 MB, admin rule jobs ~33 MB,
Oracle agent ~25 MB.

The swap file (4 GB, since 4 Aug) is why the box stays up instead of killing processes; it is not extra RAM. The disk
is fine (0.5 ms per 4 KB read, 212 MB/s); the problem is how much moves between RAM and disk.

**Done on the host 21 Nov 01:53 IST (owner asked to make the server better), each reversible:**

| Change | Why | Undo |
|---|---|---|
| zswap on (lz4, pool up to 20% of RAM), `/etc/systemd/system/zswap.service`, enabled at boot | idle memory is compressed in RAM (~3:1) before anything goes to disk, so far fewer disk round trips | `sudo systemctl disable --now zswap.service` and `echo 0 \| sudo tee /sys/module/zswap/parameters/enabled` |
| Stopped `pandapay-prod-maps-scraper-1`, restart policy set to `no` | removed from compose in `62f99ea7` (nearby uses Google Places / OSM directly) but the old container kept running with a headless Chrome since 19 Oct; 24 h of logs held only its own `/ready` health checks | `docker update --restart=unless-stopped pandapay-prod-maps-scraper-1 && docker start pandapay-prod-maps-scraper-1` |
| Stopped the PM2 `auth-service` (`/home/ubuntu/apps/pandapal-auth-service`), `pm2 save` | every request to `auth.pandapath.in` in the nginx log is a WordPress exploit scanner or a favicon; no app, API or website code references the host; old unpatched code facing the internet | `pm2 start auth-service && pm2 save` |

Swap in use fell from 1,036 MB to 893 MB at once.

Still the owner's decision:
1. **Move to a bigger VM.** The real fix. Oracle's free Ampere A1 shape allows up to 4 cores and 24 GB in a free
   account (ARM: images are built on the host, Node and Python images support arm64). Any paid shape with 2–4 GB also
   removes the swapping.
2. **Run the admin stack only while it is in use** (admin API, admin gateway, rule jobs: ~130 MB in RAM and ~180 MB
   swapped, the largest remaining software-side saving).
3. `auth.pandapath.in` now answers 502 from nginx; a `return 404` server block would be tidier.

### Admin gateway and SMS template worker (21 Nov, measured under Linux in `node:22-alpine`)

- **Template worker:** not big in itself. It starts at 75 MB, of which 49 MB is the Node program file (shared between
  processes from the same image) and ~16 MB is compiling the SMS contract schemas every SMS v2 service needs. Its log
  shows 47–58 MB at rest and a 110 MB peak during AI jobs; Node keeps garbage until its heap limit pushes it, which is
  why it once showed 140 MB in swap. Not loading the admin server it imports would save ~2 MB (its own modules already
  pull in the same libraries), so that was not changed. Nothing to fix without risking jobs.
- **Admin gateway:** parsed every admin API reply and serialised it again to forward it; the 14 MB catalogue peaked
  at 161 MB against 72 MB for a small request. It now streams the bytes (`auth/src/admin/server.js` `streamReply`):
  ~103 MB peak, no JSON heap growth, same bytes/status/content type/no-store to the console. Fixed on the way: deleting a
  rule-family row returned 503 through the gateway (an empty 204 crashed the old read loop) although the delete worked.
  Dev `96530804`.
- **Admin API `/admin/cards`:** builds the 14 MB reply from row objects. Having Postgres produce the JSON would save
  most of that, but dates and numbers would come out in a different format; not done (owner: no visible changes).

## 4d. What actually shipped (21 Nov ~03:30 IST)

The owner chose to deploy **all of dev** (`2dca6bec`, pushed to `prod` with `[deploy-tests:server]`): everything in
4c below, plus this session's build 197 app work (app only), Sujay's server work (6 migrations: durable SMS AI draft
jobs and lifecycle, entry-kind categories, AI excluded providers, requeue, `transactions.edited_at`; POST/PATCH
/transactions refuse a category that does not fit the kind; `/categories` returns `entryKinds`) and the deploy test
switch. Known visible effect, accepted by the owner: older app builds see the 33 new non-spend categories in their
pickers and get a 400 when saving a category that does not fit the entry's kind, until the next app build ships.

## 4c. One combined production deploy (owner's plan, 21 Nov)

Server-side commits waiting (all invisible to the app, the admin console and the SMS pages; no app build needed):

| Commit | What | Where it runs |
|---|---|---|
| prod `18d5bddd` | sync limit 480/h, wallet reads coalesced, 4 warm DB connections | API |
| prod `d0cb1241` | store-review login, legacy 4-digit (other session; `REVIEWER_OTP_*` already in host `.env`) | auth |
| dev `96530804` | admin gateway streams replies (14 MB catalogue peak 161 -> ~103 MB); fixes 503 on rule-family deletes | admin gateway (prod auth image) |
| dev `4b1cf6a0` | admin gateway gzips replies over 1 KB when the browser asks | admin gateway |
| dev `b13c04e5` | admin card list read 25 rows at a time through a cursor (peak about halved, same bytes) | admin API (prod API image) |
| dev `fe58992c` | admin health checks use wget, not a Node start every 30 s (~2% CPU each, all day) | admin compose |
| dev `6305cad2` | rewards worker: idle cycle is one transaction (12 -> 6 round trips every 5 s), idle log once a minute | rewards worker |
| dev `e65850c5` | `GET /points-ledgers?userCardIds=` answers every card's ledger in one request (per-card route kept) | API |

Steps:
1. Cherry-pick the five dev commits onto `prod` (on top of `d0cb1241`), run the API and auth suites, push `prod` once.
   The workflow deploys API, auth and workers.
2. Admin (images are the prod ones, so after step 1): on the host
   `cd /home/ubuntu/pandapay-secrets/admin-setup && ./admin_setup.sh gen-compose` (health checks changed), then
   `docker compose -p pandapay-admin -f compose.admin.yml --env-file ../admin.env --profile admin up -d --force-recreate --no-deps admin-api admin-gateway`.
   The admin containers have run 10-14-day-old code, so this brings every admin change since then, not only these.
3. Check: iPhone sync gives no 429; `/user-cards` timings; console card list opens and matches; deleting a rule-family
   row says success; `docker stats` for the admin containers at rest (~0% CPU) and after opening the card list.

### App-side items (21 Nov)

| Call | Today | Outcome |
|---|---|---|
| `GET /user-cards/:id/points-ledger` | one call per card (~10 at once) on every app open | **Done** (dev `4ac0e813` app, `e65850c5` API): calls arriving within 25 ms go out as one `GET /points-ledgers`; each card gets exactly its own list and the same errors; against a server without the route the app asks per card, as before. Ships with the next app build; the server route must be deployed first or the app simply keeps asking per card. |
| `GET /transactions?from=` / `from&to` | whole date range in one reply, up to 2 MB raw (~250 KB gzip) | **Not changed, on purpose.** A full list replaces what the phone holds (rows missing from it are removed locally; see `TransactionPage` and the provider at `providers.dart` ~6910). Pages are not one consistent snapshot, so a transaction edited while the pages are read could be missed and removed from the phone: that breaks "never lose a record". Compression already cut it ~8x. Doing it safely needs a snapshot-consistent paging protocol (e.g. a revision checked across pages). |
| `GET /catalogue` | whole 10.5 MB catalogue (1.3 MB gzip) | **Not changed, on purpose.** 19 parts of the app read the whole catalogue (Discover, Find cards, calculator, scan result, SMS runtime compare cards the person does not own). It is downloaded only when its version changes (ETag), and the server keeps one gzip copy per version. A per-card or delta catalogue would change those screens (loading states, missing comparisons). |

## 5. Not done here
- Deploying: all the server changes above need a production deploy (owner's go-ahead); the nginx changes are a separate, manual config change on the host.
- One app-open call (`GET /bootstrap`) instead of ~50: needs an app change and a server route; the biggest remaining win for app-open speed.
- Everything in sections 3 and 4 other than the sync and compression rows.
- The phone could ask for a smaller `limit` on a slow link; not needed now that the default is 250.
