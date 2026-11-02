# iOS SMS import processing recovery — 2 November 2026

The connected phone had 3,061 durable pending inputs. Its March-only import
received 424 messages. The later screenshot's 843 receipts were March (424)
and April (419); both windows reached Finish. Processing, rather than message
acquisition, was blocked.

## Root cause and recovery

A device-registration alert was excluded by the shared SMS gate but admitted
by the native security policy. The shared capture owner returned without a
financial decision. Acquisition acknowledgement required such a decision for
every input, so the same 50-row batch failed repeatedly and blocked later input.

Registration alerts now use the common Dart/native security policy. Existing
queued security inputs receive an explicit `excluded_security` outcome without
a financial decision, raw-body digest, or shared acquisition receipt. Native
acknowledgement independently validates that exclusion against its saved body,
erases raw input and old identity bindings, and reconciles the window. Invalid
financial acknowledgements still fail and retain their queued inputs.

## Resume and progress

- Resume is disabled during active acquisition or outstanding local processing.
- A processing failure offers **Retry processing**, which only drains local
  input. It does not issue a new attempt or launch Shortcuts.
- Native retry retains already searched `finished` windows and their attempts.
- Both notification and app distinguish receiving, processing and completion.
  A delivered window counts as complete only after local acknowledgement.
- App counts refresh at most once per second during a long drain. Message
  counts distinguish read and processed input. The coverage bar includes
  completed ranges beyond a gap, rather than counting only a contiguous prefix.
- The displayed imported-through day accounts for the exclusive end boundary.

## Background execution

`SmsImportBackgroundHost` registers the permitted task identifiers at launch.
An explicit user Start/Resume requests iOS 26 continued-processing runtime.
Automatic window advancement does not request new user-initiated runtime.
The system activity reports read/processed counts; older/fallback paths retain
the custom Live Activity. Finite UIKit runtime supports warm background drains;
a network-independent `BGProcessingTask` provides scheduled recovery.

A warm task joins the existing serial controller. A cold task starts the
retained `iosSmsBackgroundMain` Flutter entry point and uses the existing
`SmsImportStore`/acquisition receipt pipeline. It does not restore tokens,
perform HTTP, search Messages, or launch a Shortcut. Persisted account namespace,
native generation and consent are checked before mutations and acknowledgements.
Cold processing uses the installed app version for downloaded-rule compatibility.
Expiration stops between committed batches and preserves the remaining queue.
Cancelling a continued task pauses acquisition.

iOS controls background runtime and scheduling; the earliest begin date is not
a promised start time. Saved inputs remain durable when runtime is unavailable.

## Validation

- 404 SMS feature and intake/security regression tests passed.
- Native spool tests cover preserved finished windows, processing-aware progress,
  rejection of forged exclusions, and erasure/recovery of legacy security input.
- Dart and native security policy tests share 35 synthetic cases.
- Static analysis of the changed SMS implementation passed.
- Replaying a read-only acquisition copy against a separate local financial
  database copy processed all 3,061 inputs, excluded one security alert, and
  left zero pending inputs. No original message text is included in this report.
- Background tests cover bounded cold batches, expiration, generation changes,
  and signed-out refusal. Widget tests cover disabled Resume and local retry.
- Device build uses the project's existing Personal Team testing entitlement
  override; distribution entitlements remain unchanged.

## Connected-phone result

Installed and launched signed development build **1.0.15 (103)**. A fresh
read-only acquisition copy confirmed pending inputs fell from **3,061 to 0**;
committed inputs increased by 3,061. March (424 found) and April (419 found)
both reached `complete`. There were no new capture rows or history jobs, and
all existing window attempts were preserved. The app queued its usual recent
catch-up after processing; no history reimport was started.

The full SMS regression run passed 404 tests. Subsequent targeted controller
and native checks passed after the final pause/completion refinement. Signed
bundle verification passed, including the retained headless entry point and
existing Shortcut action contracts. OS-scheduled cold execution was not forced
on the phone; its worker and expiration/account boundaries were tested locally.
