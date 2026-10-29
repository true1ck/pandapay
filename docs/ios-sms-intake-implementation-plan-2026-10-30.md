# PandaPay iOS SMS intake: implementation plan

Prepared 30 October 2026. This is the execution plan for moving acquisition from the diagnostic app to the real PandaPay iPhone app. It incorporates nonblocking reconciliation, replay prevention, selected monthly onboarding, account ownership and recovery. Production implementation and device acceptance remain pending; this planning change installs no app or automation.

Related specifications:

- [Android/iPhone acquisition comparison](ios-android-sms-acquisition-parity-2026-10-29.md)
- [Main-app integration design](ios-shortcuts-main-app-integration-plan-2026-10-29.md)
- [Monthly history onboarding](ios-monthly-history-onboarding-spec-2026-10-29.md)
- [Live, daily and app-open reconciliation](ios-live-capture-reconciliation-review-2026-10-30.md)

## Required result

The main app displays its existing local data immediately. A user returning after several days can navigate and edit normally while eligible saved SMS are processed off the UI isolate. A small, nonmodal status strip near the top reports catch-up progress, waiting for Shortcuts, partial results or retry. No route guard, full-screen spinner or modal blocks ordinary app use for SMS import.

Live, app-open, daily and history acquisition converge on one durable handoff and the existing shared financial pipeline. Repeated acquisition of the same source must not create another financial transaction, reset retry progress or lose an unfinished item. Initial iOS history remains selectable, including two years/custom dates, processed one calendar window at a time.

**Platform boundary:** Flutter processing in the background of the UI is different from iOS granting runtime while an app is closed. Also, searching Messages requires Shortcuts; an app-to-Shortcut launch may take the user out of PandaPay. Do not describe that as an invisible in-app background inbox read. Background-only execution of the full search recipe must be demonstrated before enabling any automatic acquisition mode that depends on it. If a new search needs a transition or permission, keep the app usable and show **Continue catch-up**. Never repeatedly switch the user to Shortcuts on every app resume.

## Verified baseline and gaps

| Existing behaviour | Evidence and implication |
| --- | --- |
| Shared message hash | `smsSourceKey` in `app/lib/data/local/sms_intake_repository.dart` hashes the account, normalized sender and normalized body using SHA-256. `api/src/import_source_key.js` uses the corresponding wire contract. Reuse it instead of creating an iPhone financial key. |
| Timestamps intentionally excluded | The API source explains that Android live and provider deliveries can have different timestamps for the same SMS. Adding Current Date or acquisition time to the financial key would turn retries into new sources. |
| Local replay checks | `SmsImportStore._capture` checks reconciliation receipts and final decisions for the current parser version, then remembers repeated input. Database primary keys scope those sources to an account. Duplicate verification cannot be only a UI/in-memory check. |
| Repeated-occurrence warning | `SmsIntakeRepository.remember` marks `repeated_occurrence` when the same source key arrives with a different timestamp. One captured financial source is still retained. Separate identical messages can therefore share a canonical source. |
| Background capture worker exists | `SmsCaptureWorker` processes batches on a separate isolate. `_captureMessages` already loads account/rule state and notifies the UI after external commits. Reuse that owner. |
| Main-isolate fallback exists | `_captureMessages` currently falls back to direct synchronous capture after a worker failure. A large reconciliation through this fallback could block the UI and reset pending work; constrain the fallback for production catch-up. |
| iPhone production connection is absent | Probe-only actions and a memory queue are not a main-app receiver. The existing `captureShortcutMessages` integration seam still needs a production bridge/drainer. |
| Source acquisition has limits | User-tested space-trigger coverage is partial; metadata and source-index completeness remain device checks. Deduplication cannot recover a message that was never found or handed off. |

Baseline verification for this plan: 15 Flutter tests passed across the intake repository, capture worker, iPhone/shared-acquisition parity and capture-owner integration; 4 API source-key tests passed. This checks existing behaviour, not the new job queue or status UI described below.

## Deduplication: separate transport, source occurrence and financial identity

Do not use one new hash for all three purposes.

| Identity | What it identifies | Proposed rule |
| --- | --- | --- |
| Capture/receipt ID | A specific issued handoff or replay of that transport item | Persist the ID; repeat acknowledgement of the same ID is idempotent. Arbitrary per-call UUIDs alone cannot detect the same source in another search. |
| Source-occurrence fingerprint | The same original SMS returned again by live/history/overlapping searches | When trustworthy source metadata exists, hash a versioned, unambiguous tuple of account scope/generation, original sender, full-body digest and original receive instant at a documented precision. Use the same encoding across acquisition routes; do not include the route or current scan time. If a verified stable source identifier is available, preserve it as evidence too. |
| Financial source key | The input identity already used by PandaPay's shared intake/API | Keep the current versioned account + normalized sender + normalized body hash. No iPhone-only timestamp change. |

The source-occurrence fingerprint is for an acquisition ledger and efficient repeat detection, not a replacement financial key. Original metadata must be usable and stable before relying on it. A Current Date fallback, unknown timestamp precision, missing sender or substituted contact name cannot establish an exact occurrence identity; record the limitation and use existing shared processing/decision checks. Do not silently round different source instants together or overwrite original values to force a match.

Message/body hashing does not authenticate a bank and does not anonymize financial content. Keep raw input and hashes in private account-scoped storage, outside URLs, analytics and ordinary logs. No amount/merchant/day-only deduplication is allowed.

### Repeat-handling sequence

1. Validate account ownership/generation, envelope version, bounds and pre-storage security requirements before adding a production raw-message spool item.
2. Atomically claim a transport receipt and, where verified, a source-occurrence fingerprint using database uniqueness. A check-then-insert race in two processes is insufficient.
3. If that receipt/occurrence is already **committed**, record a lightweight already-seen receipt for this attempt and avoid another raw spool copy or identical parse/upload. If its work is still **pending or failed**, attach the new attempt to the existing pending item; do not treat mere existence as success.
4. Reconcile policy/parser versions before skipping processing. A receipt ledger must not block an intentional shared parser-version upgrade that should re-evaluate an older decision. Reuse the shared pipeline's replay/version logic and protect existing user corrections.
5. For new or unresolved work, durably save first, then submit bounded records through the existing shared capture owner. A successful local result is independent of a pending HTTP upload.
6. Store the committed shared outcome/receipt link, then acknowledge/delete the transport spool item. A crash between processing and acknowledgement must replay through shared idempotency rather than create a second financial record.
7. Preserve attempts, next retry time, original input and committed user edits on repeated submissions. Audit `INSERT OR REPLACE` paths in `SmsIntakeRepository.capture`: a replay of pending work must not reset retry metadata or overwrite the evidence merely to deduplicate.
8. Count returned, already seen, pending, processed, ignored and newly created records separately. Existing decision receipts still count toward handoff reconciliation; duplicates should not be invisible missing items.

### Repeated identical messages: release decision

Exactly equal normalized sender/body text with different receive dates is ambiguous under the current financial key. The new acquisition ledger must preserve the distinct original occurrences and mark that ambiguity; do not discard the evidence or create an extra transaction based solely on another date. Current Date must not be used to manufacture a new occurrence.

Before promising that all distinct repeated payments are retained, add Android/iPhone/API fixtures for this case and determine whether the shared identity policy needs a new version. If so, design its backfill, compatibility/mapping to existing sources, retry behaviour and API/database changes together. Do not ship an iOS-only fix that duplicates old transactions or silently changes Android semantics. Phase 1 below treats this as a release gate; until resolved, retain explicit ambiguity instead of claiming perfect deduplication.

## Nonblocking user experience

Use the existing app shell (`_AppShell` in `app/lib/app/router.dart`) to host a compact `SmsSyncStatusBar`, adapting the current design without blocking or covering screen controls. The exact widget/controller names below are proposed new components.

| State | Top status strip | User can continue using PandaPay? |
| --- | --- | --- |
| Local data ready; catch-up queued | “Checking for recent messages…” | Yes; show cached balances/activity immediately. |
| Already-saved input being processed | “Updating recent activity…” with indeterminate indicator or known batch progress | Yes; process off the UI isolate and update committed records incrementally. |
| External acquisition needed | “Recent-message check pending” with **Continue catch-up** | Yes; launching Shortcuts is a user-visible step unless a tested quiet route is available. |
| Waiting for issued Shortcut result | “Waiting for message import…” with Details/Pause | Yes when PandaPay is visible; returning alone must not relaunch the same attempt. |
| Known date windows complete/in progress | “Checking day 2 of 4” or “Importing month 8 of 25” | Yes; calculate progress only from a known window denominator. |
| Paused or retryable failure | “Message update paused” / “Some dates need another check” with Resume/Retry | Yes; preserve saved data and the last committed coverage boundary. |
| Offline network sync pending | “Saved on this phone; upload pending” when useful | Yes; keep local acquisition separate from server sync. |
| Finished | Brief “Recent messages checked” or “Updated through [time]”, then collapse | Yes; use “checked”/coverage language, not an unverified all-SMS guarantee. |

The View renders immutable state from a Riverpod-backed controller or existing state-management equivalent. Keep databases, native calls, retries and hashing out of widget `build`. No new state-management framework is needed. Rate-limit progress rebuilds/accessibility announcements, respect reduced motion/text scaling and safe areas, and avoid exposing SMS bodies or senders in the strip. A dismissed strip must not delete or acknowledge pending intake.

Startup/resume creates or joins an asynchronous job **after the first usable local screen**, never an awaited prerequisite for routing or ordinary providers. Coalesce repeated resume events; rate-limit no-op checks and retain the active attempt token across external-app round trips. Do not recursively open Shortcuts each time it returns focus to PandaPay. Preserve in-progress edits and navigation as financial data updates.

## Processing and concurrency architecture

| Layer/component | Role and concrete implementation task |
| --- | --- |
| Production native App Intents | Accept original text/body/date, keep background execution mode, validate issued account/attempt and durably hand off without waiting for Flutter. Rebind existing recipes to the main app as described in the migration plan. |
| Native spool/receipt store | Atomically save private input, receipt/occurrence links and outcomes with concurrency protection. Enforce storage bounds without dropping unacknowledged items; defer safely when protected data is unavailable. |
| `IosShortcutIntakeService` | Serialize spool drains, respect account/recovery generations and reconcile receipts before deletion. Existing `captureShortcutMessages` remains the financial entry point. |
| `SmsReconciliationCoordinator` | One acquisition lease/owner for app-open, daily, manual and historical range requests; persist interval/attempt state, overlap and frozen cutoffs. Keep logical historical and ongoing coverage ledgers distinct. |
| `SmsReconciliationRepository` | Store jobs/windows/attempts/coverage and acquisition receipts. Use indexed account-scoped lookups and bounded reads; no full-history body scans for a duplicate check. Native and Dart coordination must share persisted authority rather than only an in-memory mutex. |
| Existing `SmsCaptureWorker` | Reuse the shared parser/rules in bounded batches off the UI isolate. Do not send enormous message lists across isolates or run an entire two-year job in one transaction. |
| Shared intake/store | Reuse canonical source keys, financial/ignored/review decisions and user/rule precedence. Audit pending-replay writes and rollback behaviour while retaining Android parity. |
| Existing sync owner | Own HTTP retries, reconciliation and mutations. No second uploader in the native action or status widget. |
| Status controller/widget | Observe committed repository state and expose Continue/Pause/Retry commands without owning the import job. Scope observations to the active account. |

Select a measured small batch target initially, for example at most 50 records, and profile it on the target iPhone before settling on throughput. This is a bounded work unit, not a source-query or history cutoff. Yield/commit between batches, keep transactions short, apply backpressure and prioritize live saves/ordinary user writes over historical work. Handle busy storage with bounded retry/backoff rather than long UI-thread waits.

For worker failure or timeout, retain durable work and show retry status. The existing direct-store fallback must not synchronously process a large reconciliation on the UI isolate. Restrict it to measured small work or defer/restart the worker; ensure a timed-out worker cannot commit later while another owner races the same batch. Stable IDs, a persisted lease/fence and database uniqueness remain necessary even with one coordinator.

An isolate protects UI responsiveness; it does not keep iOS alive or guarantee timer execution. Daily recovery is an optional user-configured Time of Day Shortcut that enters the same durable coordinator. If the app is absent, native actions preserve input/progress and Dart drains later. No perpetual background task or invisible direct Messages reader is part of this plan.

## Checkpoints and failure rules

- Advance a receive-range checkpoint only through a contiguous completed interval with reconciled acquisition receipts and committed eligible shared outcomes. Last live SMS, app open and network upload are different timestamps.
- Use a frozen cutoff and overlapping date lookback for app-open/daily catch-up. Reopening after four days includes the whole gap, not only today. Split large gaps into day windows; initial user-selected older history uses month windows and explicit child splits when dense.
- Treat security exclusions and other final shared decisions as recorded outcomes; missing metadata, silent truncation and uncertain durable saves cannot masquerade as complete coverage.
- On interruption, restore existing attempts/receipts before scheduling another; callbacks are untrusted/idempotent signals, not proof of complete acquisition.
- Bind job, receipt and native spool data to account/recovery generation. Sign-out/reset prevents old captures from being attributed to the next account, and recovery fencing applies across isolates/native writers.
- A daily trigger, manual action and app resume at once should coalesce into one acquisition lease plus at most one follow-up. Live single-message saving stays available while history is paused or running.
- Keep original sender/body/receive-date provenance. Missing sender inference remains an explicit diagnostic-only option; estimated live dates must not participate as verified original occurrence dates.
- Use classified non-sensitive error codes in UI/logs; do not let exceptions or callback URLs expose raw financial messages or credentials. Hashes are not public telemetry.

## Existing shortcuts: required migration

The main change is replacing the prototype's **app actions** with main PandaPay actions, then reconnecting their variables. Renaming the app or Shortcut does not rebind an action: saved actions belong to the prototype bundle (`app.pandapay.iosimportprobe`). The main iPhone project already exists, but its production receivers must be implemented, installed and discoverable before this migration can work.

| Existing workflow | Required change | Settings/logic to retain |
| --- | --- | --- |
| Live incoming SMS | Replace the prototype capture action with the main PandaPay capture action. Reconnect Message Content, the source Message's Sender property as text, and receive date; verify each mapping after replacement. | Keep the working one-space Message Contains trigger and full-body mapping. A supported Current Date fallback remains explicitly estimated live receive time, not verified source metadata. |
| Selected-range history | Replace prototype prepare/begin, range-boundary, per-message capture and finish actions with the production protocol's equivalents. Supply the issued window/attempt and reconcile its completion receipt. | Retain the date-filtered search and per-message loop, preserving each message's own body, sender and original receive date. Do not use Current Date for history or a latest-N message limit. |
| Month-by-month onboarding | Connect the same parameterized production history Shortcut to the app's persisted monthly coordinator. | The user chooses the period inside PandaPay. No separate Shortcut per month or manual monthly date editing is required. |
| App-open/manual catch-up | Use the production history protocol with the coordinator's missing date windows and frozen cutoff. | Reuse the same acquisition and deduplication path; continue normal app use and expose acquisition continuation when an external Shortcut launch is needed. |
| Optional daily recovery | If enabled by the user, add a Time of Day automation that invokes the production reconciliation entry point. This is separate setup, not an existing shortcut that automatically changes. | Use the same coordinator, coverage ledger and deduplication as app-open/manual catch-up; do not create a second processing pipeline. |

Keep the original prototype recipes and app until the replacements pass mapping, quiet-execution, durable-save and replay tests. Test the main-app recipes without relying on prototype actions before retiring the prototype. Replacement alone does not prove background reliability or complete SMS coverage. The detailed sequence is in [Shortcut migration](ios-shortcuts-main-app-integration-plan-2026-10-29.md#shortcut-migration).

## Implementation phases and gates

| Phase | Deliverable/files | Exit gate |
| --- | --- | --- |
| 1. Lock input and identity contracts | Extend shared fixtures for `smsSourceKey`/API equivalence, normalization, original vs estimated dates, distinct equal-text occurrences and parser reprocessing. Define versioned acquisition envelope/receipt schema. | No iOS-only financial hash; repeated-occurrence release decision documented with tests and any shared migration plan. |
| 2. Add durable native input | Main-target native action/spool; startup bridge registration; indexed atomic acquisition receipts and capture-time ownership. | Write failure never acknowledges saved; successful handoff survives process restart; text bank/personal senders and metadata remain intact. |
| 3. Connect shared processing | `IosShortcutIntakeService` → `captureShortcutMessages` → `SmsCaptureWorker`/shared intake. Harden pending-replay writes and large-batch fallback. | Crash/retry/concurrent replay yields one intended financial effect; rules/profile/namespace match Android under equivalent state. |
| 4. Add persisted reconciliation | Repository/coordinator for intervals, receipt reconciliation, one acquisition lease, overlap, partial windows, account reset and backoff. | Three/four-day gaps and interrupted/empty/dense windows resume without skipped coverage or duplicate financial effects. |
| 5. Add usable shell status | Start lifecycle work after first usable frame; compact status strip and Continue/Pause/Retry; incremental committed updates. | Navigation and editing remain responsive; no blocking spinner or forced Shortcut launch loop; unknown progress is not a fake percentage. |
| 6. Add onboarding and optional daily setup | Period picker incl. two years/custom, monthly window queue, main-app-bound live/history recipes, daily setup instructions. | Queries cover selected dates with no latest-N cutoff; daily/manual/resume share one owner and no user automation is silently created. |
| 7. Device qualification and release | Profile-build verification, real-device state matrix, privacy/account lifecycle checks, release gating and migration instructions. | Main-app actions function without the prototype; limits/continuations documented; same-revision Android/iPhone tests pass before claiming platform parity. |

Proposed production files, not yet created: `IncomingSmsIntent.swift`, `IncomingSmsSpool.swift`, `ios_shortcut_intake_service.dart`, `sms_reconciliation_coordinator.dart`, `sms_reconciliation_repository.dart`, and `sms_sync_status_bar.dart`. Add schema migrations through the existing local DB approach rather than creating an unrelated financial store. Exact schema names and native/Dart ownership boundaries must be reviewed in Phase 1 before implementation.

## Test matrix

| Case | Required assertion |
| --- | --- |
| Same SMS through live, monthly, daily and app-open paths | Reused source/committed decision; no second financial row or duplicate upload from replay. |
| Duplicate while original is pending/failing | Joins existing work and preserves attempts/backoff; existence alone does not acknowledge success. |
| Different capture times or UTC spellings for the same original instant | Financial key remains stable; trusted occurrence normalization is deliberate; Current Date cannot create another source. |
| Same amount/merchant but different reference/body | Distinct valid sources stay distinct. |
| Exactly equal sender/body, different original dates | Distinct occurrences retained for audit; canonical ambiguity/migration gate explicit; no silent new claim of perfect identity. |
| Missing/inferred sender, contact display name, altered body representation | No fabricated match or automatic deletion of a potentially different source; incomplete/ambiguous status visible. |
| Two native calls, resume and daily callbacks overlap | Atomic receipt uniqueness plus fenced lease; no concurrent financial double effect or overlapping acquisition launch. |
| Process fails before save / after save / after shared commit / before ack | Failed save reports failure; durable pending survives; committed replay is idempotent. |
| Worker unavailable/time-out/late completion | No large synchronous UI fallback; work retained; late writes cannot bypass fence/uniqueness. |
| Large catch-up plus user navigation/edit | UI stays responsive in a Profile build on a real phone; edits persist; short transactions don't monopolize the writer; no lost live capture. |
| Four-day absence / empty day / dense month / indexing delay | Entire chosen gap planned with overlap; no early stop, silent capacity truncation or checkpoint leap over a failure. |
| Repeated resumes and Shortcuts return | One continuing attempt; no launch loop; route and user state preserved. |
| Offline or server failure after local capture | Local progress and data remain usable; upload retry doesn't reacquire already committed input unnecessarily. |
| Account switch, sign-out, reset/recovery | Old receipt/spool data cannot land under a new namespace/generation or resurrect deleted data. |
| Unknown progress, text scaling and accessibility | Honest indeterminate indicator until denominator known; top strip does not cover controls or flood announcements. |
| Background, suspension, system termination, force-quit, locked, pre-first-unlock reboot | Independently measured acquisition/save/process outcomes; foreground success is not extrapolated. |
| User ignores/pauses catch-up | App remains usable; pending data/checkpoint preserved; no compulsory repeated app switch. |

No plan can guarantee zero missed or ambiguous messages when iOS does not trigger/return them, source metadata is absent, messages were deleted or shared policy intentionally excludes them. The release goal is auditable coverage, durable saves, controlled retries, nonblocking use and tested replay safety, with unsupported states visible.

## Sources and engineering basis

These sources support the design principles; they do not certify this app's implementation or guarantee silent Shortcut execution:

- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations): separate UI/controller state from services/repositories; retain the app's existing Riverpod approach.
- [Flutter concurrency and isolates](https://docs.flutter.dev/perf/isolates): move expensive work off the main isolate when needed for responsiveness; isolate work and messages have their own cost and lifecycle.
- [SQLite UPSERT](https://www.sqlite.org/lang_upsert.html) and [transactions](https://www.sqlite.org/lang_transaction.html): rely on uniqueness/atomic writes and handle busy writers, not an in-memory duplicate check alone.
- [Apple: running a Shortcut from a URL](https://support.apple.com/en-euro/guide/shortcuts/apd624386f42/ios): the supported launch route is an external Shortcut workflow; validate user-visible transitions.
- [Apple: background execution strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app): iOS controls background runtime/scheduling; UI nonblocking work is not a background scheduling guarantee.

## Delivery checklist

- [ ] Finalize acquisition/financial identity contracts and any shared identity migration decision.
- [ ] Implement durable native capture and indexed receipts with account/recovery fencing.
- [ ] Connect the shared worker and harden pending replay, timeout and UI fallback handling.
- [ ] Implement resumable ongoing/monthly jobs and one acquisition owner.
- [ ] Add nonblocking status/progress and user-controlled external acquisition continuation.
- [ ] Wire main-app shortcuts and optional daily setup; preserve prototype until acceptance.
- [ ] Run synthetic, crash/concurrency, parity, performance and real-device acceptance tests.
- [ ] Record evidence/limits and release the main-app integration through a separate reviewed release step.
