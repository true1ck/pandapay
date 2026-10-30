# Repeated SMS history sharing permission

Status on 30 October 2026: **Finish retains permission by user confirmation; Capture permission remains unresolved, and the user reports an import regression after build 70**. The in-place person-type change is being reverted to the saved text contract. Unattended history import remains unqualified. Do not describe the large-data tutorial or a successful app installation as proof of permission retention or successful import.

## Evidence

- The user's screenshots show **Allow Sharing Large Amounts of Data** already enabled.
- The user selects **Always Allow**, but subsequent history runs show **Ask Each Time** again under the Shortcut's per-action Messages permissions. Both **Capture PandaPay Window SMS** and **Finish PandaPay SMS Window** are implicated by the Privacy screen.
- The prompts describe a previous allowance for one Messages item and a new request involving the search dates and many Messages. This establishes a change in the scope shown by Shortcuts; it does not establish why the saved choice is not retained.
- The user reports that the new recipe also resets when run directly in Shortcuts. Consequently, PandaPay's launch URL is not a necessary trigger. The older prototype recipe reportedly retains its permission.
- The user subsequently confirmed that Sender is unavailable in their picker and that removing Sender does **not** stop the repeated prompt. The sender-mapping observation below is separate from this permission failure; it must not be presented as its cause or as a required permission fix.
- The user reports that both main Capture and Finish Messages permissions still reset on each run after the explicit-input update. The working probe needs only its Find Messages permission in their observed setup. Record this as a negative result for the build-66 change, not as a successful privacy fix.
- After switching to **Finish PandaPay History Import** in build 68, the user explicitly confirmed: **Finish stays allowed; only Capture resets**. This validates that action's observed permission retention, not every background mode or the full history import.
- Apple's [Shortcuts privacy guide](https://support.apple.com/en-in/guide/shortcuts/apd961a4fc65/ios) says Always Allow should persist on subsequent runs. Large-data sharing is a separate setting. Repeating that setup instruction is not a diagnosis of this failure.

The current main recipe was exported through the Mac Shortcuts app and inspected without running it. The original installed recipe was not changed. It contains no prototype-bound actions. Historical prototype entries remain visible in the user's Privacy screenshot, but their presence alone does not prove that they cause the reset.

## Actual recipe comparison

The initial comparison used the reviewed source `artifacts/ios-history-range-v2/PANDAPAY SELECTED RANGE V2.wflow`. The later comparison exported the **actual synced PANDAPAY SELECTED RANGE V2** recipe through the supported Mac UI. It confirms the user's statement: **Sender is unassigned** in their working recipe. The saved generated source's sender-person mapping was not evidence of their installed mapping. Both actual recipes use text-token expressions for the request, body and date, so that serialization choice is not an established main/probe difference. Input values and message contents are intentionally omitted from this report.

| Connection | Reviewed prototype | Exported main recipe | Finding |
| --- | --- | --- | --- |
| Receiver | `app.pandapay.iosimportprobe` | `app.pandapay.pandapay` | A different app needs its own initial approval. This does not explain repeated approval after Always Allow. |
| Range start/end request | Explicit Shortcut Input | Explicit Shortcut Input | Both are explicitly bound. A missing Begin action is not the cause: Start/End already validate the issued request. |
| Find / Count / Repeat | Find results → Count Items and Repeat Each | Same action-output connections | Finish receives Count, rather than an accidentally selected Message collection. |
| Body | Repeat Item → `body` | Repeat Item → `body` | Correct field selection. |
| Sender | Unassigned in the actual synced recipe | Entire Repeat Item coerced to Text in the earlier export; user subsequently removed it | Whole-Message coercion is not sender extraction, but removing it did not resolve consent. Do not ask the user to select a property absent from their picker. |
| Original date | Repeat Item → `date`, text-token expression | Repeat Item → `date`, text-token expression | Same mapping/serialization in the actual exported recipes. |
| Item receipt identity | No per-index production receipt | Repeat Index | Required by the production receipt protocol. Its effect on Shortcuts' data provenance is unproven. Do not remove it to suppress prompts. |
| Finish count | Count output | Count output | Both preserve an independent Find count. Do not replace it with the number retained or parsed. |
| Finish foreground behavior | `openAppWhenRun = true` | `openAppWhenRun = false` | A real implementation difference; not established as the permission-reset cause. Live capture must remain able to run without foregrounding PandaPay. |
| Return to app | Plain `shortcuts://run-shortcut`; prototype Finish foregrounds the app | Official x-callback launch with a nonce-scoped return | Different transport, but the user's direct-run reproduction rules it out as a necessary condition. |
| Accepted Shortcut input | Text only | Broad default content types | Tighten to Text for this text request contract. No evidence yet that this alone fixes consent persistence. |

The main native bridge has no code to reset Shortcuts privacy. Its `configure(reset:)` operation revokes PandaPay's own acquisition generation; it does not read or write Shortcuts permissions. Capture and Finish return bounded status strings. The app ignores callback result/error text and obtains completion from committed native receipts.

## Native explicit-input revision

The compiled build-65 schema allowed Apple's default automatic previous-result connection for every parameter. The main actions now declare `inputConnectionBehavior: .never` for each input. Apple describes this setting as prohibiting an automatic connection to the previous App Intent result; see [InputConnectionBehavior](https://developer.apple.com/documentation/appintents/inputconnectionbehavior) and [never](https://developer.apple.com/documentation/appintents/inputconnectionbehavior/never).

This removes an ambiguity at the native boundary: an omitted optional input must not inherit an unrelated result. Request, Repeat Index, message fields and the independent Find count still require their explicit saved bindings. The default `limitOff = false` and `warning = false` remain intact. No action identifier, parameter identifier, input type, native receipt rule, storage policy or app-launch URL changes in this revision. It does not grant permission, read Shortcuts' private privacy database, strip provenance or bypass iOS consent.

This is a targeted boundary correction and diagnostic change, **not a confirmed explanation of the permission reset**. The exact installed recipe already explicitly binds several inputs, and the older prototype also used Apple's default behavior. Repeated device runs must establish whether the new declaration changes the observed prompt. The artifact verifier now rejects the old automatic-input metadata and checks the actual extracted schema for all seven main actions.

**Build 66 verification:** the signed main-app build succeeded. The artifact verifier confirmed `.never` for all 16 parameters across the seven actions; it had rejected the old build-65 schema as expected. The native synthetic harness passed durable capture, replay, account fencing, counts, receipts, restart and callback tests. Deep signature verification and `git diff --check` passed. Installation succeeded, and the device app list confirmed **Pandapay 1.0.15 (66)** alongside the unchanged prototype **1.0.0 (1)**. No Flutter implementation changed in this revision, so the previously passed full Flutter suite was not rerun. No installed recipe, Shortcut privacy entry or system permission was changed by the tools. Repeated-run permission retention remains a user-device test, not an installation result.

## Correction and controlled qualification

### Interactive completion comparison

The exact working probe's Finish has `openAppWhenRun = true`; the main Finish has been background-only. A new **Finish PandaPay History Import** action mirrors that foreground completion behavior while calling the **same production `IncomingSmsSpool.finish`** implementation with the same request/count/Limit-off/warning contract. It preserves all count, receipt, partial-window, deduplication and account checks. Capture remains in the background. The existing **Finish PandaPay SMS Window** action remains unchanged for existing background recipes, so a scheduled automation does not unexpectedly open PandaPay.

This is a controlled comparison of a verified implementation difference, **not proof that foregrounding causes the privacy failure or that the failure is fixed**. It requires one action replacement in an interactive recipe, plus reconnecting Stop and Output:

| Existing interactive recipe | Comparison revision |
| --- | --- |
| Finish PandaPay SMS Window | **Finish PandaPay History Import** |
| Import request | Original Shortcut Input / saved Import request |
| Messages found | The existing Count output |
| Find Messages limit is off | Yes, after verifying Find has Limit off |
| Search may be incomplete | Preserve the existing setting |
| Stop and Output | Output of **Finish PandaPay History Import** |

No Capture, Repeat Index, body/date or sender edit is part of this consent comparison. The working prototype remains unchanged. Existing background recipes keep the quiet Finish. A future background history copy must also use the quiet Finish; app-started interactive history uses the new action.

Automatic progression now requires both committed native completion **and the matching successful Shortcut return**, cached for the current attempt until the app is foregrounded. This prevents a foreground Finish from launching the next month before the current Shortcut reaches Stop and Output. A stale return from the prior month cannot advance the new attempt.

The native synthetic intake/callback harness and **19** focused import/controller/widget tests passed, including a new regression for the foreground-Finish sequencing race. Analysis of both changed Flutter files reported no issues. Signed main-app **1.0.15 (68)** built successfully and passed the compiled-schema verifier: seven quiet actions, one foreground Finish, identical inputs/results on both Finish variants, and the Face ID configuration retained. Deep signature verification passed. Device installation succeeded and app-list read-back confirmed main build **68**, with the separate prototype unchanged at **1.0.0 (1)**. No real-message import, recipe replacement or permission selection was performed by the tools. Repeated runs on the phone are still required before marking permission retention resolved.

### Interactive Capture follow-up

The probe's Capture is already background-only, so there is no equivalent foreground difference to claim as a confirmed Capture root cause. Following the user's positive Finish result, the main app adds **Capture PandaPay History SMS** for interactive history. It uses foreground execution and **exactly the same input types, identifiers, defaults, output type and `IncomingSmsSpool.capture` call as Capture PandaPay Window SMS**. The action identifier is new. A successful device result would establish that this variant works; it would not independently distinguish execution mode from fresh action/recipe metadata as the underlying reason.

Replace **Capture PandaPay Window SMS** inside Repeat with **Capture PandaPay History SMS**, preserving these bindings:

| Field | Source |
| --- | --- |
| Import request | Original Shortcut Input / saved Import request |
| Repeat index | Repeat Index |
| Message body | The working Repeat Item → Body/Content variable |
| Sender (text) | Preserve the current value; leave unassigned if unavailable |
| Original Message Date | The working Repeat Item → Date variable |

Keep the confirmed **Finish PandaPay History Import** and its Stop and Output binding. This Capture intentionally returns PandaPay to the foreground during an interactive import. Do not use it in a quiet daily automation. **Capture Incoming SMS in PandaPay**, the existing background **Capture PandaPay Window SMS**, and the background Finish remain unchanged. No sender inference, receipt/index rule, deduplication, account ownership or stored data changes are made.

The progression regression test now also covers Capture's foreground/ready events while Repeat is still running: pending inputs may drain normally, but the next date window cannot launch until Finish commits and the matching Shortcut return arrives. Capture permission retention still needs two consecutive phone runs with the revised recipe/build unchanged between them.

Twenty focused import/controller/widget tests and the native intake/callback harness passed. Analysis of the changed Flutter screen reported no issues. Signed **1.0.15 (69)** built successfully. The compiled-app verifier confirmed all nine actions, exactly two foreground interactive variants, identical inputs/results for each interactive/background pair, updated help text and retained Face ID configuration. The text verifier handles Dart's UTF-8 and UTF-16 compiled strings. Deep signature verification and `git diff --check` passed. Device installation succeeded and the app-list read-back confirmed main build **69** with the prototype unchanged at **1.0.0 (1)**. No recipe or privacy entry was changed by the tools. The user-confirmed Finish result remains the baseline; Capture's repeated-run permission retention and full-window completion remain separate device checks.

### Negative Capture result and app-side receiver port

The user's 10:01 PM screenshot and report confirm that **Capture PandaPay History SMS still resets Messages to Ask Each Time** after the foreground change, while Finish is absent from the failing permission entries. Foreground execution did not resolve Capture. The user specifically identifies the working probe action as **Import PandaPay Range Message** (`CaptureDeviceHistoryRangeMessageIntent`).

The main recipe was exported again through the supported Mac UI without running or editing it. The current export uses the intended **CapturePandaPayHistoryMessageIntent** and **FinishPandaPayHistoryImportIntent**, with a single Capture inside Repeat. Body and original Date are the correct Repeat Item properties. Sender now selects the actual Message `author` property, not the earlier whole-Message-to-Text coercion. Repeat Index is explicitly bound. This verifies that the requested main actions are present; do not attribute this failure to the user's action selection or ask them to reset privacy again.

The existing main **CapturePandaPayHistoryMessageIntent** is now changed **in place**, keeping its identifier and the existing request/body/sender/date parameter identifiers:

| Native field/behavior | Working probe | Revised main History Capture |
| --- | --- | --- |
| Request | Required String | Required String, with main generation/attempt validation |
| Body | Required String | Required String |
| Sender | Optional IntentPerson, emailOrPhone mode | Same optional person mode; existing `sender` parameter ID retained |
| Original receive date | Optional Date | Optional Date |
| Repeat Index | Absent | **Absent from the exported action schema** |
| Automatic input connection | Apple's default | Same default |
| Foreground | No | No |
| Sender conversion | Prefer actual handle, then supplied name | Same extraction in tested `SmsHistorySender`; unknown/future types remain missing |

This ports the individual-message acquisition contract rather than adding another action or changing a Shortcut privacy setting. The request remains the main app's issued v3 request; no prototype token or storage is reused. The live and legacy Window Capture APIs keep their optional text inputs and existing indexed behavior. The confirmed interactive Finish stays unchanged.

With no shortcut-supplied index, the main store derives a receipt ID from its existing validated sender/body/original-date binding. Reordered/repeated deliveries reuse that receipt. The receipt is still scoped to the issued attempt and account. The independent Find count is retained: if Find contains indistinguishable rows that collapse to one identity, the window remains **partial**, rather than claiming complete coverage. This does not change PandaPay's shared financial source key or solve its separately documented identical-text transaction ambiguity.

Sensitive/invalid inputs never contribute a body digest to this scheme; they get an opaque random receipt, and existing security/validation decisions still apply. A direct synthetic SQLite audit checks that security-excluded receipts have a null binding and no stored body/hash. Missing senders are not replaced with invented bank headers. Native acknowledgement still waits for committed shared processing; no schema migration or account-reset operation is introduced.

Tests cover content-receipt replay and reordered retries, distinct dates/senders, count mismatch/partial safety, redaction, account fencing, and bank/phone/email person handles. The 20 focused Flutter import/controller tests also passed; analysis of the changed screen reported no issues. Signed-build and installation evidence are recorded after verification. The existing shortcut should use the updated receiver definition after installation; stale OS action metadata remains a device qualification issue, not a reason to claim that raw saved recipe parameters have already been rewritten by the app.

The collection-wide Repeat Index and the previous text sender/optional-body parameter types were real app-side differences. This revision removes those differences at the receiver boundary. It is **not yet proof of the exact iOS permission-reset mechanism or of retained permission**; repeated device runs of the updated receiver remain required.

**Build 70:** signed **1.0.15 (70)** built and installed successfully; app-list read-back confirmed build 70 and the separate probe unchanged at **1.0.0 (1)**. The compiled verifier confirms the four fields, absent Repeat Index, required body, optional `IntentPerson` in `emailOrPhone` mode, optional Date, the probe's default connection behavior and background execution. The existing History Capture action identifier and the remaining four parameter IDs are preserved. Deep signature verification, project-plist validation and `git diff --check` passed. Native tests passed replay/count/account/security checks plus person conversion; 20 focused Flutter tests passed. No recipe or privacy choice was modified by the tools. The first qualification step is to resume the existing app-issued import with the updated receiver; do not require another action replacement or privacy reset in advance of that result.

### Build-70 import regression and compatibility restoration

The user reports no import and **no visible Shortcuts error**. A read-only diagnostic copy of the main app's acquisition database passed integrity checking. Only aggregate metadata was printed: 188 earlier captures are committed (41 captured, 134 ignored, 13 review); the active catch-up attempt has zero Capture receipts and no Finish count. All existing receipts use the legacy index scheme, so no build-70 message-identity receipt is recorded. This does **not** prove that no handler was entered: a pre-handler conversion failure, launch failure or an early validation/transaction failure could all leave no receipt. Do not claim an observed Text-to-Contact error; the user explicitly saw no error. The raw diagnostic copy was removed after retaining a restricted aggregate summary.

Changing the existing `sender` field from optional text to `IntentPerson`, and making body required, was not a safe in-place migration of a saved main-app action. Matching a separately created probe's parameter types does not make existing main-app bindings equivalent. The receiver now restores optional text body/sender, optional Date and explicit-only connections under the same field/action identifiers. The native message-receipt path remains, so there is still no mandatory Repeat Index. The unused person converter and its project/harness entries are removed. Existing live/legacy inputs and the confirmed Finish remain unchanged.

A small persisted trace now distinguishes successfully recorded Start, End, Capture and Finish actions for the current attempt. Launch-side boundary validation cannot claim that Shortcuts executed: only actual Start/End intents opt in. Capture/Finish record their stages inside their existing validated transaction, without body, sender or date content. A new attempt does not inherit the earlier trace, and the diagnostic attempt setting is excluded from snapshot output. The app shows the last recorded action only under **Import options → Import details**. Failed validation before recording still cannot be observed as a successful action; the trace is not a complete OS execution log.

Native tests passed invocation-vs-validation separation, attempt scoping, replay, count mismatches, sensitive redaction and account fencing. Twenty-one focused Flutter tests passed, including the hidden action trace and existing editing/navigation behavior; analysis reported no issues in the changed screen. Build and installation results are recorded after completion. Physical import recovery and retained Capture permission remain device checks.

**Build 71:** signed **1.0.15 (71)** passed the compiled verifier, including optional String body/sender, unchanged Date type, absent Repeat Index, no person/contact resolution metadata, action-trace UI and retained Face ID support. Deep signature verification passed. Installation succeeded and device app-list read-back confirmed build 71 with the probe unchanged at **1.0.0 (1)**. No Shortcut edits or privacy resets were performed. The user has been asked to resume once so the new on-device trace can be inspected; recovery is not claimed from the install result alone.

**Migration rule:** saved App Intent parameter names **and types** are a compatibility contract. A different sender representation must use a separately versioned/opt-in receiver rather than changing an existing text field in place. Unit tests of a person-to-text helper do not validate Shortcuts' saved-variable resolution.

### Device retry after build 71 and history navigation

A subsequent read-only acquisition-database check passed integrity checking and now shows the active attempt at **Finish**: **79 found / 79 receipts**, comprising **30 saved for processing, 12 already saved and 37 missing sender**. The pipeline has 218 committed captures in total, compared with 188 before this run. Thus the compatible receiver imported this run; the entire attempt did not disappear. The date window remains **partial**, with the next date window queued, because missing sender is an acquisition failure rather than a successful classification. No raw input was printed or retained in the local diagnostic copy.

Capture permission persistence is still unconfirmed. The user thinks it may have worked and instead reports being unable to select previous dates from the main app after onboarding. Do not treat that answer as a repeated-run permission-retention confirmation.

Both onboarding and Import & Sync already route to `IosSmsImportScreen`. Its `activeJob` branch, however, replaced the history selector with Resume progress for any active catch-up/history job. An incomplete catch-up therefore hid all previous-date choices. The screen now keeps the history selector available and offers **Start new import** when a check exists. Replacement is an explicit, account/job-scoped native transaction: the old job stops only if the selected history job is created successfully; saved captures/receipts remain, old request callbacks become stale, and partial dates are not falsely marked complete. Back navigation itself does not stop a job or launch a shortcut. Missing-sender counts are shown on the partial-progress card instead of suggesting that splitting dates will repair absent metadata. The Capture/Finish App Intent parameter contracts are unchanged by this UI repair.

A fresh supported export after build 71 still serializes `itemIndex` inside the saved History Capture action, even though the installed app's published action schema no longer declares it. The Finish parameters are request/found/limitOff. This confirms that removing an app parameter does **not** rewrite the saved recipe. The stale collection-derived field is a remaining comparison variable; its presence is not proof of the permission-reset cause. No installed recipe was edited, run or privacy-reset by the tools. A clean-copy comparison without that obsolete field remains a possible qualification step after the current history-screen issue, rather than another unverified app-schema change.

**Build 72:** signed 1.0.15 (72) passed native tests, 25 focused Flutter tests, targeted analysis, compiled UI/schema verification and signature checks, then was installed and confirmed by device app-list read-back. History choices remain accessible during unfinished jobs. This is a UI/job-replacement repair; it makes no new claim about Capture privacy persistence.

### Zero-processing history attempt: 31 October follow-up

The user reports a very fast three-month run and zero processed/saved counters. A fresh read-only acquisition check shows **19 found, 19 receipts, Finish reached**, with **18 `missing_sender` rejections and one security exclusion** in the first calendar window. The remaining calendar windows are queued. Thus the app's strict missing-sender rejection is the observed cause of zero processing in this attempt; it is not proof that Find or Capture did not run. The empty sender may have several source/conversion causes, and the main app must not hide valid input while that is investigated.

The next implementation retains a valid non-sensitive body and original date even when sender is absent. The sender remains the empty string with `senderEvidence=missing`, rather than a fabricated bank header. Such a row has no verified cross-attempt source-occurrence fingerprint. Its per-attempt content receipt only makes replay/reordering idempotent and is not promoted to evidence of an original sender. The existing shared normalized sender/body key still deduplicates processing/review; repeated-text occurrence ambiguity remains explicit.

The same `SmsImportStore` branch is used by Android and iOS: the existing shared triage still excludes security/promotion/unrelated messages. A financial candidate with an unknown sender creates a durable **local Needs Review item** and a committed review decision, with no provisional transaction, account/card changes or automatic upload/AI request. Review reads cannot silently auto-file that acquisition review. Its card says **Sender unavailable**, displays the full retained text, and explains the missing metadata. Capture worker commit notifications refresh Needs Review. Same-source replay does not add another item; distinct source identities and eventual user-reviewed financial effects still use PandaPay's existing contracts.

Only committed shared processing/review permits native acknowledgement. A missing-sender review is successful acquisition and can complete the date window when independent counts match; the old `missing_sender` rejection receipts remain partial and require a fresh Resume attempt. Missing dates, invalid bodies, out-of-range items, security exclusions and capacity/account fences retain their existing treatment. The UI now displays received, processed and review counts, with detailed duplicate/security/ignore counts behind Import details. The published Capture/Finish action identifiers and parameter types do not change, and no Shortcut edit or privacy reset is required for this repair. Real import recovery and repeated-run Capture consent remain device checks, not conclusions from synthetic tests.

Validation for this revision: **2,360 Flutter tests passed**, including the real capture owner → shared intake/API test, unknown-sender local review through the separate capture worker, review-card labeling and repeated reads/replay, history replacement/back navigation, and acquisition counters. Native tests passed unknown-sender retention, same-attempt replay, security exclusion, committed-review completion and existing date/account/count/restart checks. Targeted analysis reported no issues. No production SMS contents were used in these tests. Signed-build/install and fresh device-run evidence are recorded after completion.

**Build 73:** signed 1.0.15 (73) passed compiled-main-app/schema verification and deep signature checking. The first install disconnected; after successful reconnection, the second install completed and device app-list read-back confirms **Pandapay 1.0.15 (73)** while the separate probe remains **1.0.0 (1)**. No saved Shortcut or OS permission was modified by the tools. A fresh user Resume has been requested to inspect actual receipts/counters. The import and Capture permission are not marked physically qualified from this installation alone.

For recipes whose Message picker actually exposes these properties, the intended explicit mappings are below. The user reports that Sender is not available, so do not instruct them to select a nonexistent option or make sender repair a prerequisite to testing consent retention. Preserve the working prototype and the existing main recipe:

| Capture PandaPay Window SMS field | Explicit source |
| --- | --- |
| Import request | Original Shortcut Input, saved unchanged before Find/Repeat |
| Repeat index | Repeat Index, as Number |
| Message body | Repeat Item → Message → Content/Body |
| Sender (text) | Repeat Item → Message → Sender, then Text if conversion is required |
| Original Message Date | Repeat Item → Message → Date |

If the variable picker does not offer Sender, leave it unassigned during permission diagnosis. Do not substitute the whole Message as sender or invent a bank header. The production missing-sender validation is separate and can leave a history window partial; the prototype's inference behavior is not production sender evidence.

Use the same bounded source range and an app-issued active request for each comparison. A request-less manual run can fail validation and is not a successful import test. Keep the recipe/build unchanged between repeated runs so edits, new app identities or reinstallations cannot confound permission persistence.

1. Test the explicit-input native revision against the existing recipe without changing its mappings or resetting its privacy. Qualify count/validation outcomes separately from consent persistence.
2. If Always Allow still resets, retain that negative result and investigate the remaining action/schema differences. Recreating actions in a clean, separately named recipe can test retained metadata only if needed; it is not an established fix or a demand that the user rebuild a correct recipe repeatedly.
3. Compare repeated direct runs with repeated app-started runs. Record which action requests consent and whether its Privacy entry actually changes. Do not log messages, contacts or request tokens.
4. Only after a specific change retains permission across repeated runs, verify a second calendar window, cancellation/resume and the daily recipe. Preserve Count/Repeat Index, partial-window detection, account fencing and deduplication throughout.

Reports of similar symptoms exist on [Apple Developer Forums](https://developer.apple.com/forums/thread/747564), including changing counts in entity Repeat loops. This is a developer report without an Apple diagnosis; it is not proof of the cause here. Do not label the issue an Apple bug or a fixed PandaPay bug without the controlled device result.

The iPhone editor is not currently available to automation: iPhone Mirroring reports **iPhone in Use**. The Mac editor cannot resolve the iOS-only main-app actions. No permission choice, recipe replacement or real-message test was performed by the tools during this investigation.
