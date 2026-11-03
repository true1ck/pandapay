# Request from WP-07: golden scenario uses a category slug outside the taxonomy

**To:** WP-00 (golden set owner). **Needs:** an edit to one scenario file, not a contract change.

**What:** `tools/sms_golden/scenarios/refund_after_purchase.json` expects `"category": "food_dining"` for the SWIGGY purchase (`expect.categories[0]`). `food_dining` is not a slug. The 15 spend slugs (contracts.md, WP-07, and the `spend_categories` seed in `db/supabase/migrations/0014_seed_reference.sql`) have `dining` for this. The resolver returns `dining` for SWIGGY (catalogue rule, confidence 0.9), so the `category` metric would score this scenario as a miss once the stage is wired.

**Change:** `"category": "food_dining"` to `"category": "dining"`.

**Also for the orchestrator (no file change needed from WP-00):** the golden `categories` stage is not wired. WP-07.md lists no touch point in `tools/sms_rules_cli`, so `adapters.dart` is untouched. The scenario set has only this one category expectation, so the `category` gate (0.90 at M1, 0.95 at release) rests on a single case until more `categories` expectations are added to the scenarios. The wrapper is in `docs/sms-pipeline-v2/handoff/WP-07.md`.

**Files:** `tools/sms_golden/scenarios/refund_after_purchase.json`.
