# Sender capture lab — isolated prototype

**Correction about receiver labels:** `origin: live` is assigned by the original single-message receiver, regardless of which shortcut called it. That receiver may also be used inside a Find Messages loop. A screenshot of that field alone cannot establish the acquisition trigger. Earlier statements below treating it as proof of an incoming-only test were too strong. The actual captured sender headers remain valid evidence for that receiver. The new isolated comparison uses the same source variables with two receiver contracts instead.

During the isolated investigation, the user requested moving investigation back to **PandaPay History Probe**, keeping the main app unchanged. Main **1.0.15 (80)** remained unchanged during that investigation. The new diagnostic targets only **app.pandapay.iosimportprobe**, version **1.0.0 (4)**, built from `lib/main_ios_history_device_probe.dart` in the disposable wrapper `/tmp/pandapay-ios-device-probe` and a separate derived-data directory. Main receiver, intake controller/store, input adapter and project files were recorded by content hash before this work; they remain unchanged during the prototype work.

## Current test: text-only receiver

The next screenshot shows **Import PandaPay Range Message failed because Shortcuts couldn't convert from Message to Contact, Phone Number, or Email Address**. This is failure before `perform()`; its Person input can block both text diagnostics in the same action. The visible `Repeat Item` chip versus `Sender` chip does not by itself establish which aggrandizements were saved. Do not infer the hidden picker configuration from its label or claim this is a missing sender recorded by the app.

Build 4 adds a **separate** receiver, **Import PandaPay Range Message as Text**, with no Person input. The original action's Person field and ID/type stay intact for comparison; its failed input is not changed in place. Replace only the per-message action inside **PANDAPAY SENDER CHECK**, retaining the original **PANDAPAY SELECTED RANGE V2** shortcut and main app.

| New text-only field | Mapping |
| --- | --- |
| Range request | Keep Shortcut Input / original range request. |
| Message body | Repeat Item → type Message → Body/Content. |
| Sender as text | Repeat Item → type Message → Sender. |
| Sender type (diagnostic) | **Empty for the first test.** Only bind a Get Type result later. The screenshot's Sender variable in this field is not a type report. |
| Original receive date | Repeat Item → type Message → Date. |

Keep search/count/Finish/Stop and Output unchanged. All text-only receiver fields explicitly avoid connection to the previous action's whole output. It uses the same native range checks, memory inbox, security filtering and comparison screen. Raw JSON includes `receiver: text_only`, distinguishes omitted and empty text, and labels Person as unavailable on that action. The existing action reports `receiver: person_and_text`. This is receiver-entry evidence; it does not reveal an object Shortcuts already discarded before the call.

Run one known receive day from the probe and inspect the top comparison card. A text value matching the visible sender is source evidence; a guessed `VM-…` value appears only in the separate inference comparison. If received text is empty, that is a negative result for this route, not grounds to substitute a guessed bank header. No new claim of sender recovery is made until this test is observed.

**Build-4 checks:** all **27 focused Flutter tests** passed, including text-only raw receiver identification, preservation of an actual text header and separate inferred header. The native history/live harnesses passed; targeted analysis reports no issues. The signed **1.0.0 (4)** artifact passed the compiled verifier: the new action contains exactly request/body/senderText/senderType/receivedAt, optional sender text, no Person parameter, no contact-specific metadata and explicit-only connections. The original Person action's schema remains intact. Deep signature verification and main-source content-hash checks passed. Device installation/read-back and the actual text result are separate qualification evidence below.

Installation succeeded, and device app-list read-back confirms **PandaPay History Probe 1.0.0 (4)** alongside unchanged main **Pandapay 1.0.15 (80)**. The text-only action is installed; the iPhone test-copy action replacement and a real sender value remain unverified. No installed Shortcut was changed during this follow-up, and no real SMS search or permission grant was executed by the tools.

**Next build-4 screenshot:** the displayed latest range has **164 accepted**, **160 missing sender**, **0 handle / 0 name only / 4 text**, with seven security exclusions. The cumulative session shows 468 accepted handoffs and 457 missing senders. This confirms sender capture remains unresolved for most tested historical messages. It is not a successful result simply because the body/date and review pipeline ran. The screenshot is scrolled to summaries and cumulative retained SMS; it does not show the fresh raw `receiver`, `sender_text`, `sender_shortcuts_type` or `sender_person` values. Cumulative source cards preserve the first stored source/evidence for a canonical key, so a `missing_person` label on one cannot establish which receiver handled the latest repeat run. No claim is made that the user chose the wrong action.

The text-only handler forwards the optional text it receives directly into native range capture; the native range inbox preserves its sender string with the same record. The shared adapter uses a nonempty text/handle sender without inference. A primary Person conversion failure can still prevent entry into the old receiver, as the earlier screenshot showed. These code facts locate what needs to be observed; they do not establish whether missing history senders arise in the saved binding, source Message property, OS conversion, or another route. The user has been asked only for the fresh raw sender fields, omitting the body and masking addresses. No speculative rebuild or main-app change is made from the summary counters alone.

**Working live baseline, 1 November:** the next three screenshots show `origin: live`, `receiver: existing_single_message`, nonempty matching raw text/native sender, `native_sender_evidence: text`, and `senderInferred: false` in the direct output. The actual header is an SBI Card sender ID; no message body, card suffix, reference, source hash or full transaction JSON is copied into this document. The direct branch classified this one message as a financial candidate and added one transaction. The independent body-only branch guessed a generic SBI bank header and also added one transaction in its **separate temporary database**. This proves a real bank sender can reach the existing live text receiver on the tested device; it does not qualify historical range capture or all live senders.

Null `sender_person` is consistent with this String-only live receiver, and null `sender_shortcuts_type` only means the optional type report was not supplied. Neither null negates the supplied text sender. The inference branch's different effective header demonstrates that inference is not source recovery. The two branches are intentionally isolated; their different canonical source keys must not be merged into the main intake as two real messages.

The next useful comparison is the **same source SMS** acquired by **Find Messages** for its receive day, **1 November 2026**, using **PANDAPAY SENDER CHECK → Import PandaPay Range Message as Text**. Inspect the raw card with `origin: history` and `receiver: text_only`; compare its received sender to the working live header. This one-day comparison holds body/source constant while changing acquisition. No full-history rerun, main-app build, privacy reset or classifier change is justified by the successful live result alone. Historical sender capture remains unresolved until that paired result is observed.

**PhonePe collect-request example:** the next user screenshot also has `origin: live` / `receiver: existing_single_message` and a nonempty original payment-app sender header. The raw sender and direct effective sender match, with `senderInferred: false`; the body-only branch falls back to generic `VM-BANK`. The company requesting money is a separate merchant/requester name in the body; PhonePe is the named payment app. Preserve these as different roles. A request saying an account will be debited on approval is pending-request evidence, not a completed expense. The shown direct output added zero transactions and used the broad `commitment_detected` reason. That result does not prove a dedicated pending-request model or the merchant/payment-app fields were extracted correctly; the current comparison screen omits non-transaction observation payloads.

Desired application behavior for this class: preserve the actual SMS header as source evidence; display the requesting merchant and named payment app separately; keep the amount as requested, with approval/completion unconfirmed. Keep a generic body-inferred header in diagnostics only. A later completed-debit event can establish spending and be correlated to the request using supporting identifiers/evidence; amount alone must not merge different payments. This is a field/semantic decision, not a main-app code change or a historical sender-capture success claim.

**User-confirmed request followed by payment:** the user explains that the earlier SBI Card live screenshot is the completed payment for this PhonePe request. The source body says the amount was spent; the direct output retained one expense with the actual SBI Card sender and `senderInferred: false`. The request's supplied receive instant precedes the spent alert by approximately **1.25 seconds**. The matching amount and compatible full/truncated merchant names are consistent with the user's confirmation. Preserve the two original SMS records and their different senders, while counting only the completed-spend record as spending. The requesting app comes from the request; the card instrument comes from the debit alert. Do not replace either source header with a guessed bank string.

The direct completed-payment JSON already shows an expense, a credit-card instrument, the merchant text extracted from the debit body, a separate original SMS receive timestamp and one transaction added. Its transaction date is date-only in the SMS (the JSON uses midnight); no exact bank transaction time is established. It also shows `rail: unknown` despite explicit UPI wording in the body, so that extraction remains incomplete. The comparison screenshots do not show automatic request-to-expense reconciliation, and the diagnostic output omits commitment payloads. Do not claim the request has automatically changed to paid or that the full merchant/payment-app projection is implemented correctly from these screenshots alone. Desired linked UI: a completed merchant expense and a matched request with no second expense, subject to the shared matching rules and evidence. No main-app/classifier changes are made during this analysis.

## Original comparison setup (build 3, preserved)

Created **PANDAPAY SENDER CHECK** by duplicating **PANDAPAY SELECTED RANGE V2** through the supported Mac Shortcuts UI. The original and the main **PANDAPAY SMS HISTORY** recipe were preserved. The copy was exported locally without running it. The export is an opaque AEA container and was not edited. Mac Shortcuts shows the iPhone-only app actions as Unknown Action, so the final field mappings must be checked in the iPhone editor.

In the copy, inside Repeat, use **Import PandaPay Range Message** from the prototype:

| Field | Mapping |
| --- | --- |
| Range request | Keep Shortcut Input / original range request. |
| Message body | Keep Repeat Item → type Message → Body/Content. |
| Sender as person | Repeat Item → type Message → Sender. This retains the original optional Person field and its `emailOrPhone` mode. |
| Sender as text (diagnostic) | The same Repeat Item → Message → Sender, presented to the optional text input. |
| Sender type (diagnostic) | Optional: add the built-in **Get Type** action inside Repeat, before Import, with Repeat Item → Message → Sender as its input. Bind its output to this field. The Get Type action was verified in the current Mac Shortcuts action library. |
| Original receive date | Keep Repeat Item → Message → Date. |

Do not put the Get Type output into either sender value field. Keep the existing search/count/finish/output bindings. These two new diagnostic strings are optional and explicitly do not inherit the preceding action's result. The old action and original parameter IDs/types remain intact.

Open the prototype and select **PANDAPAY SENDER CHECK** in its range-shortcut selector. Pick one known receive day, fetch, then expand the newest entry under **Sender input vs inference**. Older entries remain behind **Earlier comparisons**; the display keeps up to 30 recent non-sensitive inputs.

## What the probe shows

1. **Input received from Shortcut (raw):** message body, original receive date, separately supplied text, Shortcuts-reported type if provided, Person presence, primary handle and its kind, supplied name and its kind, alias count, and the native selected sender/evidence. It does not query Contacts or dump alias addresses.
2. **Without sender inference:** actual shared intake with inference disabled. A name-only Person is visible raw but is not promoted to an address. Missing-sender financial candidates enter local review. Ignored messages remain inspectable.
3. **Body-only inference comparison:** the same shared logic in a separate temporary database, deliberately withholding the sender and using the existing body-inference adapter. The guessed sender, triage, decision/reason, transaction count and parser JSON are shown separately. This branch never changes the direct branch or main app.

The older probe could display `VM-UBINBK (inferred)` after reading “Union Bank” in the body even if no sender arrived. That was not capture evidence. The existing inference implementation suggests `VM-ICICIB` for an ICICI body, `VM-UBINBK` for a Union Bank body, and `VM-BANK` when no listed bank matches. These are parser guesses, not recovered sender addresses. A forwarded bank-style message from a personal number demonstrates the distinction: the supplied personal number can yield `p2p_mobile_number`, while withholding it and guessing a bank can produce a financial candidate.

## Abbreviated synthetic example

This is a synthetic illustration of the screen's structure, not a real message or a device result. The app shows additional decision fields and full parser output when available.

```json
{
  "input": {
    "origin": "history",
    "message_body": "Union Bank of India A/c *1234 Debited Rs:25.00 on 21-10-2026 01:26:04 by Mob Bk ref no SYNTHETIC, Fvg: TEST SHOP Avl Bal Rs:1000.00",
    "sender_shortcuts_type": "Contact",
    "sender_text": null,
    "sender_person": {
      "present": false,
      "handle": null,
      "handle_type": null,
      "name": null,
      "name_type": null,
      "alias_count": 0
    },
    "native_sender_value": "",
    "native_sender_evidence": "missing_person"
  },
  "direct": {
    "effectiveSender": "",
    "senderInferred": false,
    "outcome": "needs_review",
    "intakeReason": "sender_unavailable",
    "transactionsAdded": 0
  },
  "inferred": {
    "inference_basis": "body_text_only",
    "effectiveSender": "VM-UBINBK",
    "senderInferred": true,
    "transactionsAdded": 1
  }
}
```

A directly supplied bank handle instead appears in `sender_person.handle` with `handle_type: application_defined`; a phone sender can have `handle_type: phone_number`. A Person with only a name is distinguished from an absent Person. The native parameters' types describe what reached `perform()` after Shortcuts resolution. If Shortcuts rejects conversion before the handler, the probe cannot observe that failed call; its error and the Get Type result need to be inspected separately. Type names from Get Type are displayed as reported, not used for routing/classification.

## Verification and limits

Focused tests cover raw missing values, named-only input, actual personal-number vs guessed-bank decisions, security exclusion, ignored “Hi” visibility, replay/review acknowledgement, comparison isolation, bounded recent display and narrow-screen JSON rendering. Native range tests verify sender-diagnostic fields stay associated with the same message and do not bypass security exclusions. The direct and comparison databases are in memory, with no account or active upload. No real message is written into development logs or this document.

Signed build, device installation/read-back and real sender capture are recorded separately. No main-app deployment or real history/live message run is performed by the implementation tools. The original sender problem remains unqualified until actual inputs from the test copy are inspected.

**Verification:** all **26 focused Flutter tests** passed, including both comparison outputs, review replay, ignored input visibility, narrow layouts, separate expansion/JSON scroll storage and the existing live acknowledgement retry. Targeted Dart analysis reported no issues. The native history and live harnesses passed. Signed Profile **1.0.0 (3)** built successfully and passed the compiled probe/schema verifier and deep signature validation. The compiled wrapper contains the sender comparison screen and preserves the old live String sender and old range Person parameter, adding only optional diagnostic text/type parameters; main receiver actions and the Flutter demo are absent. Installation to the paired iPhone succeeded. Device read-back/launch and a real mapped sender test are separate evidence below.

The first isolated clean build encountered a missing SQLite header in the disposable wrapper's existing Pods directory. It was restored from the matching CocoaPods release cache after verifying its content matches the main checkout's same dependency version. No main app Pods or dependency versions were changed. The final build used `/tmp/pandapay-sender-probe-derived`, keeping the main app artifact separate.

**Device read-back:** the paired iPhone reports **PandaPay History Probe 1.0.0 (3)** and main **Pandapay 1.0.15 (80)**. iOS successfully launched the probe (process identifier returned by CoreDevice). This is launch/install evidence, not visual screen verification or real sender capture. The separate **PANDAPAY SENDER CHECK** copy exists in the synced Mac library, but the optional diagnostic mappings remain to be set in the iPhone editor, where the receiver action is available. No real SMS/history run or privacy grant was performed by the tools.

If either typed conversion fails before the receiver, test **Sender as person** alone with both new strings blank, then test the diagnostic text separately. An empty snapshot cannot be interpreted as an empty sender: handler entry must be observed. The original range Shortcut is retained for comparison, and the probe's selector can launch it without renaming or overwriting it.

## Main-app migration authorized after the live result

The user subsequently requested moving the text-sender path into the original PandaPay application. See [the main-app migration and UPI card evidence guide](ios-main-text-sender-migration-2026-11-01.md). The prototype remains separate. This later work does not retroactively establish successful historical sender recovery in the screenshots above.

## Build 5 — compare the original receiver with the main input contract

The user explicitly requested continuing tests in the prototype and leaving main PandaPay unchanged. The successful original single-message String receiver is retained. A new **Probe Main-App History Input** action has the same four field IDs, titles, types, optionality, type metadata and explicit-only connections as the main app's **Capture PandaPay History SMS as Text**. It writes only to the existing disposable range inbox; it does not call the main app, a production database or a backend. The compiled verifier compares both bundles' field contracts directly. The original Person range action and text-only range action stay compatible.

In the **PANDAPAY SENDER CHECK** test copy, retain the probe's existing prepare/end/search/count/Finish/Stop actions. Inside Repeat:

1. Use **Inspect Financial Message With Sender** (the working original receiver). Set Message body = Repeat Item → Message → Body; Sender (text) = Repeat Item → Message → Sender; Original receive date = Repeat Item → Message → Date. This published String parameter has the legacy identifier `senderPerson`; the identifier does not mean it is still a Person type.
2. Replace the old range Capture block with **Probe Main-App History Input**. Set Import request = original Shortcut Input; body, Sender (text), and date = the **same source variables** as step 1. The sender parameter here is named `sender`, matching the main app.

Run only a known receive day from the probe. The top **Check today’s history** button selects today's calendar day automatically. Select the existing sender-test shortcut in the probe's dropdown first. **Check latest received message** uses the day of the latest single-message receiver input. No Quick Look or main-app import is required. A new Shortcut action can need initial system consent; repeated consent persistence is not claimed by this build.

The top cards show the actual supplied sender, omitted/empty text, native value type, receiver, parameter ID, receive date and a short body preview. Raw JSON and the separate body-only inference comparison remain available below. Labels identify receivers, not automation triggers. The user's Quick Look image showing `saved_without_sender` is an action receipt; it does not preview the original Sender property.

A reference captured in the original receiver and an exact text match in the selected range can be compared without filling either input. Two matching history records are explicitly ambiguous; no sender is chosen. Matching text is not proof of the same occurrence, and it is never used to merge financial records. The reference stays separate from the recent-30 display limit, and matching scans all accepted rows cheaply so a match near the beginning of a batch is not lost. Raw details remain local to the probe process.

**Checks:** all **33** focused data/widget tests passed, including original/main-contract comparison in the same loop, missing-value preservation, selected-run fencing, duplicate ambiguity, retained references beyond the recent-30 window, unusual native value types and narrow-screen controls. Targeted Dart analysis reports no issues. Native range/live harnesses passed. The signed **1.0.0 (5)** build passed compiled UI/action checks, exact main-field comparison and deep signature verification. The source/config hashes of 14 production files remain unchanged; no main build or main install was performed during this follow-up. Installation/read-back and a real same-variable test are separate evidence recorded below.

**Device installation/read-back:** CoreDevice installation succeeded. A fresh device app-list reports probe **1.0.0 (5)** and unchanged main **1.0.15 (81)**. The main source/config hash check remains clean for all 14 recorded files. The launch attempt was denied because the iPhone was locked (`FBSOpenApplicationErrorDomain`, Locked). The user must unlock and open PandaPay History Probe; no unlock was attempted. This is not reported as a visible/open screen or a successful real-message comparison. No real SMS import or privacy grant was performed by the implementation tools.

## Build 6 — fix registration of the sender-test shortcut

The user correctly selected **PANDAPAY SENDER CHECK** and started the test from the probe, but Prepare immediately reported an inactive range. The native `runShortcut` bridge registered the request only when the name equaled the old **PANDAPAY SELECTED RANGE V2**. It opened the sender-test copy without registering its request, so the first Prepare action inevitably failed `unknownRun`. This was an app implementation defect, not evidence of an expired request or an incorrect user action. The prior suggestion to restart the same flow did not address this condition.

`DeviceHistoryRangeInbox.registerForShortcut` now validates either supported recipe name and registers its V2 request before Shortcuts opens. The bridge calls it for supplied range input instead of gating registration on the baseline name. Unsupported names fail before an unregistered launch. No sender mapping or action input schema changes are required.

The native regression test exercises launch registration → start/end boundaries → sender capture → Finish for both dropdown names, and rejects unsupported names without leaving a run. The native harness passes. The compiled verifier additionally checks that the native binary contains the sender-test recipe registration and that the visible probe title matches its bundle build number. Main PandaPay source/config remains unchanged from the 14-file baseline; main stays on build 81. Build/install evidence follows separately.

**Build-6 artifact checks:** signed Profile build succeeded; the compiled action/field verifier and deep signature validation passed. The exact visible build-6 title is present as a Dart Latin-1 string; the verifier was corrected to recognize that encoding in addition to UTF-8/UTF-16. Native registration of PANDAPAY SENDER CHECK is present in the compiled binary. Installation succeeded. No sender action or Shortcut field rewiring is needed for this registration fix. Device version/launch read-back follows.

**Build-6 device read-back:** the paired iPhone reports probe **1.0.0 (6)** and unchanged main **1.0.15 (81)**. Device launch of the probe succeeded and returned a process ID. The real sender comparison remains to be run by the user; this fix addresses the confirmed missing launch registration, not a claimed recovery of historical sender values. Keep the test shortcut fields unchanged and start the same one-day check from Sender Probe 6.

## Build 7 — one-file diagnostic export

The user requested exporting the probe's evidence in one file instead of sending screenshots. **Export diagnostics** at the top of Sender Probe opens the native iOS share sheet with a single UTF-8 JSON file. The user can choose Save to Files or another sharing destination, then attach the file to the chat. The application does not send it automatically. No main-app changes or main import are required.

The report has format `pandapay.sender_probe_diagnostics`, schema version 1, and native bundle/build/iOS/time-zone metadata. It includes selected shortcut and date/request boundaries, all available native range reports, current pending inputs, native attempt counts/recent events, receiver comparison, a separate capture journal with raw sender/text/Person evidence, actual direct results, body-only inference results, parser output, per-session/range counts, transactions, observations and available error/stack traces. Legacy receiver tags are explicitly distinguished from acquisition triggers. The installed Shortcut recipe itself and failures before its handler are not observable from this app; that limit is stated in the file.

The display remains limited to 30 recent comparisons. The separate export journal retains up to 5,000 processed non-sensitive records / 16 MiB of compact trace data. Capacity omissions are counted and `complete` becomes false; native recent-attempt detail remains limited to 30 while totals cover all observed attempts. Pending inputs are listed separately from processed records. Capture and comparison work yields between 50-message batches to keep the UI usable. Export is a point-in-time snapshot and marks whether processing was ongoing. It cannot recover sessions lost before this update or include future inputs.

SMS text and sender values are included intentionally because the user requested raw diagnostic evidence. Security-code content is excluded from the export, including sensitive values present in the native in-memory attempt panel. Native app metadata overrides any report-supplied app identity. The main bundle is rejected by the file writer. JSON creation is atomic, size bounded to 32 MiB, and performed off the UI thread. Temporary share files are removed on share completion/cancellation; abandoned exports older than a day are cleaned during a subsequent export. A user-saved/shared copy remains with the chosen destination.

**Checks:** all **40** focused data/widget tests passed: full journal beyond the recent-30 screen, input/output preservation, processing failures and retries, explicit capacity limits, sensitive-content exclusion in both attempts and pending inputs, share invocation, duplicate-tap prevention, cancellation, retry and oversized-report feedback. Targeted analysis reports no issues. Native export tests verify Unicode/JSON round-trip, authoritative build metadata, main-bundle rejection, file cleanup and schema/size guards. Existing native range/live tests passed. Build, signature, installation and actual device sharing are recorded separately below. No real message was exported by development tools.

**Build-7 delivery:** signed Profile build, compiled UI/action/field verification and deep signature validation passed. The artifact includes Export diagnostics, its JSON schema and the native file/share handler. Device installation succeeded; fresh app-list read-back confirms probe **1.0.0 (7)** and unchanged main **1.0.15 (81)**. Device launch succeeded. All 14 main source/config hashes remain unchanged. A read-only iPhone Mirroring check returned a mirroring error, so the physical share sheet was not visually inspected and no real user report was exported by the tools. The native file writer and Flutter share/cancel/error flows were tested with synthetic data. Run the sender test once in the updated probe, then Export diagnostics → Save to Files/share → attach the JSON file to the chat. Shortcut mappings are unchanged.

## First user-export result from build 7

The complete exported one-day test contains nine exact body/date pairs through both receiver contracts (18 journal entries), with zero omissions, no pending inputs/errors and a completed range. Both receivers received no sender on all nine. Their direct results match: six review items, three ignored and zero transactions. Three parsed transactions appear only in the separate body-inference comparison. This reproduces the missing value in the original probe receiver as well as the main-shaped receiver, narrowing the next test to source property binding or conversion before handler entry. See the [export analysis and next isolated Text conversion comparison](ios-probe-export-analysis-2026-11-01.md). No main/probe rebuild was made from this evidence.

## Build 8 — extract facts without a fabricated sender, replay the existing file

The user requested using the body facts already present in the diagnostic input rather than requiring another sender-mapping experiment. A new **Extracted message facts** panel calls the shared local parser directly, preserving an absent sender as absent. It shows transaction candidates and unconfirmed payment requests separately, including amount, merchant, instrument, card suffix, UPI evidence, transaction and receive dates, explicit issuer/app names and expandable input/output JSON. These are isolated extraction previews, not posted expenses. The previous strict shared-intake and body-inference comparisons remain separately labelled.

Only the original capture journal inputs are replayed. Previous inferred headers and parsed transaction outputs are not used as new input. Paired receiver traces with identical text and receive instant share one extraction preview, retaining both receiver sources. Different receive times remain distinct; conflicting supplied senders are shown as conflicting. Security inputs and missing dates retain the existing boundary validation. No real SMS text or private transaction data is copied into source fixtures, development logs or this document.

An explicitly staged JSON copy in the probe's Documents directory can be replayed on launch without invoking Shortcuts. SHA-256 acknowledgement fences consumption of that copy; an aggregate receipt contains counts but no messages. The original Downloads file is preserved. Replay inputs are marked `diagnostic_file_replay` in exported traces so replay is not mistaken for new sender acquisition. The report includes `body_evidence` and replay source/count metadata. Clearing the probe also clears staged replay data. Results remain in the disposable process-local diagnostic sessions.

**Local checks:** all **41** focused Flutter tests passed, including a private local replay of the user's existing export. It yielded **9 unique inputs, 3 transaction candidates and 1 unconfirmed payment request**, no omissions, and no invented sender headers. All three candidates' business facts match the prior parser output. Synthetic tests additionally cover missing and conflicting senders, unique saved-card matching, request/completion separation, receiver grouping, date separation, capacity, security exclusion, narrow-screen JSON inspection and automatic replay without any Shortcut invocation. Targeted Dart analysis reports no issues. Native export/replay, range and live harnesses passed, including replacement-file acknowledgement fencing and original-file preservation. Main's 14-file source/config baseline remains unchanged. Build/install and device replay evidence follow separately.

**Build-8 installation:** the signed artifact passed compiled UI/action/field checks and deep signature verification. Installation and fresh device read-back confirmed probe **1.0.0 (8)** and unchanged main **1.0.15 (81)**; probe launch succeeded. A staged-file replay receipt was not retrieved, so automatic on-device file replay is not reported as verified. The original supplied file's hash remains unchanged. iPhone Mirroring could not inspect the screen while the physical phone was in use, and a debugger connection subsequently required the phone to be unlocked. No authentication was bypassed.

**User-run device verification:** the user's subsequent build-8 export contains **18 native-handoff journal entries for 9 unique body/date inputs**, split equally between the original and main-contract receiver. `replay_info` is null; this establishes a real Shortcut handoff, independently of staged-file replay. Its new `body_evidence` section contains **3 transaction candidates and 1 unconfirmed payment request**, zero omissions and no recorded processing errors. Both receiver traces remain attached to each extraction preview. The three candidates match the prior comparison's business facts without using a fabricated sender. The request contributes no spending. All actual captured senders remain unavailable; this proves sender-independent extraction, not recovery of the missing headers or production posting.

The user will run further phone/Shortcut tests and provide diagnostic exports. Automated device checks were stopped after that instruction. The latest export already supplies the needed extraction test, so no further Shortcut edits, new test run or main-app install are required for this result.

## Build 9 — local startup-retry follow-up, not installed

Local startup review found that replay was marked checked even when its file was absent or temporarily unreadable. It is now marked checked only after successful processing and acknowledgement, allowing app-resume recovery. Synthetic widget cases cover immediate availability, a file staged after startup, and a temporary native read failure; each processes once after recovery without invoking Shortcuts. The full focused set now has **43 passing Flutter tests**, with targeted analysis reporting no issues. Signed Profile build 9, compiled UI/action verification and deep signature validation passed locally. It was **not installed** after the user took over phone testing. The phone's verified/tested probe remains build 8; main remains build 81.

## Build 10 — explicit Person-to-String acquisition converter

The earlier screenshots contained real supplied sender headers. A source/history audit found no subsequent removal of a nonempty String in the original receiver or native inboxes: the original optional String receiver was unchanged, and the recent exports already contained empty sender input at handler entry. The two current receiver contracts were both relying on default String conversion. Body parsing cannot reconstruct that absent original address.

Build 10 attaches a public `Resolver<Input = IntentPerson, Output = String>` to the existing String sender parameters in the probe's original two single-message receivers, text-only range receiver and main-field-contract receiver. Saved action/parameter identifiers, String types, optionality, original connection policies and legacy Person action remain compatible. The resolver manually preserves primary phone/email/application-defined handles and name/type/alias-count evidence in a bounded versioned envelope, decoded before native capture. Existing plain String input stays unchanged. Nil, empty and whitespace inputs remain distinct. Names and contact aliases are not silently promoted to original SMS addresses; no Contacts query or body-based header guess is introduced. This adapter is not compiled into the main app.

The native live inbox now carries conversion diagnostics through acknowledgement, and the raw/exported input includes `sender_conversion` and `sender_parameter_state`. A successful typed conversion should show **`intent_person_resolver_v1`**, **`person_handle`**, and a nonempty actual sender. A nonempty **`already_text`** value is also valid capture. An empty already-text input means no Person reached this resolver; it cannot establish recovery.

**Local checks:** 29 focused Flutter data/widget tests passed, including strict shared processing with a resolved primary handle and visible/exported provenance. Targeted analysis reports no issues. The new native harness compiles the actual public resolver parameter declaration and passes application-defined/phone/email, Unicode, direct String/nil/blank compatibility, name/alias exclusion, envelope validation/size bounds and preservation through real live/range inboxes and Finish. Existing native live tests pass. Signed Profile build 10, compiled app/field checks and deep signature verification pass. All 14 recorded production source/config hashes remain unchanged.

**Runtime qualification remains necessary:** the compiled static `resolvableInputTypes` still lists base String conversions, despite the custom resolver being present in compiler constant metadata and the native binary. Neither that static schema nor manually encoding a synthetic Person proves automatic Shortcuts dispatch. This Xcode has no public AppIntentsTesting module or parameter-resolution testing API. Build 10 is therefore a concrete, instrumented acquisition change awaiting the user's bounded phone test, not a verified recovery of the nine missing historical senders. The main-shaped probe action now has additional probe-only conversion behavior; main build 81 does not yet contain it.

Use **PANDAPAY SENDER CHECK unchanged**, start the same known receive-day range from **Sender Probe 10**, and export diagnostics. No Person field replacement, manual bank header, new SMS or automatic tool-run Shortcut is required. The user performs the test and sharing. Installation/read-back evidence follows separately.

Public API references: [Apple Resolvers overview](https://developer.apple.com/documentation/appintents/resolvers), [Resolver conversion method](https://developer.apple.com/documentation/appintents/resolver/resolve%28from%3Acontext%3A%29), [String parameter resolver declaration](https://developer.apple.com/documentation/appintents/intentparameter/init(title:description:default:inputoptions:requestvaluedialog:inputconnectionbehavior:resolvers:)). These establish the supported conversion hook, not device dispatch success for this Message input.

**Build-10 delivery:** CoreDevice installation succeeded. Fresh filtered app-list read-back confirms probe **1.0.0 (10)** and unchanged main **1.0.15 (81)**. The tools did not launch the app, run Shortcuts, import SMS, grant privacy permissions or attach a debugger. The user will perform the one-day check and export; real sender recovery is still awaiting that evidence.

**User's build-10 result:** the new export reports a completed range with 9 found/received/accepted and 18 traces across the two receiver contracts. All 18 inputs have `sender_conversion: already_text`, `sender_parameter_state: empty`, and no Person input. The custom Person resolver was therefore not exercised, and actual sender recovery failed in this test. There are no recorded errors or pending inputs; the existing 3 transaction previews and 1 unconfirmed request remain available. This is not reported as a successful sender fix.

The next bounded comparison materializes the Sender in an Apple **Text** action inside Repeat before the original receiver. Bind only **Inspect Financial Message With Sender → Sender (text)** to that Text action's output, with Text containing Repeat Item → Message → Sender. Keep the main-contract receiver's direct Sender binding as the control, and keep both body/date/request bindings unchanged. Start the same receive-day range from Probe 10 and export. This tests a different upstream rendering step without another app installation, a guessed bank header, or any tool-run phone test. A real nonempty sender must be observed before claiming this route fixes acquisition.

**Text comparison result:** the user supplied a matching screenshot and an export containing 25 distinct original body/date pairs across three completed ranges. The original receiver observed 56 attempts: 25 processed unique inputs, 25 native duplicates and 6 security exclusions. The range control recorded 50 accepted traces across overlapping runs, plus the same 6 exclusions. Every one of the 75 processed journal traces has empty sender text with `already_text` / `empty`. The smaller original journal is duplicate suppression, not a skipped first action. No errors, pending inputs or capacity omissions appear. The 10 transaction previews and 1 unconfirmed request do not establish sender acquisition.

## Build 11 — failed direct-Person attempt (do not repeat)

Read-only inspection of Apple's published Messages entity metadata found a concrete type mismatch: `MessageEntity.author` (Sender) is a foreign **MessagePerson entity**, whose `person` property is **IntentPerson**. It advertises transfer of `com.apple.appintents.IntentPerson`, not a String representation. This matches the failed outer-entity Text conversion and explains why a converter expecting an actual Person was not reached by the observed String calls. The static schema supports this inference; actual iPhone materialization remains a user-run check. Exact schema evidence and limitations are in [the wrapper investigation](ios-message-sender-wrapper-2026-11-01.md).

A separate **Probe Message Sender Person** action accepted an optional `IntentPerson` and recorded its primary handle. It was installed as build 11, but its parameter omitted `mode`; the SDK silently defaulted it to `.contact`. Therefore it was not an unrestricted typed input.

**Phone result:** Shortcuts failed before the handler ran: “Probe Message Sender Person failed because Shortcuts couldn't convert from Person to Contact.” This confirms the default mode was a bad fit. Do not repeat the Build 11 mapping or treat this action as a fix.

**Local follow-up:** a public-SDK custom `AppEntity` resolver experiment compiled, but its generated parameter metadata contained no `resolvableInputTypes`, so it is not yet an evidenced Shortcuts conversion route. The SDK has no unrestricted `IntentPerson` mode. `.emailOrPhone` was already tried on an earlier range action and failed; it also does not guarantee support for application-defined sender handles. No alternative candidate has passed local metadata checks and the user's phone test together. All 14 production baseline hashes remain unchanged. A separate Mac inspection copy named PANDAPAY SENDER PERSON DRAFT was created; its temporary variable edits were undone and it was closed. It is not registered for runs or used by the probe.

**Build-11 delivery:** installation succeeded and fresh filtered device read-back confirms probe **1.0.0 (11)** and unchanged main **1.0.15 (81)**. No app launch, Shortcut run, SMS import, debugger attachment or privacy grant was performed by the tools. The user's screenshot subsequently confirmed the handler was never reached because Shortcuts rejected the conversion. The expected `direct_intent_person_v1` diagnostics were therefore not produced. The installation was a failed experiment, not a sender fix.
