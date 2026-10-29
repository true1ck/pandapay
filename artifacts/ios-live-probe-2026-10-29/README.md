# Live incoming SMS diagnostic

Workspace: `the isolated implementation worktree`.

The new **Live incoming SMS** card appears first in PandaPay History Probe V2. It distinguishes calls to the existing single-message handlers from range history. No Shortcut changes or real SMS imports were performed by the agent for this update.

Both **Inspect Financial Message on iPhone** and **Inspect Financial Message With Sender** now record safe pre-validation invocation metadata. Body/date/sender absence, sensitive/invalid/oversized rejection, duplicates and capacity are observable if the handler runs. Input conversion/IPC/trigger failures before that point remain **UNOBSERVED**. Only valid non-sensitive retained live SMS can be expanded locally.

Native records remain pending until Flutter reports an explicit shared-intake outcome. Failed parsing and acknowledgement retries do not count as successful intake or add duplicate rows. Live data uses a separate disposable database; history and self-check traffic cannot inflate live results. Receive time, handler/import time and processing time remain distinct. Aggregate counters are per process; the recent metadata list is bounded to 30 events. Installation, restart and explicit Clear reset temporary state.

Validation: **22 Flutter/widget tests passed**, both native synthetic harnesses passed, targeted Dart analysis found no issues, Python utilities compile, and the isolated signed Profile build succeeds. All sources match the prepared wrapper. Build metadata confirms both instrumented single-message intents (optional body/date, defaulted or optional sender) plus the existing four V2 range intents. See `verification.json` for the final installation/launch status and exact changed-file list.

Minimum user test: open the installed updated probe, receive one new non-sensitive test SMS through the existing incoming automation, reopen the app, and inspect **Handler calls** plus the latest event. Tap **Refresh / retry live handoffs** if needed. A higher call count establishes that this receiver was invoked. The latest state shows retained, ignored, metadata/security rejection, pending or retry. Zero observed calls does not by itself identify an automation error. All-message filter coverage, Message Content/Date conversion, original sender conversion and closed/locked/background behavior remain unverified.

User-observed March/September history counts and October receive/import date separation are recorded in `docs/ios-shortcuts-prototype-plan-2026-10-27.md`. They validate those individual history runs, not incoming automation or exhaustive inbox coverage.
