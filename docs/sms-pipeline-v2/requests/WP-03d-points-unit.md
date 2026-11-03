# Request to WP-02 (from WP-03d): whole points for `unit: POINTS`

**What.** `RuleEngine._buildEmit` turns every emitted amount into paise with `parseAmountIndian`, whatever the `unit`. For `unit: "POINTS"` the contract says `minor` is whole points, so "earned 50 points" comes out as `5000`, "2,000 points redeemed" as `200000`, and "total balance 1,250 points" as `125000`.

**Why it matters.** Every reward rule in `rules/sms/v2/rewards_limits/rewards_limits.json` (`REW-*`) emits `points_earned`, `points_redeemed` or `points_balance`. Six golden cases fail only on this: `probe:reward_points_earned`, `probe:reward_points_redeemed` and four `wp03d:reward_*`. The rule JSON cannot work around it (amount `transforms` are ignored by the engine).

**Suggested change** (`packages/pandapay_domain/lib/src/sms_v2/engine/rule_engine.dart`, amounts loop): when `a.unit == 'POINTS'`, parse the group as digits with commas removed (`int.tryParse(raw.replaceAll(',', ''))`, reject anything else) instead of `parseAmountIndian`. Add an engine test: `"50 points"` gives `minor: 50`.

**Files.** Engine only. No rule or contract change; the 03d rules need nothing once it lands.
