# SMS category taxonomy rollout v1

Status: frozen contract and rollout gate (2026-11-01)

Decision: do not add `sports`, `sports_fitness`, or `fitness` yet. The
current system can safely reject those values and preserve the transaction for
review/`other`, but it cannot safely publish one of them as a new public SMS
category without a coordinated taxonomy release.

## v1 contract

The canonical SMS spend vocabulary is the exact ordered list below:

`groceries`, `fuel`, `dining`, `online`, `travel`, `bills`, `rent`,
`insurance`, `education`, `government`, `wallet`, `entertainment`, `health`,
`emi`, `other`.

The versioned test oracle is
`app/test/fixtures/sms_category_taxonomy_v1.json`. It is not a runtime source;
the API fact contract remains the server owner and the mobile fact contract is
its mirror.

## Cross-surface audit

| Surface | Current contract | Finding for Sports |
| --- | --- | --- |
| API typed facts | `api/src/sms_facts.js` exports 15 slugs and rejects other values | `sports` is rejected |
| Mobile typed facts | `app/lib/data/sms_fact_contract.dart` mirrors the same 15 slugs | `sports` is rejected |
| Gemini schema/prompt | `api/src/gemini_worker.js` uses the API array for the enum and prompt | no model vocabulary exists for Sports |
| Downloaded/shared rules | mobile shared-rule validation derives its allowlist from the fact contract; the API serves approved v2 tuples | a rule cannot safely introduce Sports |
| Reference catalogue | `0014_seed_reference.sql` seeds 15 `spend_categories` rows | no catalog UUID/name/ordering exists for Sports |
| MCC/merchant hints | current UPI MCC hints and built-in merchant rules only resolve existing categories; `sports` in a merchant name is not category evidence | a name such as `BALAJI SPORTS` must not force Sports |
| Reporting | `spend_reports.js` joins `spend_categories` and falls back to `other` | a new slug needs a catalog row and response-label coverage |
| Rewards | reward rules/caps/exclusions match category UUIDs, not free-form slugs | Sports needs explicit catalogue/reward policy; otherwise it silently receives only base-rate behavior or wrong exclusions |
| Legacy learning migrations | the 2026-10-27 shared-rule functions historically allow `investments`, `income`, and `cash`; the 2026-10-28 v2 function narrows to the 15-slug contract | old database/client states are not a safe place to add a new slug ad hoc |

## Legacy boundary that must remain explicit

`investments` and `income` describe non-spend entry semantics in local SMS
classification; `cash` is also an instrument/movement label. They are not v1
SMS spend categories. Historical shared-rule migrations contain those values,
so they are recorded in the fixture as legacy allowlists rather than silently
treated as current taxonomy. Existing rows must not be bulk-reclassified when
Sports is introduced.

The existing `online` label is `Online Shopping`; it is not evidence that every
shopping or sporting-goods purchase belongs to a future Sports category. The
new category must have an explicit meaning and precedence relative to `online`,
`other`, user categories, and merchant-specific rules.

## Required v2 rollout before accepting Sports

1. Decide one stable slug and label (`sports` versus `sports_fitness` is a
   product decision, not a parser shortcut). Define whether it covers goods,
   gym/club dues, coaching, events, and equipment, and define ambiguous cases.
2. Add a version-2 taxonomy fixture with the catalog row, display label,
   ordering/icon, parent/subcategory policy, accepted fact value, and explicit
   legacy mapping. Keep v1 immutable.
3. Add the reference-data migration and verify the `/categories` response.
   Do not rewrite existing `online`, `other`, or custom-category rows.
4. Update API facts, mobile facts, Gemini schema/prompt, local display labels,
   downloaded/shared-rule validation, and their version/hash/min-client gates
   in the same release. A new value must never be accepted by only one side.
5. Add reviewed merchant/MCC evidence and conservative precedence tests. A
   merchant-name match alone must not infer Sports from words such as
   `SPORTS` or `FITNESS`.
6. Define reward semantics before publication: default/base-rate behavior,
   category rules, caps, exclusions, fee-waiver interactions, and whether
   historical rows remain in their old category. Add reward-parity fixtures.
7. Add reporting/rewards/API/mobile integration tests, then release the API
   and mobile client with the same taxonomy version. Older clients must either
   receive a safe display fallback or be excluded by the minimum-client gate.
8. Roll out in shadow/review mode first. Promote only after category-rule
   evidence, false-positive/false-negative checks, report reconciliation, and
   reward parity pass. Roll back by version/hash without deleting user edits.

## Contract-test gate

The taxonomy-only tests are:

- `api/test/sms_category_taxonomy_contract.test.js`: API/mobile source parity,
  Gemini enum/prompt coupling, downloaded-rule boundary, catalogue seed,
  migration allowlists, legacy classification, and report/reward boundaries.
- `app/test/data/sms_category_taxonomy_contract_test.dart`: mobile fact and
  downloaded shared-rule acceptance/rejection against the same v1 fixture.
- `app/test/fixtures/sms_category_taxonomy_v1.json`: immutable v1 oracle and
  explicit legacy/proposal sets.

These tests intentionally do not change parser, AI, identity, projection, or
reward implementation. A future Sports change that updates only a prompt,
fact validator, mobile cache, migration, or catalogue will fail the contract
gate before it can create partial vocabulary drift.
