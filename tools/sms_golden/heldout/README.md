# Held-out generalisation sets

Synthetic account, UPI and card alerts in wordings and layouts **no rule was written for**, each with the right answer, and lookalikes that are not a completed money movement. They measure how the whole pipeline (rules, the evidence reader, instruments, linker, ledger) reads a bank it has never seen. Every value is invented.

| File | What | Answer |
| --- | --- | --- |
| `variants_a.jsonl` | 360 alerts, 30 layouts, 14 ways of printing an account number, 8 amount forms, 8 date forms | `truth.direction`, `truth.minor`, `truth.digits` (how the account ends) |
| `variants_b.jsonl` | 185 alerts, 26 more layouts including UPI and card alerts | same |
| `variants_c.jsonl` | 116 alerts, 20 more layouts (pipe and dash separated, "stands credited", pension, ATM "Wdl", Hinglish) | same |
| `lookalikes.jsonl` | 88 messages that must count nothing: future, failed, pending, requests, balances, offers, OTPs, dues, warnings, holds | none |

`tools/sms_rules_cli/test/generalization_guard_test.dart` runs each message alone through the full pipeline and fails on any wrong direction, amount or account, any silent drop, and any counted lookalike. `app/test/features/sms_v2/pipeline/generalization_gate_test.dart` checks the phone's intake gate lets every alert through.

Measured 10 Nov 2026, each set scored blind the first time and then used to fix what it showed:

| Set | First (blind) score | After the fixes |
| --- | --- | --- |
| A, before any engine change | 53% counted correctly, 32% parked for confirmation, 7% review, about 8% silent or wrong | 100% |
| B, after the fixes for A | 96.8% counted correctly, 2.7% review, 0.5% wrong, no counted lookalike | 100% |
| C, after the fixes for B | 83% counted correctly (14 points of it with no account read), 14% review, 3.4% silent, 1 of 20 lookalikes counted | 96.6% counted, 3.4% review, nothing wrong or silent |

All three are regression guards now, not a blind measure: write a new set to measure again. The generators (`gen_*.py`) are kept so a new set can be made the same way.
