# History sender capture: build 80

**Superseded for new history recipes:** use the separate **Capture PandaPay History SMS as Text** action described in [the main-app migration guide](ios-main-text-sender-migration-2026-11-01.md). The old Person action remains compatible, but later screenshots prove Person conversion can fail before its handler; it is no longer the recommended mapping.

The build-79 device result confirms that message bodies and original dates arrive while all 413 valid inputs in the shown window have an empty sender. The text resolver did not solve that handoff. Build 80 adds a direct Person input to the existing **Capture PandaPay History SMS** action; the original text field remains optional and compatible.

## One mapping change

After installing build 80 or later, open **PANDAPAY SMS HISTORY** in Shortcuts and edit **Capture PandaPay History SMS** inside Repeat.

| Field | Set it to |
| --- | --- |
| Import request | Keep the existing request variable. |
| Message body | Keep Repeat Item → Message → Body/Content. |
| Sender (text) | Empty: remove the Sender variable from this field. |
| **Sender from Message** | **Repeat Item → type Message → Get Sender.** Preserve the Sender object; do not change it to Text or select the whole Message. |
| Original Message Date | Keep Repeat Item → Message → Date. |

Keep Find Messages, Count, Repeat, Finish and Stop and Output as they are. Do not replace the action or reset privacy settings for this test. If the new field is absent, close and reopen the editor after confirming the new main app build is installed.

## Verify the handoff

Run a short date range containing known messages from PandaPay. Under **Import options → Import details**, inspect the result showing **Capture received by build 80** (or later). If a new empty catch-up check appears, expand **Last completed import**.

- **Sender received above zero + Last sender input: Message sender handle** establishes that a supplied Message address reached the native receiver. Compare classification separately; a personal sender can still be ignored by PandaPay's shared rule.
- **Message sender supplied without an address** means a Person arrived without a usable primary handle. It does not justify substituting a contact name or guessing from its aliases.
- **No sender value arrived** means both sender inputs were empty at handler entry. It does not identify the source-side cause by itself.
- **Sender text** means the legacy text input was used.
- **No messages received yet** or no fresh Capture marker does not qualify sender capture.

The input-kind label describes the last delivery for that attempt. Counts cover accepted, non-security receipts and survive processing acknowledgement. No raw sender or message body is added to diagnostic settings.

## Canonical input and safeguards

`SmsSenderInput.swift` uses the supplied Person's primary phone, email or application-defined handle first, then explicitly supplied legacy text. Person display names and aliases do not establish the original SMS address. Unknown-sender financial candidates continue into local review; they are not silently trusted or discarded. Historical review items are not rewritten by this adapter change.

The canonical sender remains String in the shared Android/iOS intake. Body/date, account ownership, duplicate receipts, security exclusions, classification and month-completion gates retain their existing behavior. Only the acquisition adapter gains a direct typed field. Apple's [IntentPerson API](https://developer.apple.com/documentation/appintents/intentperson) supplies person/handle information; real bank-header, personal-number and repeated-permission behavior still require device qualification.
