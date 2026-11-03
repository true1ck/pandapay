# WP-15 repeated correction and explanation review fixes

Orchestrator assigned this focused review fix from checkpoint 08f1a43. Owned paths: `ui/review_controller.dart`, `corrections/corrections_service.dart`, related trace/storage and tests. It separately approved the narrow `why_sheet.dart` explanation renderer and `LedgerSnapshot` original-MovementFact owner index plus regression. No UI screens, holds arithmetic, native smoke, providers, phone migration or frozen contracts changed.

## Correct current state, retain receipt identity

The controller keeps original source-owned fact IDs for the correction wire case and the captured receipt for privacy/ignore semantics. Current merchant/category choices come from the event's active money fact. The service independently resolves that active fact, copies its already-corrected fields into the next immutable user fact, inherits an explicit instrument binding, and replaces its active leg. Original receipt legs remain as `original` evidence, including non-anchor receipts. Obsolete replacement legs stop participating in money projection; raw receipts and immutable facts remain retained.

The regression reproduced amount 10000→8000 remaining 10000 before the fix. It now exercises 10000→8000→6000, two merchant changes and two date changes, checking current active fields/ledger while every correction still reports the original receipt source/fact IDs. Repeated amount edits also preserve a manually selected instrument.

## Explain saved state

Within the same savepoint, source traces are refreshed from actual changed events, active facts, resolved instruments and projected category decisions. Local-only metadata records userChoices, instrument step `user_choice`, event type/status and category slug. Original rule attribution remains available as “Originally read with …”. Manual choices are explained as choices; changed event/link readings do not repeat stale automatic matching claims. Primary merged-event traces take precedence over the event retired by a link correction. The compact server trace schema is unchanged and no SMS body or monetary value was added to traces.

A linked refund referencing a corrected non-anchor original movement now finds its purchase category through the original-MovementFact owner index, preserving the existing stable-anchor behavior.

## Verification

- 37 focused app tests pass: correction service/trace, controller actions, pure Why text and existing review screens. Includes repeated edits, category/link trace refresh, grouped rollback, late failure rollback of active facts/traces/queue/totals, instrument binding and original-source ownership.
- 13 domain ledger projector tests pass. New non-anchor refund regression failed with `other` before the fix and now inherits `dining`; existing anchor regression remains passing.
- Targeted Dart analysis reports no issues, and diff whitespace checks pass.

Branch retains earlier WP-16/consent commits and merges root 08f1a43 without dropping either. Only the final focused fix commit should be cherry-picked by the orchestrator if those dependencies were already integrated separately.
