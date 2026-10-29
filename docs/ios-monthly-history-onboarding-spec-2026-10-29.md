# iOS onboarding: import selected SMS history month by month

Status: main-app requirement and implementation specification, recorded 29 October 2026. The date-range prototype established selected historical handoffs, not an implemented monthly onboarding coordinator or exhaustive retrieval. This document extends the [main-app integration plan](ios-shortcuts-main-app-integration-plan-2026-10-29.md); it does not modify or run the user's shortcuts.

Updated 30 October: [ongoing live/catch-up reconciliation](ios-live-capture-reconciliation-review-2026-10-30.md) reuses this range-job protocol for app-open, optional daily and manual recovery. Keep the selected older-history ledger distinct from the ongoing reconciled-through boundary so a recent catch-up cannot hide an unfinished historical month.

The [implementation execution plan](ios-sms-intake-implementation-plan-2026-10-30.md) defines deduplication/replay gates and the nonblocking status UI. History processing must not block the ordinary app; source searches that require Shortcuts remain explicit continuation/foreground steps.

## User requirement

When a new iPhone user joins PandaPay, offer a choice of how far back to import SMS history, including at least the previous two years. Acquire that selected history one calendar month at a time through a reusable Shortcut launched by PandaPay. Feed every acquired message through the existing shared PandaPay intake and classification pipeline.

Do not replace the selected date interval with “latest 500 messages,” another fixed message-count cutoff, or a single two-year Find Message request. Internal batch/storage bounds are allowed for resource management; reaching them must be handled explicitly rather than silently truncating the import.

## Onboarding flow

1. After sign-in, show an iOS **Import SMS history** step. Explain that acquisition uses a user-installed Apple Shortcut and that available results depend on messages still accessible on the phone.
2. Offer **3 months**, **6 months**, **1 year**, **2 years**, **Custom dates**, and **Skip for now**. Two years is the proposed preselected choice; the user confirms the period before starting. Custom dates can extend earlier than two years where messages are available; two years is not a hard maximum.
3. Show the actual start/end dates and planned calendar windows before import. Freeze the selected interval and its timezone/cutoff when the user starts. A user who skips can start later from the SMS import screen; a returning user can extend a prior import with the same flow.
4. Check that the production history Shortcut and main-app actions are installed. Provide setup/repair instructions if they are absent. Do not begin a job bound to the prototype application.
5. Save an account-bound import job and its calendar windows before launching the first one. Process oldest to newest as a deterministic default. Order changes acquisition scheduling only; the shared financial algorithms remain unchanged.
6. Launch the same parameterized history Shortcut for one window. Supply its dates and attempt token, not a message limit or SMS content. The Shortcut obtains source messages for that window and hands them to main-app actions individually or through bounded transport batches.
7. After the window's durable handoff and processing receipts have been reconciled, save its result, return to PandaPay, and advance to the next window. Keep at most one history acquisition in flight.
8. Display calendar progress and per-window results. Support **Pause**, **Resume**, **Retry month**, and **Stop import**. Previously committed financial results are preserved when a job is paused or stopped; stopped attempts cannot continue mutating its acquisition state.
9. Summarize months examined, source messages found, successful handoffs, new/existing financial records, review items, intentionally ignored/security-excluded items, missing metadata and windows requiring attention. Label “selected range processed” separately from “all phone messages retrieved.”

Suggested progress text: **Importing September 2025 · window 12 of 25**. If a date window has been subdivided, report subwindow progress beneath that month. Window progress has a known denominator; the total number of SMS on the phone does not.

## Calendar boundaries and chosen period

Use the phone's calendar/timezone at job creation and save it with the job. Build windows from calendar components, not 30-day intervals or fixed 24-hour additions. Each window is start-inclusive and end-exclusive. Store the resulting instants as zoned/UTC values before invoking Shortcuts; preserve each source message's receive timestamp independently.

For a rolling preset, subtract the requested calendar months/years from the start date, clamping the day when needed (for example, leap day into a non-leap year). Freeze the upper cutoff at job start. For a custom last day, the selected end is the following local midnight, capped at that job-start cutoff. The current month can therefore be partial. Later messages belong to ongoing live capture or a subsequent reconciliation job; do not keep moving the active history job's end.

Example: a two-year selection started on **29 October 2026** begins on **29 October 2024** and ends at the chosen job-start cutoff today:

| Window | Receive-date interval |
| --- | --- |
| First partial month | 29 October 2024 through 1 November 2024, end exclusive |
| Middle months | November 2024 through September 2026, one full calendar month per window |
| Final partial month | 1 October 2026 through the frozen 29 October cutoff |

This rolling interval intersects **25 calendar months**, not necessarily exactly 24 windows. The UI must calculate the actual window count. A full-calendar-month preset, if later offered, must use a different label instead of quietly changing the meaning of “previous two years.”

Process every window in the chosen range even if a month returns zero messages. One or several empty months do not prove that earlier messages do not exist. Do not stop at the first gap, infer the phone's oldest SMS date, or silently reduce the user's selected period. Deleted/unavailable messages cannot be reconstructed by this import.

If the device timezone changes during an import, retain the persisted boundaries for the active job. Recomputing them in the new timezone could create gaps or overlaps. Tests must cover leap February, daylight-saving transitions, year changes, partial months and exact midnight boundaries.

## Main-app coordinator

The app owns the month queue. The reusable Shortcut executes a single supplied search interval per invocation. Do not create one installed Shortcut per month and do not require the user to edit dates 24 times. A saturated month may create smaller child intervals, but it remains one logical month in progress reporting.

Proposed components, not yet implemented:

| Component | Responsibility |
| --- | --- |
| iOS onboarding/import screen | Period presets and date picker, setup state, progress, pause/resume and per-month result/retry controls. |
| `IosHistoryImportCoordinator` | Serializes acquisition launches, validates completion, schedules retry/split windows and advances persisted progress. |
| Durable job/window repository | Stores account ownership, frozen dates, timezone, active attempt and window outcomes across process restarts. |
| Production history App Intents | Validate an issued request, expose search bounds, durably accept one message and finalize an attempt. |
| Existing production handoff drainer | Reads saved messages into `captureShortcutMessages` and its shared account-scoped capture owner; acknowledges committed results. |

Place the coordinator/service under `app/lib/features/sms_import/` and the durable job repository under `app/lib/data/local/`. Use the real main-app database, recovery fencing and account lifecycle; do not reuse the probe's disposable namespace or memory-only run list. The native request/receipt store must also survive a cold invocation without assuming Flutter is running.

Persist at least:

- Job: stable ID, account namespace and recovery generation, selected interval, timezone, cutoff, scheduling order, status and user pause/stop choice.
- Window: stable ID and month label, exact boundaries, parent/child relation for splits, status, active attempt, counters, acquisition-completeness status and failure/retry reason.
- Attempt: a newly issued ID/token, immutable bounds/account generation, issued/start/finish status, expected counts and durable message receipts. Keep enough receipt metadata to validate a delayed or repeated callback idempotently.

One window can have several attempts. Financial deduplication continues using the shared source key; job/window/attempt identifiers are acquisition bookkeeping, not new financial identity rules.

## Shortcut handoff and completion

Extend the production-bound range protocol to associate every action with the issued job, window and attempt. The existing `IosHistoryRangeRequest` supports one start/end request; it does not implement a durable month queue. Do not change its version-2 payload incompatibly: introduce an explicit production protocol version or a versioned wrapper and preserve the existing diagnostic workflow.

1. **Begin:** validate an app-issued attempt against persisted account ownership and exact bounds. Reject stale, stopped, unknown or mismatched requests without importing under another account.
2. **Search bounds:** return the issued dates. Any broad boundary query used to compensate for Shortcuts' comparison operators must still enforce the exact half-open interval on each received message.
3. **Find Message:** search only the supplied dates, with the user-visible Limit option off. Do not apply the live automation's space/letter filter to historical queries, or add bank/transaction keywords that preempt shared triage.
4. **Per-message handoff:** pass the same Message's full body, original sender and original receive Date together. Never use the search-bound date, Current Date, a body date, or independently reordered body/sender/date arrays as historical metadata.
5. **Durable receipts:** each acquisition attempt records an outcome for every enumerated item. Accepted items must be durably saved before returning a save acknowledgement. Count native validation/security rejections, source duplicates and out-of-window boundary results separately; do not persist security bodies to implement a receipt counter.
6. **Finish:** persist the search result count, final action state, declared Limit setting and any observable completeness warnings. Reconcile those values against item receipts. A success callback alone, a zero error count, or a successfully opened URL is insufficient.
7. **Drain:** pass eligible saved messages through the existing main-app intake. Record transactions/review/ignored/existing outcomes separately from acquisition counts. Shared intake may intentionally ignore a message; that is not a missing handoff.
8. **Advance:** once enumerated items reconcile and eligible messages have durable shared outcomes, commit the attempt result. Only fully reconciled windows without unresolved acquisition failures can be counted as done. Record source-query completeness separately; matching receipts cannot prove iOS returned the whole inbox.

Keep counters mutually exclusive at each stage so they can reconcile. A useful acquisition invariant is `enumerated items = durable accepted items + explicit validation/security rejections + source duplicates + out-of-window results`; also reconcile the reported Find count against enumerated items. A separate intake invariant covers accepted items as pending, processed or retryable. Missing metadata and capacity drops must leave an attention/partial result rather than an unqualified “all data imported.”

Apple documents [success, cancellation and error callbacks](https://support.apple.com/en-ca/guide/shortcuts/apdcd7f20a6f/ios). Use them to return control to PandaPay, then validate the persisted finish receipt; callback data is untrusted transport. Do not put raw SMS, sender details or credentials in launch/callback URLs. Repeated or delayed callbacks must not launch another concurrent window or double-count a completed one.

Automatically launch the next queued window only after returning to an eligible app state and confirming the previous attempt's result. If iOS requires a prompt or another user action, display **Continue import** at the saved window. Sequential automatic app/Shortcut transitions must be tested on the target iPhone; do not promise a fully unattended two-year background scan. URL callbacks are coordination, not a background execution entitlement.

## Interruptions, retries and large months

| Condition | Required behaviour |
| --- | --- |
| Process ends or phone restarts | Restore job/window state. Read durable receipts before retrying an uncertain in-flight attempt; never assume it completed or skip to the next month. |
| User cancels or permissions are denied | Save the interrupted state and show Resume/Retry/setup instructions. Do not advance by elapsed time. |
| Finish callback is missing or duplicated | Reconcile with persisted native finish/receipt state; apply it once. An unresolved attempt remains waiting/attention rather than silently successful. |
| A month has no results | Record an examined empty window and continue through the selected range. It is not proof of the oldest available message. |
| Find limit, suspected truncation or acquisition capacity reached | Mark the window incomplete and split it into smaller nonoverlapping date intervals. Keep the parent incomplete until its children reconcile. Never retain only the first 500/2,000 results and report the month complete. |
| Many messages share a boundary timestamp | Do not advance a cursor by guessing the next second or selecting the first result. Use verified stable paging if the source supports it; otherwise report an unresolved limit rather than lose equal-timestamp messages. |
| Storage full or durable write fails | Retain a retryable failure and stop scheduling more history. Do not drop unacknowledged items to make room. |
| Account switches, signs out or recovery/reset occurs | Stop launches, reject stale attempt tokens and keep/delete pending data according to the original account's lifecycle. Never attach it to the next user. |
| Offline | Permit local intake where acquisition is available; existing sync owns later network work. Upload failure alone does not require another message search. |
| Live SMS arrives during history | Accept through the shared durable live input path without waiting for the history job. Overlapping sources still use shared deduplication. |

Monthly windows reduce the size of each query; they do not prove unlimited results. Apple documents [Find/Filter ordering and limits](https://support.apple.com/en-lamr/guide/shortcuts/apdbdab3433f/ios), but a universal result ceiling or exhaustive enumeration is not established here. Compare a month with smaller subdivisions in device tests. A low result count alone does not establish completeness.

The prototype has an explicit 2,000-item range safety bound and a bounded pending queue. Those are implementation limits, not an onboarding product policy. Production needs durable, bounded draining and split/retry handling before claiming to import dense months.

## Shared processing and live coverage

All acquired candidates enter the same shared input contract and `SmsImportStore` path used by Android, with equivalent account cards/profile/rules and code version. The month coordinator does not classify transactions or bypass personal-number/security policy. “Found,” “saved,” “processed,” “new transactions,” and “synced” remain different counters.

History queries use original receive dates, independent of any older transaction date printed inside a resent SMS. The incoming-message live shortcut remains a separate acquisition route; a successful monthly import does not establish that its one-space trigger catches every future SMS. App-open and optional daily time-triggered recovery use the same persisted range-job owner with overlap and shared deduplication. Offer this date-range flow again for manual repair and extending history.

## Acceptance checks before release

- iOS onboarding presents two years and custom dates, shows exact selected boundaries, and can be skipped/resumed later.
- Two-year/custom imports produce the correct nonoverlapping calendar windows, including partial endpoints, leap dates and timezone changes. The rolling two-year example above produces 25 windows.
- Only one history attempt is active; completion, cancel, duplicate callback, timeout and resume never skip or double-start a month.
- No fixed “latest N SMS” limit substitutes for the selected dates; empty months do not stop earlier/later selected windows.
- A message at a month boundary belongs to exactly one window. A boundary-query superset is reconciled explicitly rather than counted as eligible history.
- Each source body/sender/original date remains associated; missing values and security exclusions are explicit results.
- Large-month split/retry covers the same parent interval without gaps; unresolved same-timestamp saturation stays visible.
- Pause, restart, interrupted finalization and crash-after-processing-before-ack resume idempotently from persisted job and input receipts.
- Real-device tests verify sequential launch/return, any permission prompts and a visible continuation when automatic progression is unavailable.
- Account/recovery changes cannot attribute old window data to another user; stopped jobs reject later attempt actions.
- Shared Android/iPhone intake produces equivalent decisions under equivalent input/state; ongoing live intake remains responsive during history work.
- The final summary distinguishes selected-window progress from verified source completeness, intentionally ignored SMS and later network sync.

## Delivery scope

This requirement is now part of the production iPhone integration plan. Implementation must add the onboarding UI, durable job repository/coordinator and production-bound Shortcut protocol; none are supplied merely by documenting the flow. Do not delete the current prototype or automatically run the user's real message history as part of writing this specification.
