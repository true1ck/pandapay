# SMS Intelligence — Phase 4 Report (Needs Review and Corrections)

**Date:** 2026-10-21
**Scope:** Family-specific review kinds, safe task actions, screenshot security/service cases, structured fact override persistence, and protection against AI/rule replays.

## Changed files

| File | Change |
|---|---|
| `app/lib/data/needs_review_repository.dart` | Extended `NeedsReviewKind` enum with `securityOrServiceAlert`, `investmentSettlement`, and `mandate` in addition to `transaction` and `commitment`. Deserialization fallback preserves compatibility with existing stored rows. |
| `app/lib/features/activity/needs_review_screen.dart` | Added family-specific classification (`_isSecurityOrServiceAlert`, `_isInvestmentSettlement`, `_isMandateReview`) and dynamic type/reason/action labels (`_reviewTypeLabel`, `_reviewReasonLabel`, `_reviewActionLabel`). Security/service alerts render "Security or service alert" with a direct "Dismiss alert" action, never "Review transaction". Investment settlements render "Investment settlement payout" with "Review transfer". Ambiguous card/account notices show "Choose card/account". Confirmed manual transactions sync structured fact overrides to `POST /sms/facts/overrides` using the 64-character sourceKey and fact index. |
| `app/lib/data/user_cards_repository.dart` | Added `overrideSmsFact({sourceKey, factIndex, patch, reason})` method communicating with `POST /sms/facts/overrides`. |
| `api/src/sms_facts_route.js` | Registered `POST /sms/facts/overrides` endpoint. Validates hex64 sourceKey, non-negative factIndex, and ensures merged patch satisfies the fact schema before writing to `fact_overrides`. |
| `api/src/sms_facts.js` | Added `writeSmsFactOverride` storing user patches in `fact_overrides`. Upsert replay preserves existing overrides; `resolveFactsWithOverrides` guarantees user edits take precedence over parser and AI results. |
| `api/test/sms_facts_route.test.js` | Tested override validation, contract enforcement, invalid patch rejection, and replay immunity where user overrides outrank replayed payloads. |
| `app/test/features/activity/needs_review_screen_test.dart` | Added 5 new widget tests for: HDFC Transaction Check Alert ("Dismiss alert", not "Review transaction"), ViCARE call forwarding ("Dismiss alert", not "Review transaction"), Kotak Neo settlement ("Review transfer", not "Review transaction"), ambiguous account debit ("Choose card/account"), and structured override sync on save. All 12 tests pass. |

## Evidence

- **Flutter tests:**
  - `app/test/features/activity/needs_review_screen_test.dart`: **12 passed / 0 failed**.
  - `app/test/data/needs_review_repository_test.dart`: **7 passed / 0 failed**.
  - `app/test/data/sms_family_corpus_test.dart` + `sms_facts_outbox_test.dart` + `sms_fact_contract_test.dart`: **49 passed / 0 failed**.
  - All existing SMS scanner and intake suites: **118 passed / 0 failed**.
- **Server tests:**
  - `npm --prefix api test`: **558 passed / 0 failed / 1 skipped** (including 7 override/route tests in `api/test/sms_facts_route.test.js`).

## Compatibility gates

| Gate | Status |
|---|---|
| Screenshot security/service cases do not show "Review transaction" | ✅ Verified by widget tests: HDFC and ViCARE display "Security or service alert" and "Dismiss alert". |
| Corrected fact survives restart and rerun | ✅ Stored in `fact_overrides`; `resolveFactsWithOverrides` guarantees user override outranks later parser or AI result. |
| Existing flow preserved | ✅ No changes to scan checkpoints or source hashes. |
| Account isolation maintained | ✅ Review items, outbox, and fact overrides are scoped by namespace/profile_id. |

## Risks / Next

- Phase 5: Gemini Queue — durable job acceptance, rate/token/daily quota enforcement, worker leasing, retry with backoff, automatic payload gate, and per-item structured validation before writing to fact slots.
