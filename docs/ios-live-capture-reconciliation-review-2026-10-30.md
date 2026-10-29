# iOS live SMS capture and catch-up reconciliation

Reviewed 30 October 2026. This consolidates the user's live-capture, daily-check and app-open catch-up ideas into the [main-app integration plan](ios-shortcuts-main-app-integration-plan-2026-10-29.md). It describes planned behaviour, not implemented production capture or an already verified background test.

The [implementation execution plan](ios-sms-intake-implementation-plan-2026-10-30.md) adds the subsequent requirements: preserve app usability during catch-up, show a top status strip, reuse checked hash/decision deduplication, track acquisition receipts separately and test crash/concurrency/identical-message edge cases before release.

## Revised design

There are two ongoing mechanisms, plus initial history import:

| Mechanism | Trigger | Work |
| --- | --- | --- |
| Live acquisition | A matching incoming-message automation | Hand off this message to a main-app native action, save accepted input durably and run shared processing when available. |
| Catch-up reconciliation | App startup/resume, optional daily Shortcuts automation, or manual retry | Search a persisted receive-date interval with deliberate overlap, durably hand off messages and run the same shared processing/deduplication. |
| Initial history | User selects an onboarding period | Seed older selected coverage month by month using the existing history design. |

Daily checks and checks after reopening in two or three days are the **same reconciliation job**, with different triggers. Do not build separate daily and app-open importers, reset progress at midnight, or search only today's messages after several days away.

The initial monthly history coordinator, ongoing catch-up and manual date-range repair should share the versioned range protocol, window receipts, account ownership, native spool, shared intake and canonical deduplication. Their scope and progress labels differ, not their financial algorithms.

## Does the app need to be open?

The intended production receiver does not require PandaPay's screen to be open. Apple's [App Intents runtime documentation](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents) supports background execution. However, backgrounded, suspended, system-terminated, force-quit and locked states are different acceptance cases. A successful foreground test or one background invocation does not establish all of them.

If the handler runs without Flutter, it must save accepted input to the native durable spool before returning. Financial processing can occur later when the shared processing owner is available. Do not equate a successful Shortcut invocation with a committed transaction or completed upload.

The current installed probe stores its native queue and Dart database in process memory. The user reports a successful handoff when the prototype was not visibly open; this is evidence for that run, but the exact process state was not instrumented. It is not evidence that messages survive process death/restart, nor proof of force-quit or locked-device behaviour. The production durable handoff remains required.

## A persisted reconciliation boundary

Use an account-scoped **reconciled-through** boundary and a persisted interval ledger. The boundary describes receive-time coverage under a completed search/handoff attempt; it does not certify that Apple's search returned every existing SMS.

Track these separately:

| Value | Meaning | Can it advance reconciliation coverage? |
| --- | --- | --- |
| Last live handoff | Most recent message that reached the native action | No; earlier messages may have failed to trigger. |
| Latest message receive date | Newest supplied source timestamp | No; one new message cannot establish coverage of the interval before it. |
| Last app opened | Most recent foreground session | No; opening the app does not complete a scan. |
| Last reconciliation attempt | When a search job was started | No; it may fail, be cancelled or return partially. |
| Reconciled through | End of a contiguous range whose acquisition receipts and eligible shared outcomes are reconciled | Yes, following the commit rules below. |
| Last server sync | Most recent acknowledged network upload/reconciliation | No; an SMS may never have reached local capture. |

The boundary is scoped to the ongoing coverage stream, with a deliberate start/baseline established at setup. Selected older-history windows have their own interval ledger. Do not let a newly completed recent window imply that an unfinished historical month is complete, or force every old-history window to finish before live capture works.

When onboarding is skipped, explicitly establish when live/catch-up coverage begins. Do not pretend the previous two years were reconciled. Older imports can be selected later.

## Catch-up algorithm

1. On a trigger, verify capture consent, the active account and recovery generation. Drain already-saved native inputs through the shared owner first. Do not discard them because a fresh search is about to run.
2. Load the ongoing reconciled-through boundary, outstanding gaps and any in-flight window. Resume/reconcile existing work before creating another overlapping attempt.
3. Freeze the new search cutoff at this run's start. Search from the earlier relevant gap or the boundary minus an overlap interval, up to that cutoff. Never use the last live event or the last successful upload as the lower bound.
4. Proposed initial overlap: rescan at least the previous calendar day, clamped to the user's chosen coverage start. Use local calendar calculations for day boundaries, persist the actual UTC instants and retain the run timezone. This is a configurable lookback for indexing/delivery delays, not a completeness guarantee. Longer manual reconciliation must remain available for later-indexed messages outside that lookback.
5. If the last successful boundary was three days ago, include that whole gap through the current cutoff, plus overlap. Split into manageable day windows; split dense days further. Use the monthly coordinator's account-bound attempts, persisted results and one-active-acquisition rule. Never reduce the gap to today's date or a latest-N-message selection.
6. Query by original **SMS receive date**, with the historical query's space/keyword filters absent. The timestamp inside a resent transaction is a separate parser field. Missing original dates cannot be replaced with Current Date for this catch-up search.
7. Preserve each found message's sender/body/receive-date association. Feed eligible inputs through the main app's existing `captureShortcutMessages` entry and shared classifier. Intentional ignores, security exclusions, duplicates and missing metadata are recorded separately from transactions created.
8. Require persisted finish receipts and reconcile enumerated inputs, durable saves, native exclusions, pending work and shared outcomes. A callback, a count alone or launching Shortcuts is insufficient.
9. Commit completed windows and advance the ongoing boundary only through a **contiguous** completed prefix. Never advance past an unresolved gap, capacity limit, permission failure, missing metadata needed for processing, cancelled attempt or uncertain durable write. Completed later intervals stay in the ledger without hiding the gap.
10. Persist new boundary/receipts consistently before acknowledgement. Crash-after-processing-before-ack replays idempotently. Network sync remains the existing outbox owner's separate responsibility; an offline upload alone does not require reacquiring the messages.

An empty window with a properly completed, reconciled search can be recorded as examined. An empty result is not proof that the Messages index is exhaustive; overlap and user-visible repair remain necessary. If overlap detects changed results in a previously examined interval, update its receipt/attention status rather than claiming all earlier coverage was infallible.

Live messages arriving after the frozen cutoff are saved by live capture or included in the next catch-up. Do not move a job's end while it is running. A daily boundary is a receive-time interval, not a comparison against a financial transaction's date.

## One reconciliation owner, several triggers

| Trigger | Planned behaviour | Limit |
| --- | --- | --- |
| App startup/resume | Show local data and keep navigation/editing usable first; drain durable input asynchronously and queue catch-up if stale/gaps exist. Display a nonmodal top status strip and **Continue catch-up** if external acquisition is needed. Coalesce frequent resumes. | Opening an external Shortcut may switch apps or require interaction; do not force repeated app switching or describe it as an invisible direct inbox read. |
| Optional daily time automation | User configures/enables a Time of Day → Daily automation in Shortcuts; it calls the same reconciliation workflow. Begin with a native main-app action that obtains/creates the next bounded request from persisted job state. | Must be tested with the relevant Find Message and App Intent actions while locked/process-absent. No guarantee it always executes or finds all SMS. |
| Manual Sync/Retry | Runs or resumes the same account-bound date-range workflow, including a user-selected older repair range. | Does not bypass unresolved permission, source-indexing or acquisition limits. |

Apple documents [daily Time of Day triggers](https://support.apple.com/en-ie/guide/shortcuts/apd932ff833f/ios) and [automations capable of running without asking](https://support.apple.com/en-mide/guide/shortcuts/apd602971e63/ios). That supports an opt-in Shortcuts schedule; it is not a guarantee of unattended execution of every action in the recipe. Do not silently create a device personal automation or a Codex reminder as part of the app design review.

The main app cannot promise to wake at an exact daily time and launch Shortcuts indefinitely while closed. Apple's [background-task guidance](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) gives scheduling control to iOS. Background runtime, if provided, can help drain already-saved data; it must not be treated as permission to read Messages or as guaranteed daily acquisition.

Native actions used by the daily workflow need access to durable job state without depending on Flutter being active. Persist small-window progress from native receipts and let the shared drainer finalize processing when available. If automatic continuation is blocked, retain an explicit waiting/continue state rather than advance coverage. No new native financial parser is needed.

Coordinate onboarding/history, daily, app-open and manual requests with one serialized acquisition owner or lease. A duplicate trigger joins existing work or queues a single follow-up; it must not start a second simultaneous search. Keep live single-message saves responsive while a range job is active. Apply account ownership/generation checks to every action and callback.

## Duplicates and counting

Reuse the existing shared `smsSourceKey(account, sender, body)` and intake decisions. With equivalent source values and account scope, a live message fetched again by catch-up should reuse the existing financial record rather than create another spend. An overlap intentionally increases acquired/seen counts; it must not inflate newly created transaction counts.

Do not deduplicate on amount, merchant or transaction day alone. Do not substitute an inferred bank label or an arbitrary contact for the real source sender. If the live and history sender/body representations differ, the current key may differ too; acceptance tests must expose that rather than claim deduplication is guaranteed.

The current canonical source key excludes receive time. Consequently, truly separate messages with exactly the same normalized sender and body can collapse even on different days. This is an existing shared-policy limit, not a reason to add an iOS-only key. Test and document it; any policy change must be shared across Android, iPhone and backend contracts.

For new acquisition bookkeeping, use an account-bound receipt ID and, only with trustworthy original metadata, a source-occurrence fingerprint. Keep these separate from the financial key. Atomic uniqueness prevents duplicate concurrent claims. A previously committed occurrence can reuse its outcome; a pending/failed occurrence must be joined/retried rather than dropped. Preserve distinct occurrence evidence and gate any shared financial-identity migration before claiming that equal-text messages can never be lost. The implementation plan specifies these cases and version/retry handling.

For each interval show: messages returned, durably accepted, already seen, security/invalid/incomplete input, processed, newly retained/review/ignored, and pending retries. Keep raw-message counts distinct from financial transaction counts and network acknowledgements. A smaller transaction count does not by itself mean SMS acquisition failed.

## Device-test plan

Also test nonblocking use: startup displays cached data promptly; navigation/edits work throughout a large catch-up; the top strip has honest progress and does not cover controls; worker failure retains work without a large main-isolate fallback. An external acquisition requirement is a visible continuation state, not a mandatory repeated launch.

Do not ask the user to spend money to generate bank alerts. Use a harmless non-sensitive test SMS for delivery/lifecycle checks, then wait for a genuine bank alert to validate its header. The agent should not send messages or execute real history imports without the user's authorization.

| Test state/scenario | Evidence to record |
| --- | --- |
| App visible | Trigger/action start, received input, durable save where implemented, shared result. |
| App in background/suspended | Same evidence; record whether the app screen opened unexpectedly. |
| Process terminated without a user force-quit | Distinguish actual absence from merely leaving the app; confirm native handler and durable save, then open and drain. |
| User force-quits | Separate test: do not infer from a background or system-terminated test. Record OS error/interaction if any. |
| Phone locked after first unlock | Verify source metadata, storage access and quiet behaviour independently. |
| Reboot before first unlock | Record whether action/storage access is unavailable; never infer first-unlock behaviour from another state. |
| Successful live save, process stops, app reopens | Production spool survives; drainer creates/reuses one record. The current memory-only probe is expected not to establish this guarantee. |
| Live trigger deliberately misses a harmless test | A user-run date-range reconciliation finds it and captures it once through shared intake. |
| Three days without opening, daily checks disabled/missed | App-open catch-up plans the full interval since the last completed boundary, with overlap and no daily-gap truncation. Can be covered synthetically before a multi-day device trial. |
| Daily automation while app is not visible | Observe invocation and persisted receipts; opening the app later reconciles results. Failure does not advance coverage. |
| One SMS in live + daily + app-open + history overlap | One financial source under the existing key; acquisition attempts have separate receipts. |
| Cancel/fail/full storage/partial result | Boundary stays before unresolved coverage; retry resumes. |
| Crash around finish/ack, repeated callback | Receipt replay is safe and neither double-counts nor skips a window. |
| Account switch/reset, simultaneous triggers, timezone change | No cross-account handoff; one active acquisition; frozen intervals remain correct. |

User-reported background success is retained as an observation. No process termination, locking, real-message import or multi-day test was performed for this document review. Do not terminate the current probe automatically merely to investigate; that would clear its temporary evidence.

## Review conclusion

The ideas are complementary once consolidated. Keep live acquisition for prompt updates and use one durable reconciliation engine for both app-open and optional daily recovery, with initial monthly history as another range-job type. Persist completed receive-time coverage with overlap, reuse shared deduplication and keep unresolved gaps visible.

This reduces missed live handoffs but cannot guarantee zero missing messages: Shortcuts may not run, source messages may be deleted/unindexed, metadata can be absent and shared policy can intentionally exclude financial-looking messages. The correct promise is visible coverage, retry and reconciliation, not unconditional complete SMS access.
