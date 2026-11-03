# Request from WP-03c: golden case `corpus:autopay_failed` cannot be produced

**What.** The golden case `corpus:autopay_failed` (HDFCBK: "AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.") expects an `attempt` fact (`status: failed`, `direction: debit`) with no amount.

**Why it cannot pass.** The frozen fact contract requires every `attempt` to carry a `posted` or `scheduled` amount (`fact.attempt.amount_required`), and `minor` must be above 0. The message prints no amount, so no rule can emit a valid `attempt`. The engine turns an invalid emit into an `unknown` review item. A rule that emits `info` instead would count the message as an ignored financial case, which breaks the "zero financial cases caught by an ignore rule" gate, so WP-03c leaves it unmatched on purpose.

**Options (orchestrator decides).**

1. Golden fix (WP-00 owner): expect `unknown`/review for this case, or give the message text a printed amount (the real bank messages for failed standing instructions do print one, and WP-03c matches those with `MND-FAILED-01`).
2. Contract change request: allow an `attempt` with no amount. This touches `contracts/sms/v2/`, the Dart and Ajv validators and WP-05 totals, so it is not recommended for one template.

**Files.** `tools/sms_golden/cases/HDFCBK/*` (case `corpus:autopay_failed`), or `contracts/sms/v2/fact.schema.json` for option 2.

**Also noticed (engine, WP-02).** A `balance_snapshot` needs `asOf`, and the engine reads `asOf` only from a regex group. A statement or reminder that prints a total due but no date (for example "Your statement is generated. Total amount due INR 4,200.") therefore cannot become an `outstanding` snapshot and goes to review. Letting `attrs.asOf` fall back to `observedAt` when the group is absent would fix this class without a contract change.

## Integration decision — 3 November 2026

Use option 1: the unchanged amount-less synthetic message expects `unknown`/review, not an impossible amount-bearing attempt. It remains financial and remains in capture-recall and ask-rate measurements. No amount is fabricated, no ignore rule is added and no contract changes. This removes an inconsistent golden expectation; the case still requires review.
