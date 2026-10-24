# Gemini SMS pipeline test matrix

Scope: verify the 1% `sms_ai_queue_enabled` pilot without sending real SMS
content or writing synthetic queue jobs. Live provider checks use only
fabricated prompts.

| ID | Scenario | Expected result | Check |
|---|---|---|---|
| G01 | Queue flag absent, disabled, zero rollout, and 1% deterministic cohort | Fail closed unless enabled and profile hashes into the cohort | `sms_observation_migration.test.js`, `gemini_queue.test.js` |
| G02 | SMS family master switch off | AI queue remains off regardless of its own flag | `sms_observation_migration.test.js` |
| G03 | OTP, credentials, marketing, malformed, or non-financial SMS | Refused before queue, quota, or body persistence | `gemini_queue.test.js` |
| G04 | Eligible financial SMS with long IDs, URL, address, and reference | Only redacted body reaches queued payload/provider prompt | `gemini_queue.test.js`, `gemini_worker.test.js` |
| G05 | Invalid source key, sender, empty/oversize body | Rejected at HTTP boundary; no queue write | `gemini_queue.test.js` |
| G06 | Duplicate/concurrent acceptance of one source | One job and one quota increment; replay is idempotent | `gemini_queue.test.js` |
| G07 | Daily quota exhausted, including concurrent last-slot race | Fresh job refused; rejected row removed; total quota never exceeds limit | `gemini_queue.test.js` |
| G08 | Wrong/missing worker token; worker route disabled | 401/503; no lease or provider call | `gemini_queue.test.js` |
| G09 | Empty queue and expired/reclaimed lease | No-op for empty queue; one durable job is re-leased, stale token cannot land/retry | `gemini_queue.test.js`, `gemini_worker.test.js` |
| G10 | Provider capacity allowed/waiting/permanently blocked/database unavailable | Wait and heartbeat safely; no provider call before permit; bounded unavailable response | `ai_provider_quota_route.test.js`, `gemini_worker.test.js` |
| G11 | Gemini success, 429/quota, timeout, 503, non-retryable 4xx | Correct complete/retry/fail route; same job identity, bounded backoff | `gemini_worker.test.js` |
| G12 | Invalid JSON/schema, missing/duplicate/unknown batch item | Invalid output fails closed; valid batch items cannot cross-contaminate | `gemini_worker.test.js` |
| G13 | Model invents amount, account suffix, reference, or event state | Evidence/contract validation rejects it before fact writes | `ai_fact_evidence.test.js`, `gemini_queue.test.js` |
| G14 | Device fact or user override conflicts with AI result | Existing/device/user-corrected fact wins; no duplicate projection | `gemini_queue.test.js`, `sms_facts_route.test.js` |
| G15 | Successful and terminal-failure retention | AI job payload is purged; no duplicate raw SMS in server review; redacted event only | `gemini_queue.test.js` |
| G16 | Roll back feature flag while preserving existing user data | New AI submissions stop; legacy local parsing/review and saved corrections remain available | flag unit tests + local/route regression suite |
| G17 | Production secret/worker readiness and runtime activity | Worker healthy; pilot state and aggregate jobs/provider/results/retries observable without payloads or secrets | deployment + pilot workflow run |
| G18 | Live provider key/model and outbound path | Model metadata works; a synthetic generation returns a fact array that passes contract/evidence validation | opt-in production provider probe |

## Execution notes

- Unit/integration tests use fake clients and synthetic fixture messages only.
- No live customer message is replayed. Live Gemini probes use fabricated text
  and never create a production queue job or fact.
- A live provider call can only be proven after an eligible job from a profile
  in the deterministic 1% cohort is accepted. Production counters currently
  report zero jobs, so runtime queue error-rate conclusions remain limited.
- Do not put keys, SMS bodies, tokens, or user identifiers in this document.

## Results (2026-10-24)

- Focused backend SMS/Gemini suite: **85 passed**. Includes cohort selection,
  concurrent quota-edge acceptance, queue redaction/idempotency, batch isolation,
  provider error mapping/retries, fact evidence, prompt-field requirements,
  and rollback/fallback behavior.
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
- Live provider: key/model metadata succeeds; Google responds to authenticated
  request validation. The synthetic `gemini-3.6-flash` minimal generation
  succeeded, but full classifications were inconsistent (503, then success,
  then 503). The successful output lacked required balance fields. `gemini-3.8`
  timed out; `gemini-3.7` timed out; `gemini-2.5` returned 404.
- Google AI Studio shows the project on Free Tier, with unused listed limits
  (3.8 Flash: 0/5 RPM, 0/250K TPM, 0/20 RPD), no billing account, and API
  Logs/Datasets disabled until billing setup. This does not by itself explain
  the generation failures; no billing change was made.
- The production pilot is **paused** (`sms_ai_queue_enabled=false`, rollout
  0%). Final counters: no jobs, provider reservations, results, or retries.
  No real SMS content was sent and no production job was created.
- The worker prompt was tightened locally to spell out required fact fields,
  amount/date role mappings, and fail-closed abstention; the prompt regression
  test passes. That source edit is not yet deployed.
- Keep the pilot paused until a supported model completes repeated full-adapter
  probes and its returned facts pass contract/evidence validation.
