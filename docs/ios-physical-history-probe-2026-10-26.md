# Physical iPhone history probe

**27 October follow-up:** [shared intake and corrected metadata results](ios-shortcuts-shared-intake-2026-10-27.md). A single-message Date mapping subsequently worked. Sender still failed conversion. The diagnostic now runs the actual shared capture store and excludes incomplete inputs; the body-only results below describe the earlier research build.

Tested on 26 October 2026, on `codex/ios-shortcuts-prototype` based on `dev`.

## Verified acquisition

The connected iPhone 16 Pro Max reports iOS **27.2 (24B5084k)**. Through iPhone Mirroring, a real Apple Shortcut using the Messages **Find Message** action returned five matching messages with a `Body contains debited` filter.

The Message output must be mapped to its **Body** property. Counting characters in the default Message representation returned 40; after selecting Body, the same bounded query returned **2,397 characters**. No message bodies were copied into the repository or diagnostic logs.

The query was then restricted to `Date is before October 1, 2026 at 11:18 PM` with a five-item limit. Running Find Message → Count Characters in Body returned **2,449 characters**, establishing that this device can retrieve bodies from existing older messages. The saved Shortcut is named **PandaPay History Probe**.

This is evidence for the tested iOS 27.2 device. It does not establish availability or equivalent behavior on iOS 26, arbitrary message history pagination, or unattended incoming-message automation.

## Isolated parser app

The separate diagnostic has bundle identifier `app.pandapay.iosimportprobe` and display name **PandaPay History Probe**. A disposable Flutter wrapper is prepared by `app/tool/prepare_ios_device_history_probe.py`; it copies the current parser dependency closure without modifying the Android parser.

The native App Intents are compiled only with `PANDAPAY_DEVICE_IMPORT_PROBE`, and the capture code also checks the exact diagnostic bundle identifier at runtime. Native input is limited to 100 messages, uses an OTP/security rejection gate, and stays in process memory. The Flutter screen retains parsed summaries in memory. The diagnostic does not initialize account, synchronization or backend services.

The physical-device Profile build succeeded, including App Intents metadata generation. Xcode initially reported No Accounts; after the existing Apple account became available, automatic signing created the device provisioning profile and the signed build succeeded. The separate app was installed successfully. The user trusted their Apple Development certificate in Settings → General → VPN & Device Management. `devicectl` then launched the app, and Shortcuts listed its **Inspect Financial History on iPhone** action.

The saved Shortcut passed a five-item `Body` list from actual Messages into that App Intent. Shortcuts reported `{"captured":5}`. The app received five inputs and the shared Android triage/parser produced **one confirmed bill with an amount** and **four unknown messages needing review**. The first diagnostic screen counted those unknown outcomes as financial; this was corrected to display `Financial observations: 1` and `Needs review: 4`.

Mapping `Sender` and `Date` from the Message variable did not preserve those values. A count-only diagnostic returned `body_count:5`, `sender_count:5`, `nonempty_senders:0`, `date_count:0`, while still capturing all five bodies. No sender identifiers or message content were logged. The date filter proves these particular source messages predate October 1, but the App Intent still lacks their individual original receive dates. As a result this device test does **not** prove exact historical timestamp preservation or robust replay deduplication. A search for a separate “Get Details of Messages” action on this phone returned none.

The existing Android `reviewDraft` helper is now used for unknown financial candidates. It can suggest an amount and merchant for a user review screen while keeping the record out of the confirmed financial count. A synthetic unresolved debit example produced an ₹875.50 and Green Basket suggestion; no transaction was committed.

On 27 October, the updated diagnostic was run with the saved **date-filtered** Shortcut and refreshed on the iPhone. Its screen showed `Shortcut inputs: 5`, `Financial observations: 5`, `Needs review: 0`, `Original dates supplied: 0`, and `Senders supplied: 0`. The shared parser classified those five bodies as bills with amounts. This is a second bounded run, not a reclassification of the earlier one-bill/four-unknown result. The bill labels and amounts were not checked against the source messages for correctness, so the observation proves the handoff and parser execution, not financial accuracy.

## Current manual workflow and limits

On this tested phone, the user must run the saved **PandaPay History Probe** Shortcut. It uses **Find Message** with a body phrase and date cutoff, limits the result to five messages, passes each message's **Body** to the separate App Intent, and grants Shortcuts' message-sharing prompt when iOS asks. The user then opens the diagnostic app to inspect parsed summaries. The user must set the search phrase, cutoff and additional batches deliberately; there is no demonstrated unattended backfill or complete inbox scan.

The actual historical receive date and sender did not reach the App Intent, even though the respective Message properties were selected. The diagnostic therefore cannot assign an exact event time or safely identify repeat runs from this real input. Its in-memory UUID fallback deliberately avoids collapsing two equal-text payments, but repeated runs can add duplicates. This is a blocking gap for a production-quality historical import. Incoming-message automation, iOS 26 behavior, large-result pagination, and locked/offline execution remain untested on a physical device.

## Verification

- Ten focused Dart tests passed across the synthetic adapter/history tests and the physical-device summary adapter tests.
- Targeted Dart static analysis reported no issues.
- Both unsigned and signed ARM64 physical-device Profile builds succeeded.
- No backend changes, commits, pushes or production app replacement were performed.
