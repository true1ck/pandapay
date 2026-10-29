# Dynamic date-window Shortcut for iPhone SMS history

Status: design for a separate prototype; monthly automation and complete history coverage have not yet been verified on the device. Scope is iPhone acquisition and the existing PandaPay SMS processing path. No backend changes are required for the proposed design.

## Current Shortcut baseline screenshots

The following original screenshots were supplied by the user on 28 October as a record of the current flow. They are local workspace files and may contain message-preview content. They show the configuration at that moment; successful execution and complete metadata should be verified independently.

- [Live notification automation](../artifacts/ios-shortcuts-baseline-2026-10-28/01-live-notification-automation.png)
- [Single-message action](../artifacts/ios-shortcuts-baseline-2026-10-28/02-single-message-action.png)
- [History search and batch action](../artifacts/ios-shortcuts-baseline-2026-10-28/03-history-action.png)

## User experience

The prototype offers an **Import past messages** button and date selection, including convenient one-year and two-year ranges. It launches one installed **PandaPay History by Date** Shortcut, passing the selected start and end dates as input. The user grants any permission Shortcuts requests. The Shortcut searches each calendar month intersecting the requested range, reports the count for each window, and passes messages and their available metadata to the isolated diagnostic. The user sees any window whose results may be incomplete. The live-message automation and existing history probe remain separate.

Example: choosing 15 January through 10 April produces four search windows: 15 January–31 January, February, March, and 1 April–10 April. Calendar boundaries use the iPhone's local timezone. Internally use a start-inclusive, end-exclusive range, ending at local midnight after the final selected day. Avoid assuming every day has exactly 24 hours.

## Shortcut actions and control flow

The following is a build specification, not a claim that all actions and property conversions have been verified on every iOS version.

1. Receive the date range from the prototype through **Shortcut Input**. Parse and validate the two dates into `RequestedStart` and `RequestedLastDay`. For independent Shortcut testing, use **Ask for Input → Date** when the input is absent. Reject invalid input rather than silently selecting another range.
2. Reject a range where the first day is after the final day. Convert both choices to local calendar-day boundaries; set `RequestedEndExclusive` to the start of the day after the final day using a calendar-day adjustment.
3. Set `WindowStart` to `RequestedStart`. For each iteration, calculate the start of the next calendar month using local calendar components, then set `WindowEnd` to the earlier of that boundary and `RequestedEndExclusive`. This handles partial first and last months.
4. Use **Find Message** with both date filters configured so the selected set corresponds to `WindowStart ≤ message date < WindowEnd`. Verify the actual Shortcuts filter operators and boundary precision on the target iPhone; compensate only after testing. Do not apply a `Body contains debited` filter if the user requested all message bodies for the range.
5. Count found Message objects. Record only window boundaries, count, and test outcome; never log raw SMS bodies or sender details. Check the configured action limit and any observed platform result ceiling. If the count reaches a known limit or completeness cannot be established, mark the window **possibly incomplete** and split it into shorter nonoverlapping calendar windows for another pass. Even a count below a chosen threshold does not prove full indexing or complete device history.
6. For a test import, iterate over each found Message as an individual item. Extract that item's **Body**, **Sender** and **Date** independently and pass them together to an app action. Do not assume separately converted arrays preserve ordering or length. Avoid including unrelated or sensitive messages in diagnostic logs; keep the existing OTP/security filtering.
7. Advance `WindowStart` to `WindowEnd` and continue until reaching `RequestedEndExclusive`. Show a summary of windows examined, results found, successfully handed off, sensitive messages excluded, incomplete metadata and windows needing another pass. Do not present the found count as the total number of SMS on the phone.

Implement iteration with Shortcuts' available repeat/list actions after checking the actual editor. A queue of date windows is preferable to assuming a fixed number of months. If even the smallest practical window reaches a ceiling and there is no verified stable message identifier/offset, report that window as unresolved; silently moving the date boundary could miss messages sharing a timestamp.

## Prototype launch and return

- The prototype formats the two dates as a small versioned text payload and opens the installed Shortcut using Apple's documented Shortcuts URL scheme. Use a unique agreed Shortcut name, encode the input, and test that the two dates reach the Shortcut unchanged. No SMS content, sender, or account credentials belong in the launch URL or callback.
- Use the documented success, cancellation and error callbacks to return to the prototype where available. The callback reports execution status, not proof that all messages were imported. Keep message bodies and their metadata in the existing app-action handoff rather than a URL.
- Show a clear setup path if the Shortcut has not been installed, and distinguish launching, completed, cancelled, failed and incomplete results. Test actual foreground transitions, permissions and behavior if the app or Shortcut is interrupted; do not assume an unattended background run.
- Keep the prototype and the existing Android downstream intake aligned; this plan does not call for changes to backend APIs. Do not claim full Android parity until the original metadata, parsing, deduplication and account-scoped handoff are verified on the phone.
- Apple references: [run a Shortcut from another app](https://support.apple.com/en-lamr/guide/shortcuts/apd624386f42/ios) and [completion, cancellation and error callbacks](https://support.apple.com/en-nz/guide/shortcuts/apdcd7f20a6f/9.0/ios/26).

## What needs to be added to the current prototype

1. **Prototype date selection and launch:** Add an import button, start and end date controls, one-year and two-year presets, validation, and the encoded Shortcut launch. Provide an installation/setup path and show cancellation and error states.
2. **One reusable history Shortcut:** Duplicate the existing history probe, accept and parse both input dates, and add a fallback date prompt for standalone testing. Add local-calendar month boundaries and a loop over all intersecting windows.
3. **Dynamic Find Message filters:** Bind each window's start and end to its date filters and test the actual comparison operators on the phone. Sort consistently, count each result set, and investigate any possible result ceiling by splitting the window further.
4. **Per-message handoff:** Within each result set, obtain the same message's body, sender and original receive date, and pass the three together into the existing prototype action. Test how the installed Shortcuts version exposes sender and date, including unavailable values. A date used to search must not be substituted for the actual receive date.
5. **Progress and honest results:** Report per-window counts, rejected or missing metadata, failures, and potentially incomplete windows. Repeated windows must use the existing deduplication behavior after it is verified. Do not mark a date window complete based on a callback or a count alone.
6. **Prototype reliability and parity:** Correct or isolate the known fallback and source-body mismatch issues, then verify the shared Android processing path and existing account-scoped handoff. Test user permissions, interruption, retry and duplicate imports before extending beyond the isolated diagnostic.

These are implementation tasks, not completed features. The per-message metadata mapping, dynamic message filters and long-range completeness are device-test requirements.

## Why filtering by date and receiving a date are separate

- On the physical device, a **Find Message** date filter found bodies older than a selected cutoff. That does not mean the Message's individual Date property reached the app.
- A previous **single-message** action passed one original receive timestamp. The later bulk run supplied no original dates for its accepted inputs and used a capture-time fallback.
- A monthly search must therefore be verified using the date property for **each** Message. Extracting dates visible inside the SMS body may help identify transaction dates but does not prove the original SMS receive time.
- Sender conversion was also incomplete in the bulk run. Do not represent an inferred bank name as the verified SMS sender. Compare against the source, and mark missing metadata explicitly.

The existing prototype currently substitutes fallback times and guessed senders; it also has an unsafe source-body display fallback and a 2,000-item action cap. Correct or isolate these issues before treating new results as complete production imports. The temporary diagnostic database and native handoff do not survive process termination.

## Device verification sequence

1. Duplicate an existing history probe or create a fresh test Shortcut. Keep personal automations intact. Start with a **count-only** date-window search and no app handoff.
2. Search two known, disjoint older date windows. Confirm the count and compare a small number of results privately on the phone. Do not record real message contents in the repository.
3. Check exact-boundary samples and an empty window. Check partial months, leap February, month/year transitions, local timezone and daylight-saving transitions where applicable.
4. Compare a monthly search with smaller subdivisions of that same month. Investigate saturated windows and any unexplained count differences; neither count alone proves total inbox completeness.
5. Test one message through the app with Body, actual sender and Date. Verify the timestamp is the original receive time, not the transaction date parsed from the message or the time of import.
6. Test several messages individually through the same Shortcut loop, preserving association among body, sender and date. Then repeat one completed window and inspect the existing shared deduplication behavior and counts.
7. Only after the handoff is accurate, connect bounded batches to the existing account-scoped capture owner, existing parser, review records and upload queues. Test offline, retry, process termination and account changes before enabling production use.
8. From the prototype button, run a short range and verify the Shortcut receives both dates; exercise successful completion, cancellation, denied permission, missing Shortcut and interrupted execution. Then test one-year and two-year ranges with progress, retries and incomplete-window reporting. Do not declare full coverage merely because a run completed.

## Current state

- The prototype can display parsed results from old message bodies and uses the shared capture store in an isolated test app.
- The device has not established that 500 is a universal iOS limit or that a monthly scan reaches all historical messages.
- The total number of messages on the iPhone is not known from the observed 500-result run.
- A user can pick a date range in the proposed prototype. Launch from the app and monthly subdivision are planned, but are not yet assembled or verified end to end.

Evidence: [physical-device history probe](ios-physical-history-probe-2026-10-26.md), [shared-intake prototype](ios-shortcuts-shared-intake-2026-10-27.md), and [Apple's guide to filtering, sorting and limiting Find actions](https://support.apple.com/en-gb/guide/shortcuts/apdbdab3433f/ios).
