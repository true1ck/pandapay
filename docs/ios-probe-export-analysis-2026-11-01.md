# Sender-probe export analysis — 1 November 2026

Source: the user-provided Sender Probe 7 JSON export. No raw SMS bodies, phone numbers, private references or actual transaction records are copied into this report.

## Observed result

The file reports probe 1.0.0 (7), parser 26, PANDAPAY SENDER CHECK, one completed November 1 receive-day range, no pending inputs, no recorded failures, and no capacity omissions. The journal contains 18 records representing **9 distinct exact message-body/receive-date pairs**, each sent once to each receiver. Eighteen trace records are not eighteen distinct SMS or duplicate expenses.

| Observation | Original single-message receiver | Main-app field-contract receiver |
| --- | ---: | ---: |
| Messages handed off | 9 | 9 |
| Sender supplied | 0 | 0 |
| Sender missing | 9 | 9 |
| Financial candidates routed to review | 6 | 6 |
| Ignored | 3 | 3 |
| Transactions created in direct processing | 0 | 0 |

Every exact body/date pair has equivalent direct outcome, intake reason and effective sender across the two receiver contracts. The main-contract handler's optional sender text is explicitly an empty String for all nine; the original receiver's normalized native sender is empty too. Both report `missing_text`. The original receiver did not preserve its pre-coalescing optional nil-versus-empty distinction, so its `sender_text: null` alone must not be interpreted as proof the variable was unbound.

Six candidate sources remain in review in each direct session. Three other messages were ignored by the shared triage; the ignored outcomes are two `no_financial_signal` and one `promotional_noise`. The independent body-inference comparison creates three parsed transaction records, using guessed bank identifiers. These are not proof of sender acquisition and are isolated from the direct paths. The tested file also contains the earlier bank completion/payment-request message formats, but their private content is not reproduced here.

## What the evidence establishes

1. The range-registration fix worked for the sender-test shortcut in this run: found, received and accepted are all nine, and Finish completed.
2. The missing sender reproduces through **both** the working original receiver and the main-shaped field contract with identical message bodies and dates.
3. For these calls, the sender is already empty at handler entry. A later classifier or parser cannot be the component that removed a supplied nonempty bank header.
4. No main app installation, classifier relaxation, account data change or fabricated sender is justified by these results.

The file does **not** distinguish an empty Message.Sender property, a saved property binding, and Shortcuts' Person-to-String conversion. It does not contain the installed shortcut recipe. It does not prove a universal iOS history restriction, and it does not invalidate earlier nonempty sender captures through the original receiver.

## Earlier proposed comparison — superseded

The user subsequently requested extracting facts from the existing input instead of another sender-property experiment. The following Text conversion comparison was proposed earlier; it is **not required for Sender Probe 8**, and no additional Shortcut run is needed for its staged replay.

In PANDAPAY SENDER CHECK, inside Repeat, add Apple's **Text** action before **Inspect Financial Message With Sender**. Insert only Repeat Item → type Message → Sender into Text. Bind the original receiver's Sender (text) to the **Text action's output**. Keep the main-contract receiver's Sender (text) bound directly to Repeat Item → Message → Sender; keep both message bodies, dates and the original range request unchanged.

Start the same one-day check from Sender Probe 7, then Export diagnostics. No Quick Look, main-app import or new installation is needed. This compares explicit text rendering with direct String-parameter resolution. If rendering provides a header, it establishes a candidate acquisition route to validate; if both remain empty, it further narrows the issue to extraction/binding or conversion shared by both. It is a diagnostic experiment, not a promised sender recovery.

Apple documents adjusting a variable's content type/property and reusing a Text action's output as a separate Magic Variable: [Adjust variables](https://support.apple.com/en-gb/guide/shortcuts/apda36b9018b/ios), [Variable types](https://support.apple.com/en-ie/guide/shortcuts/apdd2b316022/ios). Those pages support the controlled conversion test, not a claim that Apple's historical sender getter is defective.

## Body extraction from the existing export

Sender Probe 8 re-evaluates only the journal's original input body, original receive date and actual supplied sender evidence. It calls the same `LocalSmsParser.parse` used by PandaPay with an empty sender when none was supplied; it never substitutes a guessed bank header or treats the previous report's parsed/inferred output as new input.

The local replay yields **9 unique message inputs, 3 transaction candidates and 1 payment request**, with no capacity omissions. The three candidates match the prior comparison's amount, merchant, transaction date, instrument, card/account suffix, UPI evidence and receive time. Whole-number JSON amounts are compared numerically because Foundation may encode a double as an integer. The payment request stays unconfirmed and contributes no spending.

The two receiver traces for an exact body/receive instant are shown as one extraction preview with both sources retained. Conflicting supplied senders are explicit. Different receive instants stay separate. This is diagnostic grouping, not a production transaction deduplication or posting change.

The screen and exported `body_evidence` section separate actual captured sender, issuer/payment-app names explicitly present in the body, transaction facts, request facts and parser event/reason evidence. An absent sender remains unavailable. A card suffix can use the shared unique saved-card lookup when cards are provided; the isolated replay has no account's saved card catalogue, so product names and payment-app attribution are not invented. Neither a request nor an extracted candidate is posted as spending by this preview.

Main PandaPay remains on build 81. No Shortcut field edits are needed for this extraction/replay update. The original user file remains unchanged; only an explicitly staged probe-local copy is read and acknowledged. Installation and device replay evidence are recorded in the [sender lab](ios-probe-sender-lab-2026-11-01.md).

## Subsequent user-run build-8 export

The second user-provided export confirms the same result from an **actual native Shortcut handoff**: 18 traces / 9 unique inputs, 3 extracted transaction candidates, 1 unconfirmed request, zero omissions and no recorded processing errors. Its `replay_info` is null and all input sources are `native_handoff`. The three candidates' amount, merchant, dates, card/account suffix, instrument and UPI evidence match the earlier inferred comparison, while the new path leaves every missing sender unavailable. The request adds no spending. Each preview retains its two receiver sources.

No additional run is required to verify this extraction behavior. The strict shared intake still routes missing-sender financial candidates to review; no production transaction posting policy was changed. The result establishes that body extraction and sender acquisition can be handled separately. The user will perform further phone tests and share exports; automated device tests have stopped. A local build-9 replay-startup retry improvement was compiled and tested but not installed.

## Repeat-run confirmation

The next user-provided build-8 export is a fresh session and range run, with different capture identifiers and the same nine original body/date inputs. Its completed range reports **9 found, 9 received and 9 accepted**, with zero pending inputs, no recorded errors and no journal/extraction omissions. The same **3 transaction previews and 1 unconfirmed payment request** are produced; all transaction-preview output fields and request facts match the preceding run. The two receiver contracts still receive no sender text on all nine messages. This confirms repeatable sender-independent extraction, while actual historical sender acquisition remains unresolved. No device test, Shortcut edit, installation or production posting change was performed to analyze this file.
