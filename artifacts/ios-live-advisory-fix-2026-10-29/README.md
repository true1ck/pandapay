# Live security-advisory false-positive fix

The established terminal **Never Share OTP/PIN/CVV** advisory no longer automatically rejects an otherwise ordinary financial alert. The exception is deliberately narrow: financial prefix with amount, exact advisory list and optional alphabetic signoff; authentication/reset instructions or remaining credential evidence keep the security veto. Original text and original receive time are unchanged.

Swift live/range/legacy-device gates and Dart adapter/parser/triage use equivalent policies. The shared Dart source change also corrects this Android classification false positive; it does not change Android scanning, transaction extraction, deployed apps or the production API. The optional learning sample redactor and tagged simulator's native gate remain conservative.

The live panel shows **Inspect Financial Message on iPhone** for `text_sender` and **Inspect Financial Message With Sender** for `person_sender`. These identify the receiver, not the source automation. It also gives a missing original Date hint.

Validation: **439 Flutter/shared/widget regressions passed**; a shared **30-case synthetic security corpus** passed Dart and native live/range tests; native live/range regression harnesses passed. Analysis has no errors, warnings or new findings; two pre-existing parser info-level lints remain. The signed isolated build succeeded. `verification.json` records final installation/launch status and all changed paths.

Independent device evidence remains unresolved by this app fix: two observed `text_sender` calls had no original Date, while a screenshot of the With Sender action showed a Message-to-Date conversion error before the handler could run. The user reported `A` triggered execution where blank Message Contains did not. `A` covers only a subset. Apple documents Sender/Message Contains filters; no unrestricted all-message trigger was verified.

Minimum next manual check: in the affected action, select **Shortcut Input → Type Message → Get Date**, only if that source actually supplies Date. Do not change the whole variable Type to Date, substitute Current Date, or parse receive time from the body. If conversion still fails, use the existing V2 range workflow for the **actual receive day** as reconciliation. The agent did not modify Shortcuts or run real messages. Installing this update restarts the process and resets temporary diagnostic state.

See the master handoff for the observed counts, official documentation links, remaining mapping/trigger limitations and a proposed (unimplemented) unique-source lookup fallback. No private SMS/account/reference data is stored in this artifact or its synthetic fixtures.
