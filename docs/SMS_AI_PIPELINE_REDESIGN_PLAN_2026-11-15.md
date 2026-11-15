# SMS AI pipeline redesign: plan (2026-11-15)

Status (2026-11-15): **built on `dev`, uncommitted, not deployed.** WP1 to WP7 are implemented and tested (see section 11); WP8 (fair
model benchmark on live keys) and WP10 (fragmentation measurement) are still to run. Examples below are synthetic (the remote is public).

Decisions by the owner (2026-11-15): free Gemini keys only (no billing), so the pipeline is built to be gentle and small; **no admin
approval gate**: a drafted rule goes to the phones that sent the layout on its own (an admin can still reject or withdraw it afterwards);
a 20 second pause between calls is fine; measure layout fragmentation; retry the failed layouts once the new prompt ships.
Read `docs/PERFORMANCE_RULEBOOK.md` before touching phone-side SMS code.

## 1. Goal

When the phone meets a message layout no rule reads, Gemini should:

1. see the **real wording** of the message, with every amount, account number, reference and date swapped for fake values (person names hidden, merchants kept);
2. get a **small request** (target 1.5k to 3k tokens, today about 14k);
3. be called **gently**: first in, first out, one layout at a time, with a configurable pause (10 to 50 s) and the provider's own retry delay respected;
4. return a **decision by slot** ("the first amount is the posted debit, the account mask is the card"), so the answer is value independent;
5. have that answer **applied on the phone** to the real message and auto-resolve it;
6. be **reused for other people**: the same layout from another person never calls Gemini again.

## 2. What the investigation found (evidence for this plan)

| Finding | Evidence |
|---|---|
| All 30 failed layouts are rejected drafts, none retryable | 28 `draft_validation_failed`, 2 stale `capacity`; worker requeue moved 0 |
| Output length is not the cause | replies avg ~1,000 tokens, max 2,397, cap 4,096 |
| Request is huge and mostly boilerplate | 43 to 47 KB (~14k tokens): `existingRules` 12 to 16 KB, `ruleSchema` 12.9 KB, `factContract` 10.8 KB, domain rules 4.3 KB; the layout itself ~150 B |
| Top rejection reasons are regex problems | bench: `template_sample_mismatch`, `example_mismatch`, `regex_dialect_invalid`, `emitted_attrs_invalid` |
| Redaction garbles layouts | ordinary capitalised words become `<PARTY>` ("Dear Customer", "Sorry", "BLOCK") |
| Rate limits come from bursts, not from production | prod peak 5 req/min (~90k tokens/min); my 3-way parallel bench caused the 429s; single calls succeed on both keys |
| Both keys look free tier | 429 bodies cite `FreeTier` quota metrics |
| Old pipeline (21 Oct, `d50a81d1^`) was gentler | key rotation, body `retryDelay`, fallback model, token gate 30 rpm / 24k tpm, batch 1 to 4, ~2.8k tokens/message |
| "24 done" is the server count, not applied | covered layouts send no rule (status `pending`); ready drafts only tested on synthetic text (43/47, 43/47, 38/47 still match other value forms); AI auto-resolved counts only messages whose trace names an `AI-` rule |
| Reasons for failure are not stored | worker keeps `errors` in memory only |
| Cross-user reuse exists but is untested in prod | all 100 eligible layouts have exactly one submitter |

## 3. Target design

```
PHONE                                   SERVER                              GEMINI
-----                                   ------                              ------
unknown message
 redact: fake values, keep words
 layout = skeleton with slot tags
 hash = H(sender, skeleton)  --------->  known hash? ---yes--> return stored
 leak check (drop sample if any                |                answer (NO Gemini call)
 original digit run survives)                  no
                                         FIFO queue (queued_at)
                                         worker: claim oldest, wait pacing gap
                                         build small prompt  ------------->  structured answer
                                                                     <-----  emit by slot
                                         build matcher from layout (deterministic)
                                         validate emit only, store by hash
 pull sync <-----------------------     deliver rule to every submitter
 overlay rule -> engine reads the REAL
 message -> facts -> auto-resolve
```

Key choice: **Gemini no longer writes the regex.** The server builds the matching pattern
from the layout deterministically (each slot tag becomes a named capture group with a known
good pattern; the words are literal). Gemini only supplies the meaning (`emit`). The phone's
existing path (provisional overlay, `match.templateHash`, engine, trace, "AI auto-resolved")
is unchanged, which also means **no app release is needed to apply results**, and old app
builds keep working.

This also removes the need for a fake-to-real value map on the phone: Gemini refers to
slots, and the engine captures the real values from the real message.

## 4. Work packages

Order matters. Each package lists files, steps, tests and the "done when".

### WP1. Record why drafts fail (do first, ships alone)

- Migration: `sms_v2_template_attempts` gets `error_codes text[]`, `error_kind text` (`provider_busy|provider_incomplete|json_invalid|validation|systemic`), `http_status int`; `sms_v2_unknown_templates` gets `failure_detail text[]`. Codes only, never message text.
- `api/src/sms_v2/template_worker.js` `runTemplateWorkerOnce`: stop collapsing everything into `provider_or_json_invalid`; save the real code from `ProviderBusyError`, JSON parse, `template_provider_incomplete`, and the validator list; record tokens even for incomplete replies (they are billed).
- `console/lib/features/dashboard/sms_ai_operations_screen.dart` and `api/src/sms_v2/learning_admin_route.js`: show failure kind counts per prompt version.
- Tests: extend `api/test/sms_v2/template_worker.test.js`; PG test for stored codes.
- Done when: a failed layout shows its reasons in the console.

### WP2. Provider layer: quota-aware, key rotation, retry delay

Reuse the old pipeline's logic (`d50a81d1^:api/src/gemini_worker.js`, class `GeminiProvider`).

- `createGeminiTemplateProvider`: accept an ordered key list (`GEMINI_API_KEY`, `GEMINI_FALLBACK_API_KEY`, optional `GEMINI_API_KEYS`); on 429/403-quota rotate to the next key; put a cooling key on a cooldown until its delay passes; never print keys.
- Parse `error.details[].retryDelay` from the 429 body (today only the `Retry-After` header is read, and Gemini does not send it). Default 30 to 35 s jittered when absent.
- Fallback model on 404 (`ai_fallback_model` setting); `gemini-2.5-*` currently 404 on the primary key.
- Request body: `systemInstruction` (static), `generationConfig.responseSchema` (structured output), `maxOutputTokens` 1024, thinking set to minimal for flash-lite models (spike: confirm the parameter name for the current model; thinking tokens consume `maxOutputTokens`, which cut off `gemini-3.5-flash`).
- `docker-compose.prod.yml` + `.github/workflows/deploy-prod.yml`: pass `GEMINI_FALLBACK_API_KEY` into the worker (the value already exists in the server `.env`).
- Tests: fake `fetch` for 429 with body delay, 403 quota, 404, timeout; key rotation and cooldown; no key in logs.
- Done when: forced 429 on key A moves to key B, and the wait equals the provider's delay.

### WP3. Queue: first in, first out, paced, gentle

- Migration: `sms_v2_unknown_templates.queued_at timestamptz` set on queue and on requeue (a requeued layout goes to the back).
- `claim()` in `template_worker.js`: `ORDER BY queued_at, template_hash` (today: most consenting people, then live-in-24h, then first seen).
- Worker loop (`jobs/template_worker_main.js`): after every provider call wait `max(ai_min_gap_seconds, provider delay)`; idle poll stays 15 s.
- Settings in `api/src/sms_v2/settings.js` (console-adjustable): `ai_min_gap_seconds` (default 20, range 5 to 120), `ai_batch_size` (default 1, max 4), `ai_fallback_model`, `ai_prompt_examples` (default 2).
- Token gate: keep `reserveCapacity`; set defaults to 24k tokens/min and 30 req/min until the real tier is known; the estimate comes from the new, smaller prompt.
- Batch of N layouts: one request, answers keyed by an item id; a missing or invalid item is retried alone, never blocks the others.
- Tests: PG test for FIFO order and back-of-queue requeue; fake-clock test for the pause; batch of 2 maps answers to the right layouts.
- Done when: 10 queued layouts drain in arrival order, one per gap.

### WP4. Small prompt (target 1.5k to 3k tokens)

- Static part first (cacheable): short system instruction (~1.5 KB, the domain rules condensed), then a slim answer schema passed as `responseSchema`, not as prose.
- Variable part last: sender, layout with slot tags, sample with fake values, up to 2 trimmed example answers from the same sender (`family`, slot mapping only; no regex).
- Drop `ruleSchema`, `factContract` and 5 full example rules from the text prompt.
- Measure with a guard test: prompt for the corpus must stay under a token budget (fail CI above 4k).
- Bump `PROMPT_VERSION`. Re-run the model bench (WP8) before and after.
- Done when: measured median under 3k tokens with the same or better validity on the bench.

### WP5. Answer by slot and deterministic matcher

- New module `api/src/sms_v2/layout_matcher.js`: layout string to regex (named groups per slot tag, literal words with flexible whitespace, patterns for amount, date, mask, reference, party, phone). Shared fixtures in `contracts/sms/v2/fixtures` so the JS builder and the Dart skeleton (`packages/pandapay_domain/lib/src/sms_v2/template/skeleton.dart`) are tested against the same corpus.
- Answer format: the existing rule `emit` shape, with `from` pointing at slot names (`amt1`, `mask1`, `date1`), plus `confidence`. The server stamps id `AI-<hash>`, status `provisional`, sender and `match.templateHash` (as `stampDraft` does today).
- Validation shrinks to the emit only (fact schema, valid slot names, reference keys, movement/hold conflicts, never "balance as amount"); the regex checks (`template_sample_mismatch`, `example_mismatch`, `regex_dialect_invalid`, `draft_overmatches_other_layouts`) are no longer needed for generated patterns. Examples required by the rule schema are generated by the server (positive from the synthetic fill; negative by removing a key word). **Spike first:** confirm `rule_bundle.schema.json` accepts this, or relax it for `AI-` rules.
- A failed validation gets one repair attempt with the error codes fed back; after that the layout goes to a `needs_review` state (not a permanent failure) and is requeued when `PROMPT_VERSION` changes.
- Tests: builder corpus (matches every fixture message of its own layout, rejects others); worker tests with a fake provider; engine test that the built rule reads a real-shaped message and auto-resolves.
- Done when: the 12-layout bench set passes at the target rate and the phone engine reads real messages with the built rule.

### WP6. Phone: send real wording with swapped values

Files: `packages/pandapay_domain/lib/src/sms_v2/template/redact.dart`, `skeleton.dart`, `vocabulary.dart`; `app/lib/features/sms_v2/sync/template_upload.dart`; contract `contracts/sms/v2/api/*unknown_templates*`.

- `redactSms` already swaps digits consistently and keeps formats; keep that for the **sample**. Add an indexed layout (`<AMT1>`, `<AMT2>`, `<DATE1>`, `<MASK1>`, `<REF1>`) next to the existing skeleton. The hash stays `H(sender, skeleton)` so existing hashes and origins do not change.
- Request item gets an optional `sample` (string). Old builds omit it; the server then uses the skeleton (graceful fallback).
- Fix the over-redaction: do not hide ordinary words. Extend `smsTemplateVocabulary` and structural words from the data (list the words that became `<PARTY>` across the synthetic corpus and the layouts already on the server; add the generic ones such as greetings and request words and SMS keywords like BLOCK/STOP). Keep: merchants in the catalogue; names after cue words (`to`, `from`, `by`, `trf to`) stay `<PARTY>`. Unknown capitalised words stay redacted.
- **Runtime leak check** before upload: if any digit run of 3 or more from the original survives in the sample, or any email/URL/phone/IFSC-like token, drop the sample and send the skeleton only.
- Server accepts `sample` with a different check from `redactedBody`: no email, URL, phone number; digit runs are allowed (they are fake) but total length and character set are bounded.
- Consent copy: confirm `template_sharing_disclosure.dart` and `legal_text.dart` describe "wording with numbers replaced, names hidden"; update both and the legal text tests if they say "layouts only".
- Performance: this runs on the capture path; keep it in the existing isolate flow, use `cachedRegExp`, run `flutter test test/performance_guards_test.dart` and `scripts/perf_smoke_android.sh` on a real phone.
- Tests: property test over the synthetic corpus (no original number survives); golden tests for sample output; upload contract tests.
- Done when: sample text for the corpus reads like the real message and the leak test passes.

### WP7. Apply on the phone and tell the truth in the app

- `covered` layouts: send a result the phone can act on (re-read with the existing shared rule) instead of `pending` (see `createTemplateStore.results`).
- `sms_v2_runtime.dart` already re-reads unknown messages when the overlay revision changes; add a log line and a test that proves a delivered rule resolves an open review item. Mind the stale-row trap (memory: weakly matched rows are never re-read in release builds): confirm open template review items are included.
- Make the overlay robust: validate each AI rule alone and skip a bad one instead of dropping all AI rules when one fails to compile (`provisional_store.dart` lines 65 to 81).
- Banner (`geminiBarState` in `review_history_views.dart`): split "done" into "ready for this phone", "applied on this phone" (count messages with an `AI-` trace), "waiting", "failed (reason)", "held (why)"; say "retrying" only when a retry is actually scheduled.
- Tests: extend `review_history_views_test.dart`, `ai_status` tests, an integration test: ready result arrives, message leaves Needs review, tab count goes up.
- Done when: the number of "done" and the "AI auto-resolved" tab agree.

### WP8. Model choice from data (answers "which model will not fail")

- Add `api/scripts/` bench (the repo has `dry_run_sms_v2_templates.js`; extend it): sequential calls with the pause, no parallelism, new prompt, new answer format.
- Set: the 30 failed layouts plus all admin-approved layouts (regression), at least 50 layouts.
- Candidates: `gemini-3.1-flash-lite`, `gemini-3.5-flash-lite`, `gemini-3.5-flash`, `gemini-3.7-flash` (timed out in probes: recheck), plus the fallback key's `gemini-2.5-flash`.
- Gate (proposal): at least 90% valid within 2 tries, under 3% provider errors, median latency under 15 s. Pick the cheapest model that passes; set the fallback model to the next.
- Done when: the model and fallback are chosen with numbers in this doc.

### WP9. Cleanup and re-run of existing failures

- One-off, with your approval: requeue the 28 `draft_validation_failed` and 2 stale `capacity` rows after WP4/5 ship and the bench passes (set `ai_retries` back, `queued_at = now()` in the old order).
- Re-send the 4 held layouts (the app already resends when counted).
- Remove dead code once the new path is the only one: regex-writing prompt parts, `validateDraft` checks that no longer apply, old tests.

### WP10 (optional, measure first). Reduce layout fragmentation

Two layouts differing only by a merchant name ("APPLE ..." vs another shop) count as different formats and each costs a Gemini call. Measure first (group layouts by sender and body with catalogue merchants masked). If many, add a **merchant slot** to the hash. This changes every hash, so it needs an origin migration; only do it if the measured saving is large.

## 5. Settings (console-adjustable)

| Setting | Default | Note |
|---|---|---|
| `ai_min_gap_seconds` | 20 | range 5 to 120; pause after each provider call |
| `ai_batch_size` | 1 | max 4; layouts per request |
| `ai_model` / `ai_fallback_model` | from WP8 | fallback on 404 |
| `ai_max_output_tokens` | 1024 | |
| `ai_prompt_examples` | 2 | example answers per prompt |
| `ai_rpm` / `ai_tpm` | 30 / 24000 | raise only with a paid tier |

## 6. Rollout (repo rules: dev first, then prod; never master)

1. WP1 (visibility) alone to dev, merge dev into prod, watch real failure reasons for a day.
2. WP2 + WP3 (provider, FIFO, pacing): worker only; restart the worker; no app release.
3. WP4 + WP5 behind a setting (`ai_pipeline=v3`), tested on the bench, then on dev data, then prod.
4. WP6 + WP7: app release; the server accepts both old and new item shapes.
5. WP9 requeue after you approve.
Rollback: flip the setting back; the old path stays until WP9 cleanup.
Migrations are additive (new columns only).

## 7. Verification

- Unit and PG tests per package (listed above); CI must stay green, including the release guards that scan for secrets and real data.
- Bench report (WP8) committed as numbers only.
- Phone replay of your real inbox (tool in `tools/sms_rules_cli`, see the replay memory) to prove "AI auto-resolved" becomes greater than zero.
- Cross-user test: two profiles send the same layout with different numbers; assert one Gemini call in total and both phones receive the rule.
- Load test: 50 queued layouts, assert the gap, order and token totals stay inside the gate.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Sample text leaks something real (a name, an id) | runtime leak check, property tests, names after cues hidden, consent copy updated |
| Both keys are free tier: Google may use inputs | enable billing on one project (decision below); sample wording makes this more sensitive than skeletons |
| Built matcher too strict for real messages | generated from the same patterns that created the layout; corpus test; phone replay |
| Rule schema needs examples | server generates them, or relax for `AI-` rules (spike in WP5) |
| Old app builds | server keeps the skeleton-only path |
| A bad AI rule hides all others on the phone | WP7 per-rule validation |

## 9. Decisions needed

1. Enable billing / paid tier before sending real wording? (Recommended: yes; the worker header already says a paid key is required.)
2. Keep admin approval of AI drafts as a publish step, or publish automatically with a confidence threshold?
3. Default pause 20 s and batch size 1: OK?
4. Run WP10 (fragmentation measurement)?
5. Approve requeueing the 30 failed layouts after WP4/5 ship?

## 11. What was built (2026-11-15)

Server (`api/`, `db/`, `contracts/`):
- `layout_matcher.js`: builds the matching pattern from the layout (slots per value kind, at most 3 name slots, under the
  2,000 character rule limit); builds the examples; reads a sample's slot values. Corpus in
  `contracts/sms/v2/fixtures/layout_corpus.json`, read by the JS matcher test and the Dart skeleton test.
- `ai_prompt.js`: fixed system prompt (about 2.5k tokens in total per request, was about 14k), vocabulary generated from the schemas.
- `template_worker.js`: Gemini returns only facts by slot; the worker builds the rule, validates it, stores failure reasons;
  two or more keys used in turn with a rest per key, the provider's own `retryDelay`, fallback model on 404, a daily quota waits
  30 minutes; a covered layout needs every value form to match; the worker rests `ai_min_gap_seconds` after each call.
- Migration `20261123080000_sms_v2_ai_pipeline_v3.sql`: `queued_at` (first in, first out), `sample` (deleted when the answer is
  final), `failure_detail`, attempt error columns, worker grants, and a retry of layouts that failed under an older prompt.
- Settings: `ai_min_gap_seconds` (20), `ai_use_sample` (on), `ai_max_output_tokens` default 2048.
- Compose, deploy workflow and example env pass `GEMINI_FALLBACK_API_KEY` (and `GEMINI_API_KEYS`) to the drafts worker only.

Phone (`app/`, `packages/pandapay_domain/`):
- `smsSample`: the redacted wording with a guard (no 3-digit run of the original, no link or address); sent next to the layout.
- A mask with digits at both ends (`4012XXXXXXXX3456`) is a mask, not a name.
- The overlay no longer drops every AI rule when one is refused; the status bar says "answered" and "applied here".

Not done, on purpose: batching several layouts in one request (one per request is gentler on free limits; `ai_batch_size` can be
added if the daily quota ever needs it), thinking-budget settings, and re-wording the consent text (to review with the owner).

## 12. Before the wording goes live: consent (owner decision needed)

The phone code that sends the wording (`smsSample`, the `sample` field) is built, tested, and **off by default**
(`smsShareWording = false` in `app/lib/features/sms_v2/sync/template_upload.dart`). Until it is on, the pipeline works with the layout alone,
exactly as before, only with the new small prompt, queue and pacing.

Why it is off: the app tells people it shares "the layout of bank messages it can't read, with every amount, name, number and date
removed", and "never shares your messages". A sample is a copy of the message with its numbers made up and names hidden. That is a
different thing to share, so before it is switched on:

1. New consent copy (`TemplateSharingCopy` in `app/lib/features/consent/template_sharing_disclosure.dart`), for example a new bullet:
   "a copy of that message with every number replaced by a made-up one and every name removed, so the AI can read its wording",
   and the footer must stop saying it never shares "your messages".
2. A new `smsSharedLearningPolicyVersion` (the database matches the exact string), so existing users are asked again.
3. Privacy Policy section 5 and the Terms text in `app/lib/features/settings/legal_text.dart`, and the store declarations.
4. Because both Gemini keys are on the **free tier**, Google may use what it receives to improve its products and reviewers may read it.
   This must be said in the copy, or one key must be moved to a billed project. The server switch `ai_use_sample` (console, default on)
   can turn the wording off again at any time, and a layout is still drafted without it.
5. Then set `smsShareWording = true`, and release the app.

## 13. Local verification (2026-11-15)

- **Prompt:** only the rules and the one example that fit the layout's words are sent, and only the slot kinds the layout has.
  Measured on 11 synthetic layouts: 1.1k to 1.6k tokens per request, average 1.3k (was 2.5k after the first redesign, about 14k
  originally). Every rule is pinned reachable by a test. A live check that accuracy did not drop is still to do (needs real quota).
- **Scenario suite** (`api/test/sms_v2/ai_pipeline_scenarios.test.js`, 13 scenarios): the real worker and provider over HTTP to
  `api/scripts/fake_gemini_server.js` (faults: 429 with retryDelay, daily quota, 503, 403, 404, bad JSON, cut off, empty).
  `SMS_V2_AI_BASE_URL` points the worker at it (never set on a hosted worker).
- **Emulator end to end** (throwaway stack, own AVD, staging flavor, test accounts, fake Gemini; scripts and logs in the session
  scratchpad `e2e/`): first message resolves after an AI draft; the same layout from a second account made no second Gemini call;
  a 429 mid-queue was handed to the other key with calls first in first out and 5 s apart; Gemini down (503, then both keys limited)
  recovered without user action; bad answers left a named failure and a retry resolved it; offline showed no error and caught up
  after reconnect. 17 Gemini calls for 8 layouts, 1.2k to 1.4k tokens per request.
- **Found and fixed:** a finished draft waited for the next ordinary sync (5 minutes) and a consent grant started no upload until
  the app resumed. Now the phone looks every 30 s for 10 minutes after sending a format that has no final answer yet, and syncs
  at once when sharing consent is granted.
- **Seen, not changed:** (1) when the server reports any held layout the phone resends everything it ever sent (once per 6 hours,
  by design in `template_resend.dart`); the server stores each layout once, but each resend uses part of the daily cap of 50.
  (2) The Insights hub counts "AI suggested" items in its "need review" number. (3) Offline, the Gemini bar shows the last known
  status (tested as intended). (4) `cost_usd` stays empty for models with no price entered.
- **Not tested:** real Gemini, App Check, signed rule bundles, two phones at once, the daily cap, wording on.

## 10. Not doing

- Restoring the old per-message pipeline wholesale (removed on purpose; one call per message; no shared learning).
- Sending raw SMS text.
- Retrying rejected drafts blindly with the old prompt.
