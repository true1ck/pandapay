# Lane P: performance and cross-device

Branch `sms-v2/lane-p-performance`, based on `sms-v2/claude-lanes` (1baab86). Local only; nothing pushed or deployed. No Gmail code touched.

## What was added

| File | Purpose |
| --- | --- |
| `app/test/features/sms_v2/support/synthetic_corpus.dart` | Deterministic synthetic history. Bodies come from the 15 golden scenarios (40%), the 115 golden case messages (30%) and the bundle's own rule examples (30%), then amounts, card digits, reference numbers and dates vary over 730 days. Every body is distinct. No private data. |
| `app/test/features/sms_v2/pipeline/history_stage_benchmark_test.dart` | The 20,000-message benchmark (skipped by default) and a live-message latency test (always runs, 1,500-message store). |
| `app/test/features/sms_v2/support/sync_harness.dart` | Two-phone harness: independent SQLite stores, a synthetic server log cut into sync pages, a canonical state digest. |
| `app/test/features/sms_v2/sync/cross_device_projection_test.dart` | Cross-device convergence and a propagated user correction. |
| `app/test/features/sms_v2/pipeline/idempotency_test.dart` | Replay twice changes nothing. |
| `app/test/features/sms_v2/pipeline/rule_prefilter_test.dart`, `perf_regressions_test.dart`, `packages/pandapay_domain/test/sms_v2/engine/required_literals_test.dart` | Regression tests for the three performance fixes. |

Run the benchmark on demand (about 1.5 minutes of test time plus compile):

```
cd app && flutter test --no-pub --concurrency=1 --dart-define=SMS_V2_BENCHMARK=true \
  [--dart-define=SMS_V2_BENCHMARK_COUNT=20000] test/features/sms_v2/pipeline/history_stage_benchmark_test.dart
```

It writes the report to `$TMPDIR/sms_v2_lane_p_benchmark.txt`. It drives the real `SmsV2Runtime.capture` (intake gate, rule engine, instruments, linker, ledger projection, display rows, outbox, traces) over a file-backed SQLite database, in slices of 200 messages (the runtime's own chunk size; the pipeline limit is 500).

## Measured numbers (desktop, 20,000 messages)

Machine: Apple desktop running the Flutter test VM (JIT), **load average about 11** because other lanes were running; treat all timings as roughly plus or minus 25%.

| Run | Total wall | Notes |
| --- | --- | --- |
| Existing single-template benchmark (`history_benchmark_test.dart`), before fixes | over 120 s (failed its own 2-minute assertion) | Matches WP-14's 103 s |
| Lane P corpus, before fixes | 123.6 s and 85.6 s (two runs) | Chunk time grew 1.9x to 2.1x from first to last 10 chunks: quadratic |
| Lane P corpus, after fixes (final) | **42.6 s and 43.5 s** | Chunk median 434 ms, p95 523 ms, max 755 ms; last-10 over first-10 ratio 1.26 to 1.38 |

Stage breakdown. "Isolated" stages run the same corpus in memory with the real components; the residual is the rest of the full run.

| Stage | Isolated, after fixes | Share of 43 s |
| --- | --- | --- |
| Capture: triage, safety gate, source keys (18,693 candidates) | 6.4 s | 15% |
| Interpret (rule engine, 809 rules) | 13.0 s | 30% |
| Instrument resolution | 0.05 s | 0% |
| Linker (with in-memory context assembly) | 0.6 s | 1% |
| Ledger and category projection | 0.6 s | 1% |
| SQLite writes, per-chunk context reads, trace and decision rows, glue (residual) | 22.8 s | 52% |

The residual in the instrumented 20,000 run (52.5 s, temporary timers, since removed): context reads (`contextSince`) 3.6 s, instrument resolution plus fact inserts 4.2 s, `categoryDecisions()` full ledger read 1.9 s, ledger snapshot 2.4 s, projection writer 2.2 s, trace/decision/outbox writes about 5 s, capture triage about 6 s, rule engine 14.9 s.

Other measurements from the final run:

- Memory: process RSS 197.5 MB before the import, sampled peak 295.1 MB, `ProcessInfo.maxRss` 311.5 MB. The pipeline's own growth is about 98 MB; the rest is the Flutter test harness baseline (about 200 MB), which is not comparable to a phone process.
- Database size: 154.5 MB for 20,000 messages (about 7.7 KB per message). Largest: `v2_outbox` 39.1 MB, `v2_facts` 31.0 MB, `v2_sync_state` 16.2 MB (one trace row per message), `financial_entities` 14.1 MB, `v2_ledger` 7.6 MB, `v2_events` 5.7 MB.
- Rows: 24,570 facts, 11,464 events, 10,768 ledger entries, 39,772 queued uploads, 2,730 review items, 261 instruments. Decisions: 17,284 matched, 1,244 ignored, 1,318 unknown.
- Chunks: 100 runtime slices of 200. The pipeline limit stays 500 per local transaction.
- Live message (one new card purchase captured on the 20,000-message store, then totals read from the ledger): capture 145 ms plus a 315 ms full-ledger totals read, 472 ms in total on this desktop. On the 1,500-message store the same path takes about 15 ms capture plus 25 ms read. The totals read here is the conservative ledger-snapshot path; it scales with the store, so it is the part to watch on a phone. The first read after a restart also runs the legacy one-time `repairAutoPayArtifacts` (about 550 ms for 1,500 captured messages in a fresh database, a test artifact of an empty first run); the benchmark performs it before timing.

## Budget status

| Budget | Result |
| --- | --- |
| Engine, 10,000 messages vs 1,000 rules under 2 s | Existing domain gate still passes (0.7 to 0.8 s typical, 2.0 s when the machine was loaded). |
| History import 20,000 messages under 2 min on a mid-range Android phone, under 300 MB | **Not proven.** Desktop is 43 s, down from 86 to 124 s, but that is above the 30 s guidance and a phone is slower. See the assumption below. Memory delta of about 98 MB is comfortably inside 300 MB, but the absolute phone figure needs a device run. |
| Live message visible in totals within 1 s | Met on the desktop at 20,000 messages (472 ms); likely met on a phone for the capture part, but the ledger totals read (315 ms here) is the risk. |

Ratio assumption (stated, not measured): a mid-range Android phone running AOT-compiled Dart is typically 3x to 5x slower than a desktop core for this kind of CPU-bound code, while this desktop run is JIT, which costs roughly 1.5x to 2x versus AOT. Net projection 43 s x (3 to 5) / (1.5 to 2) = roughly 65 to 145 s. That straddles the 120 s budget, so a physical device run is still required (as WP-14 already lists). The remaining desktop cost is dominated by linear CPU work: triage 6.4 s and the rule engine 13 s.

## Fixes made (each proven by the benchmark, each with a regression test)

1. **Quadratic display write** (`app/lib/data/local/financial_store.dart`, `saveTransactions`). The per-row `DELETE ... WHERE namespace=? AND entity='transactions' AND source_key=? AND pending=1` let SQLite pick the primary key prefix and walk every transaction of the account for each saved row. Pinned with `INDEXED BY financial_source_identity`. Instrumented cost at 20,000: 22 s inside `ProjectionWriter.write`; after the fix 0.08 s. The chunk time ratio fell from 2.1x to about 1.3x. Test: `perf_regressions_test.dart` (a confirmed row removes only its own provisional copy).
2. **Quadratic template-review resolve** (`app/lib/features/sms_v2/pipeline/sms_v2_pipeline.dart`). Every non-unknown message ran `UPDATE v2_review_items ... json_extract(payload,'$.sourceKey')=?`, a scan of all review rows. The pipeline now reads the open template sources once per chunk and only updates when the message has one. Same result, one read per chunk (about 1.1 s at 10,000, growing quadratically). Test: a matched message resolves only its own open template review.
3. **Rule engine regex prefilter** (`packages/pandapay_domain/lib/src/sms_v2/engine/compiled_bundle.dart`, `rule_engine.dart`). The engine tried 214 regexes per message on average (about 5.8 microseconds each). `CompiledRule` now derives up to three lowercase literal runs that every match must contain, and the engine runs that substring check before the regex (the same check order change moves `requireAll` and `rejectAny` ahead of the regex, which is equivalent because all conditions must hold). The extractor is deliberately conservative: it gives up on top-level alternation and unreadable escapes, drops a literal followed by `?`, `*` or `{`, and skips groups and classes. Rule interpretation fell from 26.4 s to 13.0 s at 20,000. Tests: extractor unit tests, a soundness test over the whole real bundle (a regex match always implies its literals are present, over every rule example plus 400 sampled bodies per rule), and a brute-force equivalence test that the winning rule for 1,500 varied messages is identical to a scan without the prefilter.

## Proposed, not done (outside the smallest-change rule)

- Hoist the per-call `RegExp(...)` constructions in `classifySmsTriage` (`app/lib/features/sms_import/sms_text_hint.dart`, about 40 inline patterns) and `SmsGateFilter.evaluate` to `static final`. Triage costs 6.4 s of the 43 s. The file is shared with the legacy pipeline, so I left it.
- `SmsV2Pipeline._project` reads `_ledger.categoryDecisions()` (every ledger payload) on every chunk to find user-locked categories: 1.9 s at 20,000 and growing with the ledger. A SQL filter on the stored decision source would remove it; `ledger_store.dart` belongs to another lane.
- `EventStore.contextSince` (3.6 s) and the per-chunk instrument and fact reads are fine now but are the next linear costs. Consider widening the history chunk from 200 to 500 once memory on a device is known (fewer per-chunk context loads).
- Storage: 7.7 KB per message. The per-message decision trace (`v2_sync_state`, 16 MB) and the outbox (39 MB) are the largest rewritable pieces if device storage matters.
- `SyncPull._rebuildDisplay` re-reads every event and ledger entry on every pulled page. It was not benchmarked here; with a first sync of many pages on a new device it is worth measuring.

## Cross-device projection

`cross_device_projection_test.dart`. An uploader phone captures the 15 golden scenarios plus 250 varied synthetic messages through the real pipeline (more than 150 events, refunds, several categories). Its outbox is cut into 20-record pages by a synthetic server log with per-record update clocks. An Android and an iPhone store (separate in-memory SQLite databases) receive those pages: the Android in order, the iPhone shuffled with about half the pages repeated; a third store gets another shuffle. The digest compares events, ledger entries, category decisions, display rows, facts, instruments, totals (spend, refund, income, investment, count, spend by category) and derived review prompts (low-confidence events, detected instruments, unresolved card-bill targets). All three stores are identical, and equal the uploader's events, ledger and totals.

Correction: on the Android phone a refunded purchase and an unrefunded purchase are re-categorised with `CorrectionsService` (user source). Upload goes through the server log; the Android receives its own echo and the iPhone receives the update shuffled with duplicates. Both phones end identical, with the user category on both purchases, the refund following its purchase, the same total spend and refund, and a different category split.

Scope note: the persisted `v2_review_items` table is per device by design (it holds local message keys and template reviews), so "review items" in the comparison means the prompts derivable from synced state.

## Idempotency

`idempotency_test.dart`. Capturing the same messages again through a fresh pipeline changes no row in facts, instruments (and their evidence counts), events, ledger, outbox, review items, display rows, source decisions, rule stats or trace state; an earned reward and a note placed on a display row survive. The same holds for `SmsV2Runtime.capture` repeated twice and once in reverse order, and for receiving the same sync pages (and a shuffled duplicate set) again: only the pull cursor moves, and nothing is queued for upload.

## Finding for the linker owner

Processing one history as a single batch versus one message at a time gives the same result for every non-IPO event type and the same spend, income and refund totals, but IPO applications differ: in one batch two applications end `ambiguous` (and three `awaiting_leg`), one at a time they link (8 complete, 1 awaiting). It happens when blocks and releases of several different IPO applications arrive together. It is conservative (review instead of a wrong link) and not a replay problem, but it means a history import and live capture can show different IPO review prompts. The test `one batch and one-at-a-time agree on every non-IPO event` pins the rest.

## Verification

- `cd packages/pandapay_domain && dart test`: 1,034 passed.
- `cd app && flutter test --no-pub --concurrency=1 test/features/sms_v2`: 269 passed, 3 skipped (benchmark and local rig).
- Same with `--dart-define=SMS_PIPELINE_V2=true`: 269 passed, 3 skipped.
- Legacy store tests touching `saveTransactions` (financial store, amount evidence, local-first, transaction page, delta, sync status, amount repair): 112 passed.
