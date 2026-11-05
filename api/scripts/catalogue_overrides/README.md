# Catalogue overrides

Reviewed fixes to CardPipeline research records. The catalogue loader
(`api/scripts/import_card_pipeline.js` → `catalogue_v2/overrides.js`) applies
them to the source record **before** the v2 transform (plan C7.2). Use them
when an issuer document shows the research is wrong. Use a loader change when a
pattern is wrong for many cards.

## File

One file per card, named after the CardPipeline checklist `source_slug`:
`api/scripts/catalogue_overrides/<source_slug>.json`.

```json
{
  "source_slug": "swiggy-hdfc-bank-credit-card",
  "changes": [
    {
      "path": "cap_rules[id=swiggy_cashback_cap].metric",
      "value": "total_reward_points",
      "reason": "Issuer caps the cashback (₹1,500/cycle), not the spend.",
      "source_url": "https://…",
      "checked_on": "2026-11-05"
    }
  ]
}
```

`source_slug` must match the file name.

## Paths

| Syntax | Meaning | Example |
|---|---|---|
| `a.b.c` | object keys | `accrual_engine.rounding_mode` |
| `[n]` | array index | `fee_waiver_and_milestones.spend_milestones[0].period` |
| `[key=value]` | the array element whose `key` equals `value` | `reward_rules[id=online_5pct].conditions.mcc_list` |

Every segment except the last must exist. The last one may be a new key.

## Operations

`op` is optional:

- `set` (default): replaces the value. `null` is allowed, and so is a whole
  array (`"path": "cap_rules"`).
- `remove`: deletes a key or an array element.
- `append`: pushes `value` onto an array.

A change whose path doesn't resolve is **not applied**. The card is still
loaded, and the failure is listed under "Overrides NOT applied" in
`.staging/coverage-report.md` (flag `override_not_applied`). Applied changes
are listed in the card's `model_coverage.overrides_applied`.

## Values the loader understands

- **Category tokens**: use only tokens in `catalogue_v2/category_tokens.js`
  (`CATEGORY_MAP`, `MERCHANT_TOKEN_MAP`, `GROUP_TOKEN_MAP`,
  `PLATFORM_TOKEN_MAP`, or `all_retail`). Prefer `conditions.mcc_list` /
  `mcc_exclude` and merchant names over new tokens. The coverage report lists
  unmapped tokens by frequency.
- **Rule role**: `reward_rules[id=x].rule_role` = `info` always makes the rule
  `info`. Another role is used only if the rule maps cleanly.
- **Cap metrics**: `bonus_reward_points`, `total_reward_points`,
  `eligible_spend_amount`, `txn_count`. The currency (points or ₹ cashback)
  comes from the targeted rules.
- **Cap and milestone periods**: the source values (`calendar_month`,
  `statement_cycle`, `quarter`, `calendar_year`, …).
  `statement_cycle_quarter` is read as `quarter` (flag `period_approximated`).
- **Rounding**: `accrual_engine.rounding_mode` = `floor` | `round` |
  `points_half_up` | `points_floor` | `none` (D7);
  `accrual_engine.cashback_rounding` = `paise` | `rupee_floor` |
  `rupee_half_up` (D11).
- **User-dependent cap**: set `cap_rules[id=x].depends_on_user` to `true` and
  `limit_value` to `null` (D13a).
- **Keeping a deferral flag** (D13/D14): when a restated rule or cap no longer
  carries the key the flag came from, set it explicitly:
  `reward_rules[id=x].depends_on_user_attribute` or
  `reward_rules[id=x].depends_on_txn_attribute` = `true` (the rule becomes
  `info` with that flag), or `cap_rules[id=x].cap_depends_on_user` = `true`
  (the flag is kept; the amount stays as given, or null).
- **Card-age cap tier**: set `cap_rules[id=x].tier_by_card_age` to `true` on
  the introductory tier (D8d).

The loader reports `override_removed_exclusion` when a whole-array
`reward_rules` replacement drops a source exclusion, and
`dangling_cap_reference` when a rule's `cap_reference` names no cap (D14c).

`verified_cards.json` (WP7) lists the source slugs whose worked examples pass.
The loader marks those cards `model_status = 'verified'`.

## Check before committing

```sh
node api/scripts/import_card_pipeline.js --transform-only --slug <card-slug> \
  --pipeline /path/to/CardPipeline
```

Then read `api/scripts/.staging/coverage-report.md`. The test
`api/test/catalogue_v2_fixtures.test.js` also applies every file here to its
record (when the record is available) and fails on any path that doesn't
resolve.
