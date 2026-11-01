# SMS category vocabulary contract

## Bounded change

The current SMS fact contract intentionally keeps the existing 15 canonical
spend slugs. `api/src/sms_facts.js` is the server-side owner. The mobile
contract mirrors that list at `app/lib/data/sms_fact_contract.dart` because
the app and API are separate runtimes.

This change removes two avoidable drift points:

- `api/src/gemini_worker.js` now consumes the fact-contract array for its
  structured-output schema and prompt instead of redeclaring it.
- `app/lib/data/local/sms_rule_bundle.dart` now derives its shared-rule
  allowlist from `smsSpendCategories` instead of maintaining a second set.

Conformance tests cover every currently supported slug and explicitly reject
`sports`, `fitness`, and `shopping` until their product semantics are decided.

## Why new categories are not added here

Adding a slug is not only an SMS-parser change. Before a new public category is
safe, the product needs decisions and coordinated changes for:

1. The catalog row/slug and parent-child shape in the reference-data
   migrations and catalogue API.
2. The meaning of overlapping concepts: `online` is currently used as a
   channel/purpose-like category, while `shopping` could mean retail purpose;
   `sports` could mean sporting goods, a gym, coaching, or a venue.
3. Legacy-row treatment and reporting rollups for existing `online`, `other`,
   and merchant-rule assignments.
4. Reward eligibility and category inheritance. Reward rules currently match
   category identifiers explicitly; a new slug must not silently lose or gain
   rewards.
5. API/mobile compatibility and a versioned rollout for old clients, cached
   rule bundles, Gemini prompts, fact validation, and correction screens.

Until those decisions exist, accepting a new slug in only one layer would make
the pipeline appear to support it while catalog lookup, reports, rewards, or
older clients disagree. The safe behavior remains fail-closed validation and
user review/`other` for unsupported vocabulary.

## Follow-up contract for taxonomy expansion

When product decisions are available, add the category to the catalog and
publish a versioned vocabulary consumed by every runtime. The rollout should
include a legacy mapping/backfill policy, reward/report semantics, Gemini
schema/prompt updates, mobile contract updates, and cross-layer fixture tests
before the new slug is accepted by fact validation.
