# Shared expenses: worst-case SCALE and data-volume report

Branch `split-labels`. Product code was not touched. Everything below was produced by the suites
`db/tests/shared_expenses_worst_scale_*.test.js`, which call the real SQL functions and the real
`api/src/shared_expenses/queries.js` / `notifications.js` as `app_user` under RLS, on the real migrations.

## How to reproduce

```
docker run -d --name pp-scale-pg -p 127.0.0.1:55462:5432 -e POSTGRES_PASSWORD=scale -m 1536m postgres:16 \
  -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c shared_buffers=256MB -c work_mem=16MB -c track_functions=all
export PANDAPAY_WORST_SCALE_PG_URL=postgres://postgres:scale@127.0.0.1:55462/postgres
node --test db/tests/shared_expenses_worst_scale_<contexts|group|feed|fanout|people|limits|abuse>.test.js
```

Without `PANDAPAY_WORST_SCALE_PG_URL` every suite is skipped (suite stays green). Every number is printed as a `SCALE {json}` line.
Knobs: `PANDAPAY_WORST_SCALE_SIZES`, `_EXPENSES`, `_EVENTS`, `_INVITES`, `_GROUPS`, `_VICTIM`, `_NAMEONLY_GROUPS`, `_DIRECTS`, `_OUT`, `_KEEP_DB`.

## Honesty notes (read before trusting a number)

* **fsync=off, synchronous_commit=off, full_page_writes=off.** Commit/WAL cost is missing, so write latencies are optimistic
  (a real server adds roughly one WAL flush, about 1-5 ms on SSD). CPU, plan shape, buffer counts and row counts are real.
* One docker container (postgres 16, 1.5 GB RAM cap, shared_buffers 256 MB), loopback client, no network. A phone adds RTT on top of every figure.
  Server-side read timings are measured around the query only (BEGIN / SET ROLE / COMMIT excluded); command timings are one round trip including the transaction.
* Fixtures with exact amounts were seeded through the real commands (create / invite / accept / propose / approve). Exceptions, all stated where used:
  the 19,900-pair mesh, 100k-event stream, 100k invitation rows, 300k phone_reveals and 130 invitation rows were bulk-inserted by SQL
  (the 50 links/hour cap makes them unreachable through the API from one account). Mesh balances therefore do not equal a journal; only performance is claimed there.
* The notification inbox table is a stub with the same INSERT and dedupe index; the outbox/push provider is off. Everything before the insert is the real code.
* "Projected" values are linear extrapolations from a measured prefix and are marked as such.

## Budgets (and why)

| Budget | Value | Why |
| --- | --- | --- |
| List/read endpoint, server time, p95 | **< 300 ms** at 2000 contexts, page <= 100 rows | The screen should paint in about 1 s on 4G: roughly 300-500 ms of RTT/TLS, 200 ms of JSON parse and render, leaving 300 ms for the server. |
| Single command, p95 | **< 500 ms** at 200 members | A command is one user tap with an optimistic row; 500 ms plus RTT is still under the 1 s "feels instant" line. |
| Feed page, p95 | **< 300 ms regardless of stream size** | A page must cost O(page), not O(history); otherwise old users get slower every day. |
| Background work | no read path may scan a backlog | The purge backlog must not tax unrelated users. |

Timings are fsync-off, so a PASS with less than about 2x margin is a "watch" on real hardware.

## Results

### Z01: ONE USER, MANY SPLITS (70% direct, 30% group, about 2% declined and 1% invited rows, about 45% with an accepted expense)

All three sizes were seeded cumulatively for one user through the real commands; 100/500/2000 contexts = 98/490/1960 active + a few invited.
Counts, brute-force overview and list rows were asserted equal in every run.

| Metric (p50 / p95 ms) | 100 | 500 | 2000 | Budget |
| --- | --- | --- | --- | --- |
| `listContexts` first page (50) | 6.3 / 10.3 | 15.0 / 16.4 | **39.5 / 46.0** | PASS |
| `listContexts` limit 100 | 6.1 / 6.5 | 13.9 / 14.4 | 38.8 / 39.6 | PASS |
| `listContexts` kind=group | 3.6 / 4.2 | 6.7 / 6.9 | 22.6 / 23.7 | PASS |
| search by name/label, hit | 5.7 / 6.1 | 25.0 / 26.9 | **84.0 / 87.8** | PASS |
| search, no match | 5.3 / 5.8 | 21.6 / 23.9 | 78.7 / 80.8 | PASS |
| `readOverview` (owed/owing/net over all contexts) | 3.4 / 4.6 | 8.9 / 10.3 | 25.5 / 32.3 | PASS |
| personal activity (first page) | 4.6 / 5.9 | 4.7 / 5.5 | 4.7 / 5.2 | PASS |
| personal activity search "Trip" (10k events) | 38.7 / 45.0 (cold) | 10.7 / 11.2 | 10.5 / 11.1 | PASS |
| first projection-feed page (limit 100) | 12.0 / 14.6 | 7.7 / 8.9 | 6.6 / 7.2 | PASS |
| `list_my_invitations`, `list_join_requests`, `capabilities` | about 1 | about 0.6 | about 0.5 | PASS |
| full walk, limit 50 | 2 pages, 9 ms | 10 pages, 91 ms | **40 pages, 957 ms total, page p95 36.9** | PASS |
| response size | page of 100 = 34 KB JSON; full 1980 rows = 674 KB; node heap delta 0.9 MB | | | PASS |

* **Correctness: PASS.** Full walks returned every visible context exactly once, sorted. Overview owed/owing equals the brute-force SQL and the amounts derived from the seeded expenses (2000: owed 742,519, owing 599,035 minor units, 880 expenses). Per-row owed/owing/expenseCount equal the model.
* **Cursor stability under inserts: PASS.** 10 newer contexts created between page 1 and page 2: 1980 old rows returned once, none duplicated, new ones not injected mid-walk.
* **Sort ties: PASS.** 120 contexts with an identical `created_at` paginate in 43 pages without gaps, ordered `context_id DESC`.
* **Caps: PASS.** `limit` 101/0/-1/abc and cursors of 1025 chars or invalid base64 are refused (`INVALID_INPUT` / `INVALID_CURSOR`); `q=%` is a literal.
* **Shape of the cost (this is the scaling risk):** the list is O(all my contexts) for every page, including page 1. Plan (2000): Bitmap scan of 1980 `members` rows, 1980 index lookups into `contexts`, top-N heapsort of 51. In a fresh session one first-page call runs `_can_read_context` **5,862 times** (3 per context: the `members` and `contexts` RLS policies) and `_context_label` only 51 times (postponed past the sort); a name search runs `_context_label` 651 times and `_can_read_context` 4,331 times. Cost is linear in contexts: 6 / 15 / 40 ms at 100 / 500 / 2000, and 106 ms measured at 10,000 (Z07: overview 44 ms, search 440 ms p50 = FAIL for search only).
* **N+1:** none at the API layer (each endpoint is one SQL statement). The N+1 is inside the SQL: per-row `SECURITY DEFINER` RLS function calls (see B20/B24).
* **Missing indexes:** `contexts` has only its primary key; `contexts(created_by, kind)` is missing (used by `_friend_context`, see Z05). `pair_balances` has only its PK (adequate, `high_member_id` is reached through a bitmap OR on the PK). Everything else the list uses is indexed (`shared_members_profile`).

### Z02: ONE GROUP, MANY PEOPLE (200 counted members: 180 active + 20 pending join requests; and a separate 200-active group with 19,900 pairs)

| Metric | Measured | Budget |
| --- | --- | --- |
| invite_member latency at 10 / 50 / 100 / 150 / 179 members | 1.6 / 3.0 / 4.9 / 6.7 / 7.8 ms (linear, `_label_taken` is O(members)) | PASS |
| accept (`respond_membership`) at same sizes | 1.2 / 2.1 / 3.1 / 4.4 / 5.6 ms | PASS |
| `_emit` cost: author-only expense (1 propose + auto-accept = 1 event) at 2 / 10 / 50 / 100 / 200 active members | p50 2.6 / 2.7 / 3.4 / 4.8 / **7.7** ms (p95 10.0 at 200) | PASS |
| 50 sequential proposals at 200 members | p50 8.3, p95 8.9 ms, 118/s | PASS |
| 20 parallel proposals, 20 different members, same split (context lock) | p50 203, **p95 368**, max 386 ms, wall 202 ms for 20 (99/s) | PASS (p95 < 500) |
| 2-person propose, approve+accept, edit, edit approve, report settlement, confirm settlement, remove pending, leave at 200 members | 6.8, 8.6, 7.1, 8.6, 7.7, 9.8, 10.5, 6.1 ms | PASS |
| accept path with 19,900 pair rows: `sum(abs(balance_minor))` alone | p50 2.6 ms (Seq Scan, 310 buffers) | PASS |
| author-only accept on the mesh / 2-person approve / settlement report+confirm | p95 13.3 / 12.2 / 7.3+9.2 ms | PASS |
| 8 payers x 50 sharers expense (maximum shape) on the mesh: propose / each of 57 approvals | 11.4 ms / p95 13.3 ms; 56 obligation edges; accepted | PASS |
| write cost vs size (4000 more expenses at 2.7M stream rows): propose p50 | 6.9 ms, approve 8.8 ms (unchanged from empty) | PASS |
| roster page 100 (200 rows incl. 20 pending, 2 pages) | 6.8 ms at 5000 expenses | PASS |
| `readContextTotals`, `readOverview`, `listContexts` for a member | 1.6, 1.7, 2.3 ms | PASS |
| `readBalances` page of 100, 1889 / 7237 / **19,900** pairs | 10.0 / 33.9 / **93.3** ms (p95 97); whole walk 199 pages: p50 48, p95 90 | PASS now, **O(pairs in split)**, see B20 |
| `listContextExpenses` page of 100 (1000 / 5000 expenses) | 205 / 198 ms p50 (p95 209 / 201). Once 2043 ms at 1000 expenses when `ANALYZE` had not yet run (plan flip) | WATCH (about 2 ms per row, all RLS function calls) |
| **`listContextActivity` page of 100 (3.4k / 15.4k events)** | **454 ms / 2,229 ms** (deep page identical) | **FAIL** (B16, B17) |
| **first projection-feed page (grant snapshot), 1000 / 5000 expenses** | **248 / 1,200 ms** | **FAIL at 5000** |
| **initial sync of the split on a new device (projection feed from 0, limit 100)** | 1000 expenses / 3375 events: **408 pages, 62 s server time, 13.7 MB, p50 231 ms/page, finished**. 5000 expenses / 15,444 events: 90 s covered 3.3% of the stream (190 pages, 9.6 MB, p95 1.2 s/page); **projected 5,700 pages, about 45 min** (projection from the most expensive prefix, treat as an order of magnitude) | **FAIL** |

* **Join-request path:** 20 claims p50 8.2 ms; the 21st claim raises `join_requests_full` (409). 180 + 20 pending = 200 counted; at 200 counted a 21st request is moot (`context_member_limit` first).
* **Storage amplification (`_emit` writes one `profile_events` row per active member per event).** The 5000-expense split holds 15,453 context events and **2,749,499 `profile_events` rows = 682 MB** (about 248 bytes/row incl. two indexes; about **136 KB per accepted expense**, about 550 rows). Growth is O(members x events): a 200-member split with 50 accepted expenses/day adds about 7 MB/day (50 x 136 KB). `profile_stream_heads` stays small (all HOT updates, 0.7-1.1 MB at 180 rows; no bloat).
* **EXPLAIN (activity, 15.4k events):** `Sort Key: ((context_events.sequence)::text)` over an index scan that returned **8,453 rows** (303,289 buffer hits) because (a) the `ORDER BY sequence` binds to the text output alias (B16), and (b) the `context_events` RLS policy plans as `hashed SubPlan 2` = a Seq Scan of `expense_revisions` with `_can_read_revision()` called twice per revision, with no context restriction (B17). Replacing only the ORDER BY with a qualified name: 2,138 ms (no gain), so both causes matter.
* **EXPLAIN (balances, 7237 pairs):** `Sort (top-N) <- Seq Scan pair_balances Filter: context_id AND _can_read_context(context_id)`, 29,032 buffers. The generic `($2 IS NULL OR (low,high) > ($2,$3))` blocks the ordered index scan. Same query with an always-present keyset bound: **1.5 ms vs 34.3 ms** (23x).
* **EXPLAIN (expenses page):** nested loops with `Filter: _can_read_revision(...)` on every probe: 26,591 buffers for 101 rows.

### Z03: MANY EVENTS / FEED (100,000 profile_events for one profile in a 1-context stream)

| Metric | Measured | Verdict |
| --- | --- | --- |
| seed: 100k context_events + 100k profile_events | 27 MB + 26 MB (incl. indexes) | info |
| `/changes` (= `pullProjectionChanges`) first page, deep page (cursor at 98k) | 3.9 ms p50 / 6.7 ms p50 per page | PASS per page |
| **`/changes` catch-up of 100k events** | the feed reads **LIMIT 10 profile events per page** (hard-coded): **10,000 pages**, about 39 s of pure server time at 3.9 ms/page, plus 10,000 RTTs | **FAIL** (B23) |
| `listPersonalActivity` first page / `q` that matches | 4.0 ms / 6.0 ms | PASS |
| **`listPersonalActivity` with a `q` that matches nothing** | **4,877 ms p50 (4,953 p95)**; plan: Index Scan Backward over all 100,001 events x context_events lookup x `_context_label` | **FAIL** (B25) |
| legacy `listChanges` (not routed) full walk limit 100 | 919 pages, returned **91,850 of 100,001** (8,151 lost) | latent B16 (not exposed by routes.js) |
| hourly `purge_expired_claimant_phones()` with 50,000 due ciphertexts (100k invitation rows) | 30 ms per call, **1,000 rows per call**: 50 hours to drain; if the job runs hourly the privacy purge capacity is 24,000 numbers/day | WATCH (product decision) |
| `list_join_requests` / `list_invitations` by an unrelated owner with 50,000 foreign due rows | 7.3 / 7.5 ms (plan: Index Scan on `shared_invitations_phone_purge` returns 50,000 rows, 50,000 join-filter rejections, 8.9 ms) | PASS today, **linear in the backlog** (about 1 s at 5M rows) |
| lazy purge by the owner of the backlog | purges 50 rows per read (53 ms) | info |
| `phone_reveals` | 300,000 rows = 56 MB (199 bytes/row); no purge job found; budget check 20 ms p50 with 86k same-day rows (artificial: the real cap keeps it at 30/day) | WATCH (growth only) |
| `operation_receipts` | 928 real commands: avg row 466 bytes, **653 bytes/row incl. PK**; no TTL or purge function exists. Assumption-based sizing: 1k users x 10 commands/day = 6 MB/day; **100k users x 10 commands/day = 623 MB/day, 222 GB/year** | **WATCH/FAIL at scale** (product decision) |
| stream-head bloat | 43,154 updates, 43,153 HOT, 16 KB table, 101 dead tuples | PASS |
| backup coverage | the whole DB is dumped (`pg_dump` of the product database); the shared schema of this Z03 DB (100k events + 100k invitations + 300k reveals) = 166 MB on disk, **21.6 MB** `pg_dump -Fc -n shared_expenses` (about 7.7:1) | info |

* **B15 quantified** (profile feed paged with `limit` while the stream has more than 9 entries): limit 100 on streams of 12/60/150 events: 0 lost, 1-3 duplicates; limit 30 on 60 events: **2 lost** (sequences 9, 10), 8 duplicates; limit 5 on 150 events: **16 lost (10.7%)**, 2 duplicates, 109 pages. The app asks for limit 100, which is why the loss is hard to see: it appears when one page window straddles a digit boundary and the record count reaches the limit (large grant snapshots); no stuck cursor was observed (0 runaway walks).
* **B16 (new, same root cause as B15, in a route the app uses):** `/contexts/:id/activity` (`listContextActivity`) is `SELECT sequence::text ... ORDER BY sequence`. In a split with 43 events and limit 10 the first page is `1,10,11,12,...` and the full walk delivers **35 of 43 events** (8 lost); the legacy `listChanges` loses 8 of 42 the same way.

### Z04: PUSH / NOTIFICATION FAN-OUT (real `notifications.js`)

| Group size (active) | Required reviewers (20 sharers) | Rows created | Reviewers notified | Reviewers **dropped** | Non-reviewers pinged | Time |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | 9 | 9 | 9 | 0 | 0 | 34 ms |
| 50 | 20 | 49 | 20 | 0 | **29** | 133 ms |
| 100 | 20 | **50** | **0** | **20** | 50 | 144 ms |
| 200 | 20 | **50** | **0** | **20** | 50 | 143 ms |

* **D3 confirmed (B19).** `plan()` targets every other active member (199 in a 200-person split), `slice(0,50)` keeps an arbitrary 50 (the `loadAudience` query has no ORDER BY), and the required reviewers are not preferred: in a 100- or 200-person split with 20 required reviewers, **none** of the 20 gets a push and 50 uninvolved people do. The `LIMIT 200` in `loadAudience` cannot truncate today because the active cap is 200, but it also has no ORDER BY.
* Cost is bounded: 50 inbox transactions at about 2.9 ms each (sequential); not a DB problem. Replaying the same operation id creates 0 rows (dedupe `split:<op>:<profile>` works).
* One user in 2000 splits: one inbox row per (operation, recipient), no collapsing and no per-user cap. 2000 rows: insert p50 1.9 ms, 627 bytes/row, count 2.1 ms. A busy day (1 expense per split) = 2000 notifications for that user.

### Z05: SAME PEOPLE ACROSS MANY SPLITS

* One friend X in 50 groups + 1 direct split with the same person (alternating payer): **51 independent pair balances, all correct.** The overview (per-context, gross) says owed 17,000 / owing 5,100 while the per-person net with X is 11,900: **net equals the overview net (11,900), but gross is inflated by 5,100 vs a per-person netting.** There is no per-person aggregate endpoint; if the product wants "X owes you Rs 119" it needs one (product decision).
* Duplicate labels: the same label in 50 groups is fine (unique per split). A second direct split with the same creator named `xavier` or `Xävier` is refused: `friend_name_taken` (409) both times.
* **`_friend_context` / `_label_taken` cost (O(n) per add).** `_friend_context` filters `contexts` by `created_by` with a Seq Scan (no index) and then calls `_context_label` per matching row. Measured: a creator with 100 / 500 / 1000 / 2000 / 3000 direct splits pays **5.8 / 27.8 / 53 / 106 / 166 ms p50** per `create_context(direct)` (about 56 ms per 1000 owned splits), and `invite_member` pays it again. `_label_taken` is O(members of that split) (7.8 ms at 179 members), negligible.
* **Per-creator advisory lock** (`friends:<creator>`): at 1000 existing direct splits one device adds a friend in 53 ms; **5 devices x 10 parallel creates = 50 creates in 3.18 s (15.7/s), p50 274 ms, p95 388 ms** (a queue behind the lock; each holder spends the O(n) scan). Same-name race from 5 devices: exactly 1 created, 4 `friend_name_taken`, 1 row. 5 parallel `invite_member` of one name into 5 empty directs: exactly 1 succeeds. PASS (< 500 ms) but at 3000 owned splits the queue p95 would be about 3x.

### Z06: LIMITS AND HARD CAPS AT THE BOUNDARY (DB code -> HTTP status -> does the app have plain text?)

| Boundary | Result | HTTP | App text |
| --- | --- | --- | --- |
| 200th member (invite) / 201st | ok / `context_member_limit` | 400 | "This split is full." |
| link claim at 200 | `context_member_limit` | 400 | "This split is full." |
| 20th pending join request / 21st | ok / `join_requests_full` | 409 | "This group has too many waiting requests..." |
| 10th link claim in an hour / 11th | ok / `invitation_rate_limited` | 429 | "Too many tries for now..." |
| 50th invitation link in an hour / 51st | ok / `invitation_rate_limited` | 429 | same |
| 25th phone lookup in a day / 26th | ok / `lookup_rate_limited` | 429 | same |
| 8 payers / 9 payers | ok / `invalid_snapshot` | 400 | none in the DB-error map; the composer blocks it first ("Choose between 1 and 8 current payers.") |
| 50 sharers / 51 | ok / `invalid_snapshot` | 400 | composer blocks it ("Choose between 1 and 50 current members") |
| title 200 / 201 | ok / `invalid_proposal` | 400 | none (client-side only) |
| total 1,000,000,000 / +1 | ok / `invalid_snapshot` | 400 | none |
| group name 120 / 121 chars | ok / `invalid_context` | 400 | none |
| direct name 40 / 41 | ok / **silently truncated to 40**, then `friend_name_taken` against the 40-char sibling | 409 | misleading text ("You already have a friend with that name") |
| member label 40 / 41 | ok / **silently truncated**, then `member_name_taken` | 409 | misleading text |
| `limit` 101, 0, -1, abc; cursor > 1024 chars or invalid | `INVALID_INPUT` / `INVALID_CURSOR` | 400 | internal |

* **B18 (S2): the 200-member cap is evaluated with three different rules.** Invites and link claims count `state<>'declined'`; `submit_proposal` counts **every** `members` row (declined, left, erased). A split with 190 live members plus 15 removed/declined name-only rows (205 rows) refuses every new expense with `context_member_limit` ("This split is full.") although only 190 people are in it. An owner can do this to their own split with an unlimited invite/remove loop (260 cycles took 2.2 ms each; 263 rows with 3 live members; the next expense is refused). The roster also grows with these rows (they are listed).
* **B22 (S2, new): `list_invitations` pagination.** It orders by `created_at DESC` but pages with `invitation_id > cursor`. With 130 invitation rows on one split, a walk of 2 pages returned **67 items, 61 distinct: 69 invitations never shown, 6 repeated**.
* Left members (read from the SQL, not run): invites and claims count `state<>'declined'`, so only `declined` frees a slot; a group of 200 where 5 people left cannot add anyone. The decline path was run (`Z06.1`: after one decline the replacement invite succeeds).

### Z07: ABUSE VOLUME (one hostile account, 13,000 contexts, 99,000 name-only members)

| Abuse | Cost | Cap today |
| --- | --- | --- |
| 10,000 groups created in one run | **20 s total, 0.9-1.0 ms each, flat** (no per-user/day cap; 500 groups/s) | **none** (A confirmed; B26) |
| the hostile user's own reads at 10,000 contexts | list first page 106 ms (p95 108), overview 44 ms, full walk 100 pages (p95 104 ms), **search 440 ms p50 (FAIL)** | n/a |
| 3,000 direct splits | create latency 5.8 -> **166 ms** (see Z05); 100 -> 3000 owned splits | none |
| ~99,000 name-only members (500 groups x 198 invited names, no accept) | 269 s; per-invite p50 at member position 1 / 50 / 100 / 150 / 197: 1.3 / 2.0 / 2.7 / 3.4 / 4.1 ms; **195 bytes/member row incl. indexes (21 MB)** | none (`invite_member` has no rate limit; the 50/hour cap applies only to link invitations) |
| spam-inviting one victim (by profile id) into 2,000 groups | 1.3 ms per invite; the victim gets 2,000 `invited` memberships and a 2,000-event stream; victim list 35.6 ms, overview 0.9 ms, changes 1.2 ms, projection 4.6 ms; each decline 1 ms but is one tap per invite; no block/mute | **none** (no relationship, consent or rate limit for an invite to a registered profile) |
| global `lookup_phone` with 3,001 direct splits in the DB | 1.6 ms; plan = Index Scan on `shared_members_profile` + PK probes, not a global scan | PASS |
| storage after the run (13,021 contexts, 114,142 members, 114,163 events) | contexts 2 MB, members 21 MB, context_events 35 MB, profile_events 26 MB, **operation_receipts 45 MB** (about 0.4 KB per command), DB 141 MB | n/a |

## Verdict table

| ID | Scenario | Budget | Result |
| --- | --- | --- | --- |
| Z01 | 2000 contexts: list/search/overview/activity/invitations/join requests | p95 < 300 ms | **PASS** (46 / 88 / 32 ms) |
| Z01 | pagination correctness, cursor stability, ties, caps, overview vs brute force | exact | **PASS** |
| Z01 | 10,000 contexts search | < 300 ms | **FAIL** (440 ms), list 106 ms PASS |
| Z02 | commands at 200 members (propose, approve, edit, settle, remove, leave), 50 sequential, 20 parallel | p95 < 500 ms | **PASS** (max p95 13 ms; parallel p95 368 ms) |
| Z02 | accept path with 19,900 pairs | < 500 ms | **PASS** (13 ms) |
| Z02 | roster / balances / expenses page | < 300 ms | PASS / PASS (93 ms at 19.9k pairs, linear) / WATCH (about 200 ms) |
| Z02 | group activity page at 15k events | < 300 ms | **FAIL** (2.2 s) |
| Z02 | first projection page at 5000 expenses | < 300 ms | **FAIL** (1.2 s) |
| Z02 | new-device initial sync of a 1000-expense split | n/a | 408 pages, 62 s, 13.7 MB (**FAIL** for 5000: about 45 min projected) |
| Z03 | feed page cost with 100k events | < 300 ms | **PASS per page** (4-7 ms), **FAIL end to end** (10,000 pages) |
| Z03 | personal activity search with no match, 100k events | < 1 s | **FAIL** (4.9 s) |
| Z03 | B15 (projection feed ordering) | 0 lost | **FAIL** at small limits (2/60 and 16/150 lost); 0 lost at limit 100 in this data |
| Z03 | purge, backlog | no read scans backlog | PASS today (7 ms at 50k); purge capacity 1000/hour WATCH |
| Z03 | receipts / reveals growth | n/a | no TTL, 653 B/command: needs a retention decision |
| Z04 | reviewers notified in a 100-200 person split | 20/20 | **FAIL** (0/20; 50 bystanders pinged) |
| Z05 | cost of adding a friend (creator with n direct splits) | < 500 ms | PASS to about 3000 splits (166 ms), O(n), fixable to O(1) |
| Z05 | 5-device parallel adds | p95 < 500 ms | PASS at 1000 splits (388 ms) |
| Z06 | caps return plain-language errors | user-explainable | PASS for 200 / 20 / 10 / 50 / 25; **FAIL** for silent 40-char truncation and for the row-count cap (B18) |
| Z07 | per-owner caps on groups / invites to strangers / names | a cap exists | **FAIL** (none) |

## New defects (continuing the B-numbering of `worst-case-concurrency-report.md`)

| Bug | Sev | What | Minimal repro | Test |
| --- | --- | --- | --- | --- |
| B16 | S1 | `listContextActivity` (`GET /contexts/:id/activity`) and legacy `listChanges` `ORDER BY sequence` binds to the text output alias: wrong order, events skipped and repeated across pages, full sort per page | split with 43 events, `limit=10`: first page `1,10,11,...`, walk delivers 35 of 43 | `Z03.5b` (todo) |
| B17 | S2 | `context_events` read policy plans as a hashed SubPlan over **all** `expense_revisions` (`_can_read_revision` x2 per row, no context restriction in the plan; in this single-split DB all 5000 revisions belong to the split, so the DB-wide multiplier is read from the plan, not measured with other tenants); activity cost is O(revisions) not O(page): 454 ms at 3.4k events, 2.2 s at 15k | `EXPLAIN` of the activity query on a 5000-expense split | `Z02.A desired: group activity page` (todo) |
| B18 | S2 | `submit_proposal` counts all member rows (incl. declined/left/erased) against 200; invites count non-declined; owner can brick a split by invite+remove churn; no churn cap | 190 live + 15 removed names: expense refused `context_member_limit` | `Z06.1b` (todo), `Z06.1c` |
| B19 | S2 | Push fan-out `slice(0,50)` of an unordered audience, no reviewer targeting (D3): 0 of 20 reviewers notified at 100/200 members, 50 bystanders pinged | `notifyAfterCommit` in a 200-member split | `Z04.1b` (todo) |
| B20 | S3 | `readBalances` (`$2 IS NULL OR (low,high)>($2,$3)`) defeats the ordered index scan: O(pairs in split) + RLS function per row: 93 ms at 19.9k pairs vs 1.5 ms with a plain keyset bound | `EXPLAIN` Seq Scan + top-N sort | measured in `Z02.A_plans.timings` |
| B21 | S3 | `_friend_context` is O(direct splits owned): 166 ms at 3000, doubled by `invite_member`, serialized per creator by an advisory lock | `create_context(direct)` after 3000 | `Z07.4`, `Z05.2` |
| B22 | S2 | `list_invitations` order/cursor mismatch: 130 rows -> 67 returned, 69 never shown, 6 repeated | `Z06.7` | `Z06.7b` (todo) |
| B23 | S2 | Projection feed reads a fixed 10 events per page: catching up a long stream needs events/10 round trips; full-grant snapshot page costs 1.2 s at 5000 expenses | `Z03.1`, `Z02.A_at_5000.initial_sync` | `Z02.A desired: first projection-feed page` (todo) |
| B24 | S3 | RLS policies call `SECURITY DEFINER` functions per scanned row (members: `_can_read_context(...) OR profile_id=uid`, function first): 5,862 calls for one 50-row page at 2000 contexts, 303k buffer hits per activity page | `pg_stat_user_functions` after one call | `Z01.2000` JSON `fn_calls_first50` |
| B25 | S2 | `listPersonalActivity` with a non-matching `q` scans the entire profile stream x `_context_label`: 4.9 s at 100k events | `Z03.1` | assertion in `Z03.1` (< 1 s) |
| B26 | S3 | No per-user / per-day cap on `create_context`; no rate limit or consent on `invite_member(profileId)` (strangers' lists can be flooded) | `Z07.1`, `Z07.2` | `Z07.1b`, `Z07.2b` (todo) |
| B27 | S3 | Direct names and member labels are silently truncated to 40 chars before the uniqueness check, so two different long names collide with a misleading message | `Z06.3` | `Z06.3b` (todo) |

## Top bottlenecks, evidence and concrete fixes

1. **Per-row RLS function calls (B17, B24, B20, expenses page).** Plans show `Filter: shared_expenses._can_read_context(context_id)` on every scanned row, `_can_read_revision` twice per revision row, and a hashed SubPlan over the whole revisions table. Fix (untested, designed from the plans): (a) put the cheap `profile_id = pandapay.uid()` branch first in `shared_members_read`; (b) rewrite `shared_context_event_read` as `kind <> 'expense.proposed' OR shared_expenses._can_read_event(context_id, origin_id)` (one correlated call only for proposal rows) instead of an `EXISTS` the planner hashes; (c) replace `_can_read_context(context_id)` in the table policies by an inlinable `EXISTS (SELECT 1 FROM members m WHERE m.context_id = t.context_id AND m.profile_id = (SELECT pandapay.uid()) AND m.state='active')` plus the settings flag read once as an InitPlan, or serve the heavy lists (activity, expenses, balances) from `SECURITY DEFINER` read functions that authorize once per call, as `list_invitations` already does.
2. **Text-alias ORDER BY (B15, B16).** Order by the qualified column (`ORDER BY context_events.sequence`, `ORDER BY pe.sequence`), keep the cast only in the select list. Add the E02/E05/Z03.5b todo tests as regression tests (they turn green by themselves).
3. **Keyset predicates with `IS NULL OR` (B20).** Use `(low_member_id, high_member_id) > ($2::uuid, $3::uuid)` with a zero-UUID sentinel for the first page: 34 ms -> 1.5 ms at 7237 pairs measured.
4. **Friend-name uniqueness (B21).** Store `label_key` on a `direct_friend_names(creator, label_key, context_id)` table (or a generated column on `members`) with `UNIQUE (creator, label_key)` and drop the `_friend_context` scan; add `CREATE INDEX contexts_created_by ON shared_expenses.contexts (created_by, kind) WHERE state = 'active'`. This also removes the advisory-lock serialization (the unique index is the lock).
5. **Fan-out storage (profile_events).** 136 KB per accepted expense in a 200-person split (682 MB for 5000 expenses). Options: write per-profile rows only for people the event concerns (participants/reviewers) and let others pull the context log by context sequence; or keep the stream but store `(context_id, context_sequence, member range)` per profile *epoch* rather than one row per event per member. Needs a product decision on what a non-participant sees.
6. **Projection feed (B23).** Make the 10-event window a parameter or at least adaptive (e.g. all events whose records fit one page), and give a new device a snapshot endpoint (current state of the split: members, heads, balances, last N activity) instead of replaying events, so first sync is O(state), not O(history): 408 pages and 62 s for 1000 expenses today.
7. **Personal activity search (B25).** Search by context name first (the set of the user's contexts is small), then `JOIN LATERAL` the newest N events of matching contexts; or drop the event-kind match from the filter.
8. **`operation_receipts` retention.** Add a daily purge (for example `created_at < now() - interval '30 days'` for finished receipts) or a partition by month; clients retry within minutes, not months.
9. **Purge job capacity.** `purge_expired_claimant_phones()` removes 1,000 per call; loop until fewer than 1,000 were removed (30 ms per call).

## Limits that need a product decision

* **Cap on splits per user and per day, and a rate limit on inviting registered profiles** (Z07: 10,000 groups in 20 s; 2,000 invites to one victim in 2.6 s; the victim cannot block). Suggested starting points to discuss: 200 active owned splits, 20 new splits/day, 30 profile invites/hour, a "block this person" action.
* **What the 200-member cap counts** (B18): live members only (`active` + `invited`), with left/declined rows excluded from every check, or a hard cap on total rows ever (and an invite/remove churn limit).
* **Does a left member free a slot** (today only `declined` does).
* **Reviewer-targeted notifications** (B19): notify required reviewers first, then optionally everyone else, max 50.
* **Per-person aggregate balance** across splits (Z05): the overview shows per-context gross.
* **Retention** of `operation_receipts`, `phone_reveals`, activity events (Z03/Z07): 653 bytes per command and 248 bytes per profile event row are kept forever.
* **Direct name length**: refuse over 40 characters instead of cutting (B27), or raise the limit.
* **Projection feed contract**: ask for a snapshot endpoint vs event replay for new devices (B23).

## Files

* `db/tests/shared_expenses_worst_scale_common.test.js` (helpers), `..._contexts` (Z01, Z05 scan), `..._group` (Z02), `..._feed` (Z03), `..._fanout` (Z04), `..._people` (Z05), `..._limits` (Z06), `..._abuse` (Z07).
* `{ todo }` tests: `Z02.A desired: group activity page`, `Z02.A desired: first projection-feed page`, `Z03.2b`, `Z03.5b`, `Z04.1b`, `Z06.1b`, `Z06.3b`, `Z06.7b`, `Z07.1b`, `Z07.2b`.
