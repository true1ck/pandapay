# Gemini SMS pipeline test matrix

Scope: verify the 1% `sms_ai_queue_enabled` pilot without sending real SMS
content or writing synthetic queue jobs. Live provider connectivity checks use
only fabricated prompts and do not touch user data.

| ID | Scenario | Expected result | Check |
|---|---|---|---|
| G01 | Queue flag absent, disabled, zero rollout, and 1% deterministic cohort | Fail closed unless enabled and profile hashes into the cohort | `sms_observation_migration.test.js`, `gemini_queue.test.js` |
| G02 | SMS family master switch off | AI queue remains off regardless of its own flag | `sms_observation_migration.test.js` |
| G03 | OTP, credentials, marketing, malformed, or non-financial SMS | Refused before queue, quota, or body persistence | `gemini_queue.test.js` |
| G04 | Eligible financial SMS with long IDs, URL, address, and reference | Only redacted body reaches queued payload/provider prompt | `gemini_queue.test.js`, `gemini_worker.test.js` |
| G05 | Invalid source key, sender, empty/oversize body | Rejected at HTTP boundary; no queue write | `gemini_queue.test.js` |
| G06 | Duplicate/concurrent acceptance of one source | One job and one quota increment; replay is idempotent | `gemini_queue.test.js` |
| G07 | Daily quota exhausted | Fresh job refused; existing replay remains reusable | `gemini_queue.test.js` |
| G08 | Wrong/missing worker token; worker route disabled | 401/503; no lease or provider call | `gemini_queue.test.js` |
| G09 | Empty queue and expired/reclaimed lease | No-op for empty queue; one durable job is re-leased, stale token cannot land/retry | `gemini_queue.test.js`, `gemini_worker.test.js` |
| G10 | Provider capacity allowed/waiting/permanently blocked/database unavailable | Wait and heartbeat safely; no provider call before permit; bounded unavailable response | `ai_provider_quota_route.test.js`, `gemini_worker.test.js` |
| G11 | Gemini success, 429/quota, timeout, 5xx, non-retryable 4xx | Correct complete/retry/fail route; same job identity, bounded backoff | `gemini_worker.test.js` |
| G12 | Invalid JSON/schema, missing/duplicate/unknown batch item | Invalid output fails closed; valid batch items cannot cross-contaminate | `gemini_worker.test.js` |
| G13 | Model invents amount, account suffix, reference, or event state | Evidence/contract validation rejects it before fact writes | `ai_fact_evidence.test.js`, `gemini_queue.test.js` |
| G14 | Device fact or user override conflicts with AI result | Existing/device/user-corrected fact wins; no duplicate projection | `gemini_queue.test.js`, `sms_facts_route.test.js` |
| G15 | Successful and terminal-failure retention | AI job payload is purged; no duplicate raw SMS in server review; redacted event only | `gemini_queue.test.js` |
| G16 | Roll back feature flag while preserving existing user data | New AI submissions stop; legacy local parsing/review and saved corrections remain available | flag unit tests + local/route regression suite |
| G17 | Production secret/worker readiness and runtime activity | Worker healthy; pilot state and aggregate jobs/provider/results/retries observable without payloads or secrets | deployment + pilot workflow run |
| G18 | Live provider key/model, outbound path, and response contract | Model metadata and a synthetic generation pass; returned facts satisfy contract and evidence checks | opt-in production provider probe |

## Execution notes

- Unit/integration tests use fake clients and synthetic fixture messages only.
- No live customer message is replayed. Live Gemini probes use only fabricated
  text and never create a production queue job or fact.
- A live provider call can only be proven after an eligible job from a profile
  in the deterministic 1% cohort is accepted. Production counters report zero
  jobs, so runtime queue error-rate conclusions remain limited.
- Test and deployment run IDs/results are recorded in the task summary; do not
  put keys, SMS bodies, tokens, or user identifiers in this document.

## Earlier session results (2026-10-24)

These results describe the earlier session's checkout and production observations,
not a new production check. The subsequent local review below supersedes the
local test failures recorded here.

- Focused backend SMS/Gemini suite: **85 passed**. Includes 1% deterministic
  cohort selection, excluded-profile rejection, batch isolation, provider
  status classification, queue redaction, idempotency, concurrent quota-edge
  acceptance, evidence validation, retry/lease behavior, required prompt
  fields, and rollback/fallback tests.
- Focused Flutter SMS/review/repository tests: **66 passed**; the separate AI
  suggestion screen checks passed **2/2**. Added repository tests cover the
  authenticated queue request, refusal/offline fallback, and source-scoped
  status polling.
- Full API suite: **818 passed, 1 failed, 2 skipped**. The single failure is
  `api/test/local_sms_parity.test.js` expecting `other` while the current parser
  returns `credit_card`; it is outside the Gemini code paths.
- The broader Needs Review screen test file has four unrelated missing-action
  assertions (`Ignore message` / `Dismiss all`); its two AI suggestion tests
  pass. These are current shared-checkout UI changes, not changed by this test
  work.
- Live production: the 1% pilot was enabled for verification, then **paused**.
  Final counters: pilot disabled at 0%; no queued/leased/done/failed jobs, no
  provider reservations, results, or retries.
- Live provider probe: the configured key returns model metadata (HTTP 200) and
  the model advertises `generateContent`; HTTPS/DNS work and an authenticated
  empty-content validation request returns HTTP 400 quickly. A tiny synthetic
  generation succeeded once on `gemini-3.6-flash`, but other attempts on that
  model returned 503. Its full classifier call varied between success and 503;
  one successful response failed the fact contract because required balance
  fields were omitted. `gemini-3.8-flash` timed out at 20s and 60s;
  `gemini-3.7-flash` timed out; `gemini-2.5-flash` returned 404. The provider is
  not reliable enough for rollout.
- Google AI Studio shows a Free Tier project with unused limits for 3.8 Flash
  (0/5 RPM, 0/250K TPM, 0/20 RPD) and no billing account. Usage charts show no
  data at inspection time (the UI warns up to 15 minutes of delay); API
  Logs/Datasets are disabled until billing is configured. This does not prove
  billing is the cause, and no billing change was made.
- The production pilot is **paused** (`sms_ai_queue_enabled=false`, rollout 0).
  Final aggregate counters show no queue jobs, provider reservations, results,
  or retries. No real SMS content was sent and no production job was created.
- The 1% pilot remains **paused** until Google-side generation entitlement or
  service reliability is clarified and repeated full-adapter probes succeed.
- The local worker prompt was tightened to state required fields by fact type,
  amount/date role mappings, and fail-closed abstention. Its prompt regression
  test passes; this local source change is not deployed yet.

## Subsequent local review verification (2026-10-24)

- Full API suite: **853 passed, 0 failed, 2 database integration tests skipped**.
- Full Flutter suite: **1,666 passed**. A later source-identity correction passed
  all **49** targeted spending-selection, spend-trends, and card-detail tests.
- App-wide Dart analysis: no errors or warnings; 73 informational findings.
- Review fixes include enforcing review-only AI results during intake/replay and
  projection backfill, distinguishing provider HTTP 422 from terminal result
  validation, and removing conflicting per-item batch response instructions.
- This review performed local checks only. It did not rerun production probes,
  change rollout flags, deploy services, or verify a physical-device update.
