# Android/iPhone SMS acquisition comparison

Checked 29 October 2026 against the current feature checkout. This is a migration audit, not a claim that the installed prototype is the production iPhone app.

Target: Android SMS acquisition or iPhone Shortcut acquisition supplies the same `(sender, body, receivedAt)` contract to PandaPay's shared, account-scoped intake, triage, parser, deduplication and sync pipeline. Each device uses its own local database with the appropriate account state; a shared physical database between devices is not required.

The [main-app integration plan](ios-shortcuts-main-app-integration-plan-2026-10-29.md) describes the file changes, durable handoff, Shortcut migration and acceptance checks needed to retire the prototype.

The [30 October live/catch-up review](ios-live-capture-reconciliation-review-2026-10-30.md) adds app-open and optional daily reconciliation, using one completed receive-range checkpoint and shared deduplication rather than independent daily and resume importers.

The [implementation execution plan](ios-sms-intake-implementation-plan-2026-10-30.md) adds phases and release tests for acquisition receipts, shared identity compatibility, a nonblocking status bar and worker-based processing. It records the audit of existing deduplication and the remaining equal-text occurrence ambiguity.

| Area | Android main-app path | Current iPhone Shortcut/probe path | Migration requirement |
| --- | --- | --- | --- |
| Message body | SMS provider/listener supplies body text. | Message Content is passed as text; device screenshots show the full test body. | Preserve it unchanged. No separate iPhone financial parser is needed. |
| Sender | Provider supplies the sender address. | Optional sender text now works for one resent personal-number test. Bank-header capture remains unverified. Missing input can be replaced with an inferred bank label. | Pass the supplied source sender. Keep missing/inferred metadata explicit; inference is not original-sender parity. |
| Receive timestamp | Provider timestamp; live paths have a current-time fallback if the provider timestamp is absent. | Current Date is deliberately used as an approximate receipt/automation time for the user's live test; range imports can supply message dates. | Preserve original receipt time when available and label approximations/missing evidence. Current Date is not equivalent to original metadata. |
| Core contract | `QueuedSms(sender, body, receivedAt)`. | `IosShortcutSmsBatch` constructs the same `QueuedSms`. | Same contract already exists; validate original metadata at the acquisition boundary. |
| Triage/parser | Shared `classifySmsTriage`, `SmsGateFilter`, `SmsImportStore`, `LocalSmsParser`. | The probe calls the same shared intake and classifier. | Reuse these classes. Do not create a second iPhone algorithm. |
| Personal/numeric sender policy | Shared sender gate excludes matching personal mobile numbers and six-digit numeric sender patterns before financial evidence. | Same policy produces the observed personal-number rejection. | No iOS-specific bypass. A genuine financial SMS matching the pattern is also excluded; this is a heuristic, not verified sender identity. |
| Account context and rules | Account namespace, saved cards/profile and learned/shared/downloaded rule state are available. | Isolated namespace and temporary database; production account context is absent. | Feed the main app's account-scoped intake with equivalent account/rule state. |
| Canonical deduplication | Shared source key normalizes account, sender and body. Provider IDs separately track inbox scanning. | Same canonical source-key function after adapter conversion; transport/run identifiers are diagnostic only. | Preserve source metadata and account scope; do not substitute transport IDs for canonical keys. |
| Persistence/retries | Durable local intake and Android inbox reconciliation; background capture paths exist. | Live queue and diagnostic database are process-local. | Native durable handoff before acknowledgement, followed by shared processing/retry and restart tests. |
| Ongoing missed-message recovery | Provider scanning tracks persisted row-ID progress alongside live delivery. | No durable receive-range coverage checkpoint or app-open/daily catch-up acquisition is implemented. | One persisted reconciliation engine searches gaps with overlap on app open/manual retry/optional daily automation; advance only committed coverage. |
| Live coverage | Permission-based SMS listener plus inbox reconciliation. | One-space trigger is user-tested; messages without spaces can be missed. | Treat trigger coverage as partial and provide tested date-range reconciliation. No all-SMS guarantee established. |
| Initial history import | Provider pages and persisted row-ID progress drive inbox acquisition. | One selected date range can be handed off, but there is no durable monthly onboarding coordinator. | Let iOS users select a period including at least two years/custom dates, then run the reusable Shortcut per calendar window with saved progress. No latest-500 cutoff; see the [monthly onboarding specification](ios-monthly-history-onboarding-spec-2026-10-29.md). |
| Shortcut binding/main-app receiver | Native Android SMS plumbing is connected to the main app. | Device actions are compiled behind the probe flag and check the prototype bundle ID. Production iOS has no active call into `captureShortcutMessages`. Saved recipes reference prototype-owned actions. | Port/register main-app actions, connect their durable input to the existing capture owner, and replace prototype action references in saved shortcuts before uninstalling the prototype. |
| Build version | Earlier Android internal build was produced from master with parser version 21. | The current probe includes shared parser version 22 and the earlier advisory-security correction. | Compare both builds from the same source revision before asserting shipped-behavior parity. |

## Verification

Thirty targeted tests passed, including acquisition parity for bank-header financial SMS, personal-number financial SMS, six-digit numeric senders and chat. The existing integration test verifies that `captureShortcutMessages` reaches the account-checked capture owner and unchanged batch API with original sender/body/timestamp values. Synthetic matching establishes shared-code behavior under matching inputs/state, not complete device coverage or production iPhone wiring.

Relevant sources:

- [Shared SMS contract](../app/lib/features/sms_import/sms_background_queue.dart)
- [Android acquisition](../app/lib/features/sms_import/sms_listener_service.dart)
- [iPhone input adapter](../app/lib/features/sms_import/ios_shortcut_sms.dart)
- [Probe's shared intake call](../app/lib/data/ios_device_probe_session.dart)
- [Main-app capture owner](../app/lib/app/providers.dart)
- [Shared intake](../app/lib/data/local/sms_import_store.dart)
- [Shared sender policy](../app/lib/data/sms_gate_filter.dart)
- [Prototype-only native actions](../app/ios/Runner/PrototypeBankMessageIntent.swift)
- [Production iOS registration](../app/ios/Runner/AppDelegate.swift)
- [Acquisition parity tests](../app/test/data/ios_device_probe_session_test.dart)
- [Main-app integration test](../app/test/data/ios_shortcut_capture_pipeline_test.dart)

Conclusion: shared local classification is in place, but production integration and acquisition equivalence still have the differences above. The prototype can be discarded after the main-app action handoff, durability and real-device metadata/coverage checks are complete.
