# WP-C9 - SMS v2 offline robustness

Branch `offline/c9` (from `feature/offline-first`). Plan: `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`,
findings Q-08, Q-09, C-04, S-01, S-02, S-04, L-12. Everything is additive; an online, healthy user sees
no behaviour change except the sync order described under 1.

## What changed

1. **`SmsV2Runtime._sync` order (C-04).**
   * The capture loop (and the receipts sweep) now run *first*. The rules refresh, card-state updates
     (`repository.updateCard`), uploads, corrections, template/learning-signal/stats uploads, pull and the
     "newer rules available" refresh run after it.
   * New constructor arguments: `isOffline` (default: never offline) and `headersTimeout` (default 8 s).
     `runtime_provider.dart` passes `isOffline: () => ref.read(app.isOnlineProvider).valueOrNull == false`.
     Known offline: every network step and the metrics upload are skipped; local steps (key backfill,
     re-read of unknown messages, owner recheck, AI withdrawal, category re-sort) still run.
   * `SmsV2Runtime.headers` is bounded to 8 s (a `TimeoutException`, which counts as a network failure).
     `DeviceAttestation.headers()`, `limitedUseHeaders()` and the token fetch have an 8 s timeout
     (`fetchTimeout`) and fall through with the installation id only. The failed fetch is not repeated
     for 30 s (existing `_nextAttemptAt`).
   * Online-user difference: messages already on the phone are read with the rule bundle held *before*
     that sync's rules refresh. Messages the old bundle cannot read are re-read right after the refresh in
     the same pass (`pipeline:revision` -> `_rereadUnknown`), so the result converges in one sync.
2. **Backoff burned offline (Q-08).** `FactsUpload._send` no longer calls `retryAll()` for pure network
   errors (`SocketException`, `TimeoutException`, `http.ClientException`, `HandshakeException`,
   `HttpException`); the same holds while a failing batch is split. New `OutboxStore.resetBackoff()`
   (all waiting records of the account become due, attempts kept) is called by `smsV2LifecycleProvider`
   on offline -> online through `SmsV2Runtime.resetUploadBackoff()`.
3. **Corrections after an offline spell (Q-09).** *[I] item proven true:* the requeued source payload is
   byte-identical to the queued one (for a message whose body is still in `sms_intake`), so
   `OutboxStore.enqueue` kept `attempts` and the back-off; after a long offline spell the source, event
   and ledger rows had `attempts >= 6`, the correction no longer waited, was refused with
   `correction_facts_not_found`, the resend changed nothing, and the second refusal parked it
   (`offline_correction_timeline_test.dart`, written and seen failing before the fix).
   * `_waitsForUpload`: holds while the source/event row is in the outbox with `attempts < 6` **or**
     `next_attempt_at > now` (a back-off may only mean "was offline").
   * `requeueForUpload` uses `OutboxStore.enqueue(restart: true)`: attempts 0, due now, even for an
     identical payload.
   * `correction_facts_not_found`: up to `CorrectionsSync.maxFactsNotFoundRefusals` (4) refusals, with
     waits of 1, 5 and 30 minutes (`OutboxStore.deferUntil`), then the correction stays on the phone as
     before (`notSent` on its review row). `_resent` now holds the refusal count (an old `true` counts 1).
4. **Shared-learning consent mirror (S-02).** `SmsSharedLearningConsentMirror`
   (`sync/sharing_consent_mirror.dart`, SharedPreferences, per namespace, exact policy version only).
   Written only from a server answer, cleared by any server answer that is not a current grant, honoured
   only when the lookup failed because the server could not be reached; any other failure shares nothing.
   Used by `readSharingConsent` (via `smsSharingGrantedProvider`), the runtime's `hasSharingConsent`
   and the correction form's status line.
5. **Gemini bar (S-04).** `geminiBarState(offline: true)` -> "You're offline"; the 10 s poll does nothing
   offline and `geminiServerStatusProvider` returns null without asking (it watches connectivity, so it
   refreshes when the connection returns).
6. **Merchant category rules (L-12): not wired, on purpose.** `SmsLearningFeedback.pendingSync/markSynced`
   have no caller in `lib/` and no other path uploads the rows. They cannot be uploaded safely today:
   * Local rows are keyed by a *message layout* (`CTX|merchant|sender|masked body`) and a category slug.
     `POST /merchant-category-rules` (`api/src/user_merchant_category_rules.js`) is a *merchant-wide*
     future rule derived server-side from an owned `source_transaction_id` (VPA or strict name), keyed to
     category **UUIDs**, with `Idempotency-Key` and `expected_version` for replace (`rule_exists` 409).
     There is no mapping from a layout rule to that contract, and uploading would widen a layout-scoped
     correction into a merchant-wide rule without the preview/confirmation the Future rule sheet gives.
   * Needs an owner decision plus a server contract (e.g. an SMS-layout rule entity or a slug-based
     idempotent upsert) before any client wiring. The confirmed category of each event is already
     uploaded through the v2 category batch (`_categoryOnly` outbox records), so other devices learn the
     *result*, not the local hint.
7. **Baseline bundle (S-01): owner task, not shipped.** `baseline_bundle_test.dart` proves
   `BundleStore.load` accepts a verified signed non-empty baseline (repo test vector) and refuses an
   unsigned/untrusted one, and guards that the shipped asset is the empty placeholder or verifies under
   the production keys. Note an unsigned non-empty baseline throws (`ContractException`
   `bundle.signature_required`, or `StateError` for an untrusted version-0 placeholder) on every launch.

## Owner process for S-01 (signed baseline)

1. Export keys in the environment only: `SMS_RULES_SIGNING_KEY`, `SMS_RULES_KEY_ID` (never on a
   command line, never committed).
2. `node api/scripts/release_sms_v2_bundle.js` (dry run: build, golden gate, checks), then
   `--apply --admin-id <admin_users.id>` to import and mint the cohorts.
3. Fetch the minted `all` bundle JSON and overwrite `app/assets/sms_rules/baseline_bundle.json`; its
   `keyId` must be in `app/lib/features/sms_v2/sync/rule_keys.dart`.
   `flutter test test/features/sms_v2/storage/baseline_bundle_test.dart` must pass.
4. Pick `expiresAt` far enough out: the baseline is only the never-downloaded fallback.

## Files

Changed: `features/sms_v2/pipeline/sms_v2_runtime.dart`, `sync/{attestation,facts_upload,corrections_sync,
requeue_for_upload}.dart`, `storage/outbox_store.dart`, `providers/runtime_provider.dart`,
`ui/{review_controller,correction_form,review_history_views}.dart`.
New: `sync/sharing_consent_mirror.dart`, `providers/sharing_consent_provider.dart`.
Tests: `pipeline/sms_v2_runtime_offline_test.dart`, `providers/runtime_lifecycle_test.dart`,
`sync/offline_correction_timeline_test.dart`, `sharing_consent_mirror_test.dart`,
`ui/gemini_bar_offline_test.dart`, `storage/baseline_bundle_test.dart`; extended `facts_upload_test`,
`outbox_store_test`, `attestation_test`, `corrections/corrections_sync_test` (two cases changed to the new
rules, see the commit).

No flags, migrations or schema changes.

## Known gaps / hand-offs

* **C11 (consents):** the revoke path for `sms_shared_learning` (`privacy_permissions_screen.dart`) must
  call `SmsSharedLearningConsentMirror.set(namespace, false)` *before* the server call, so a withdrawal is
  honoured offline at once. Today the mirror is cleared by the next server answer (every
  `readSharingConsent` / sync after the screen invalidates `smsSharedLearningConsentProvider`); a person who
  withdraws online and goes offline before anything re-reads the consent could still have one offline fix
  shared. This file is outside WP-C9's ownership, so it was not edited.
* The offer card and `GeminiStatusBar` "sharing off" line still read the raw server provider (offline they
  show nothing rather than a wrong state).
* `FactsUpload` still counts non-network failures (503/429) as attempts, as before; with Q-09 these no
  longer park a correction, they only delay it.
* S-05 (Android background handler dropping a message when the DB is busy) is documentation-only in the
  plan and was not touched.
