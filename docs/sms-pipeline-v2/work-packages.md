# Work packages

Each work package is self-contained: an agent needs only the Agent playbook, the Contracts tab and its own section. Packages in the same milestone with no dependency between them run in parallel.

## Index

| WP | Title | Milestone | Depends on | Owns (main paths) | Model | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 00 | Golden set and eval harness | M0 | none | `tools/sms_golden/`, `tools/sms_rules_cli/` (skeleton, `cluster`, `redact`, `golden`), `app/test/sms_golden_baseline/`, `api/test/sms_golden_baseline/` | Sonnet | Done (4944a5e) |
| 01 | Contracts package | M0 | none | `contracts/sms/v2/`, `pandapay_domain/.../sms_v2/contract/`, `api/src/sms_v2/contracts.js`, `app/lib/features/sms_v2/flag.dart`, `app/lib/features/sms_v2/storage/schema.dart`, `app/pubspec.yaml` (assets) | Opus | Done (a61e338). Contracts frozen 2026-11-03 |
| 02 | Rule engine | M1 | 01 | `pandapay_domain/.../sms_v2/engine/`, CLI `build`, `lint`, `sign-dev`, `fetch-baseline` | Sonnet | Done (19fa053) |
| 03 | Baseline rule bundle (03a–03d) | M1 | 00, 02 | `rules/sms/v2/` (one sub-package per family folder), `app/assets/sms_rules/` | Sonnet × 4 | Done: 03a d5b4ff0, 03b 58ffdd5, 03c 5614e31, 03d 4915b83 |
| 04 | Instrument registry and detection | M1 | 01 | `pandapay_domain/.../sms_v2/instruments/`, `app/lib/features/sms_v2/storage/instrument_store.dart`, `app/lib/features/sms_v2/instruments/` | Sonnet | Done (def5312) |
| 05 | Event linker | M1 | 01, 04 | `pandapay_domain/.../sms_v2/linker/`, `app/lib/features/sms_v2/storage/event_store.dart` | Opus | Done (d4a4cf7) |
| 06 | Ledger and projections | M1 | 05, 07 | `pandapay_domain/.../sms_v2/ledger/`, `app/lib/features/sms_v2/ledger/`, `storage/ledger_store.dart`, totals call sites (hotspot owner) | Sonnet | Done locally (87d9c78) |
| 07 | Category resolver and taxonomy | M1 | 01 | `pandapay_domain/.../sms_v2/category/`, `app/lib/features/sms_v2/category/` | Sonnet | Done (c60d3fb) |
| 08 | Server facts ingestion v2 | M1 | 01 | `api/src/sms_v2/{index,facts_route,sync_route,storage,guard}.js`, `scripts/check_sms_v2.js`, migrations for instruments, facts, events, ledger and `transactions` columns | Sonnet | Done (08c5a2f) |
| 09 | Rule service v2 | M1 | 01, 02 (bundle shape) | `api/src/sms_v2/{rules_route,rules_admin_route,bundle_builder,signer,rule_stats}.js`, `api/scripts/import_sms_v2_rules.js`, rule migrations | Sonnet | Implemented locally; private admin integration verified (23f7f16) |
| 10 | AI per template | M2 | 09 | `api/src/sms_v2/{ai_templates,template_worker}.js`, template migration`s` | Sonnet | Implemented locally (a560c39); provider/device rollout checks open |
| 11 | Admin Rules page and corrections UI | M2 | 09, 12 | `console/lib/features/sms_rules/`, `console/lib/data/sms_v2_admin_api.dart`, console routes | Sonnet | In progress; console and evaluator tests |
| 12 | Correction trace and `sms-fix-case` skill | M2 | 00, 08 | `api/src/sms_v2/corrections_route.js`, corrections migration, `app/lib/features/sms_v2/pipeline/trace.dart`, `app/lib/features/sms_v2/sync/corrections_sync.dart`, `.claude/skills/sms-fix-case/` | Sonnet | Implemented locally; phone review integration in progress |
| 13 | Security | M2 | 08, 09 | `api/src/sms_v2/security.js`, `app/lib/features/sms_v2/sync/{bundle_verifier,rule_keys,attestation}.dart`, `app/pubspec.yaml` (attestation plugin), platform setup files | Sonnet | In review; production keys, App Check and device audit gates open |
| 14 | Phone pipeline wiring and batched sync | M2 | 02, 04, 05, 06, 07, 08 | `app/lib/features/sms_v2/pipeline/`, `sync/` (except WP-12 and WP-13 files), `storage/{fact_store,outbox_store,bundle_store,stats_store}.dart`, `providers/`, `app/lib/app/providers.dart` | Opus | In review; capture/sync tests pass, desktop history 103 s; physical device gates open |
| 15 | Review and confirmation screens | M2 | 14 | `app/lib/features/sms_v2/ui/`, `app/lib/app/router.dart` | Sonnet | In progress; confirmation, inbox, trace and ledger screens |
| 16 | Data migration and replay | M3 | 14, 08 | `app/lib/features/sms_v2/migration/`, `api/src/sms_v2/legacy_supersede.js`, supersede migration | Opus | In progress; server inventory and phone replay fixture |
| 17 | Cutover, cleanup and release | M3 | all | Flag removal, deletions listed in WP-17, minimum-version enforcement, release checklist | Opus + orchestrator | Not started |

Parallel lanes in M1: `02 → 03`, `04 → 05 → 06` (06 also waits for 07), `07`, `08` and `09`. In M2, 10, 12 and 13 run in parallel, then 11; WP-14 starts once its M1 inputs are Done, then WP-15. In M3, WP-16 runs, then WP-17.

## WP-00 Golden set and eval harness

**Goal:** a labeled set of real-shaped messages and multi-message scenarios, plus a runner that scores any implementation, so every later package is judged by numbers.

**Milestone** M0 · **Depends on** none · **Model** Sonnet

**Owns:**

- `tools/sms_golden/`
- `tools/sms_rules_cli/`: the package skeleton, the command registry in `bin/sms_rules.dart`, and the `redact`, `cluster` and `golden` commands
- `app/test/sms_golden_baseline/`
- `api/test/sms_golden_baseline/`

**Touch points:** root `.gitignore` gains `tools/sms_golden/private/`; `packages/pandapay_domain/pubspec.yaml` gains `crypto`. WP-00 also owns `packages/pandapay_domain/lib/src/sms_v2/template/`: the skeleton and `templateHash` functions, plus the redaction core redact(), which the CLI, the engine and the phone all use.

**Build:**

1. **CLI package.** Create the Dart package `tools/sms_rules_cli` (path dependency on `pandapay_domain`, plus `args`). `bin/sms_rules.dart` holds a command registry (`name → Command`) so later packages add one line each.
2. **`redact`.** Input is CSV or JSONL of `{sender, body, observedAt}`. Output is JSONL in which:
   - person and party names become `<PARTY>`; merchant names survive only when they are in the bundled merchant catalogue
   - phone numbers, URLs and emails become placeholders
   - every digit run of 4 or more characters is replaced by synthetic digits of the same length, kept consistent within one message
   - amounts keep their printed format (commas, decimals, `Rs.`, `INR`, `₹`) but get synthetic values
   - dates are shifted and keep their format

   No original value may survive.
3. **`cluster`.** From redacted JSONL, compute the sender brand and a skeleton: amounts → `<AMT>`, dates → `<DATE>`, masks → `<MASK>`, UPI IDs → `<VPA>`, references → `<REF>`, other digits → `#`.
   - `templateHash = sha256(brand + "\n" + skeleton)`.
   - Write `templates.json`, sorted by count, with brand, skeleton, count, 3 samples and first and last seen.
4. **Case format** (`tools/sms_golden/cases/<brand>/<templateHash>.json`): `{id, templateHash, weight, source: "synthetic" | "redacted_real", messages: [{sender, body, observedAt}], expect: {facts: [partial Fact], ignore?: true, unknown?: true}}`.
   - Partial matching: listed fields must match, and unlisted fields are ignored.
   - `weight` is the template's real message count (1 for synthetic cases).
5. **Scenario format** (`tools/sms_golden/scenarios/*.json`): `{id, description, knownInstruments?, messages: [ordered], expect: {events: [{type, legRoles}], instruments: [{kind, issuerSlug, maskDigits}], totals: {from, to, spendMinor, incomeMinor, investmentMinor, transactionCount}, categories?: [{eventIndex, category}]}}`.
6. **Seed data:**
   - Convert `app/test/fixtures/sms_family_corpus.json`, `app/test/fixtures/local_sms_cases.json`, and the 35 review probe cases (the orchestrator places them in `tools/sms_golden/cases/_probe/`).
   - Write at least 12 scenarios: card bill pair; wallet top-up then wallet spend; IPO block then release; IPO block then allotment debit; refund after purchase; mandate then charge; self-transfer; the same payment from a bank and a UPI app; salary; limit enhancement; points earned; a cheque debit.
7. **`golden`.** Load a bundle, cases and scenarios, and run them through the WP-01 interfaces: `SmsInterpreter`, `InstrumentResolver`, `EventLinker`, `LedgerProjector` and `CategoryResolver`.
   - A stage without an implementation yet is reported as `not_available`, not as a failure.
   - Compute the metrics in Test and release, weighted by `weight`, overall, per family and per brand.
   - Write `report.json` and `report.md`.
   - Exit non-zero when below `tools/sms_golden/gates.json`, or below `--baseline <report.json>` on any metric.
8. **Baseline of today's system:** `app/test/sms_golden_baseline/baseline_test.dart` runs `LocalSmsParser`, and `api/test/sms_golden_baseline/baseline.test.js` runs `parseSmsAgainstPatterns`, over the cases. Both write a report. Tag them `golden-baseline` so normal CI skips them.
9. **Private data:** real exports live only in `tools/sms_golden/private/`, which is git-ignored. Only cases that went through `redact` and that a person reviewed move into `cases/`.

**Tests:**

- Redaction: a fixture of fake "real" messages proves no original name, number or amount survives, and that formats are preserved.
- Clustering: the same template with different values gives one hash.
- The partial matcher and the metric maths.

**Done when:**

- [ ] `dart run bin/sms_rules.dart redact|cluster|golden --help` all work.
- [ ] The existing fixtures and the 35 probe cases are converted, and at least 12 scenarios exist.
- [ ] The baseline reports for today's phone and server parsers are committed under `tools/sms_golden/reports/`.
- [ ] `gates.json` holds the targets from the Overview tab.

**Out of scope:** labeling the owner's real messages (done with the owner once Full Disk Access is granted), and the engine itself.

**The owner's real export already exists:** 5,210 messages from 274 senders over 12 months, read from the Mac Messages archive.

- The scripts used are in `docs/sms-pipeline-v2/seed/real_sms_tools/` (extract, analyse, and run both of today's parsers). Turn them into the `redact` and `cluster` commands.
- Real extracts go only into `tools/sms_golden/private/` and are never committed.
- Clustering note: replacing only numbers left 1,772 groups. Merchant and person names must also become placeholders (for example any word seen in fewer than 5 messages) to reach a few hundred real templates.

## WP-01 Contracts package

**Goal:** turn the Contracts tab into code that both languages enforce identically, plus the interfaces every other package implements. After this merges, the contracts are frozen.

**Milestone** M0 · **Depends on** none · **Model** Opus

**Owns:**

- `contracts/sms/v2/` (schemas, fixtures, `error_codes.json`)
- `packages/pandapay_domain/lib/src/sms_v2/contract/`, `lib/sms_v2.dart`, `test/sms_v2/`
- `api/src/sms_v2/contracts.js`, `api/test/sms_v2/contracts.test.js`
- `app/lib/features/sms_v2/flag.dart`, `app/lib/features/sms_v2/storage/schema.dart` and its test

**Touch points:**

- `api/package.json`: add `ajv` and `ajv-formats` dependencies only.
- `app/pubspec.yaml`: add the `assets/sms_rules/` asset entry.
- `.github/workflows/build-and-test.yml`: add a "Contracts" step that runs both conformance suites.

**Build:**

1. **JSON Schemas (draft 2020-12)** for `fact`, `instrument`, `event`, `ledger_entry` and `rule_bundle` (rule, emit, link rule, category rule, ignore rule, sender, alias), plus one request schema per route in Contracts. The fact schema uses `oneOf` per `factType` to enforce each type's `attrs` and required amount roles.
2. **Fixtures:**
   - `fixtures/valid/`: at least 3 per fact type and 1 per other type.
   - `fixtures/invalid/`: at least 1 per invariant, named after the error code it must produce.
   - `error_codes.json` lists every code (for example `fact.movement.posted_required`).
3. **Dart types:**
   - `sealed class Fact` with one final subclass per fact type.
   - Value types `Amount`, `InstrumentMention`, `Counterparty`, `Provenance` and `Span`.
   - `Instrument`, `Event`, `LedgerEntry`, `RuleBundle`, `Rule`, `Emit`, `LinkRule`, `CategoryRule`, `IgnoreRule`, `SenderEntry` and `MerchantAlias`.
   - Enums carry wire names.
   - Everything is immutable, with value equality, `fromJson` and `toJson`.
   - `validate()` returns the same error codes as the server.
4. **Interfaces** in `contract/interfaces.dart`, exactly as below. Later packages implement them and must not change their signatures.
5. **Node validators:** `contracts.js` compiles the schemas once with Ajv (`strict`, `allErrors`). It exports `validateFact`, `validateInstrument`, `validateEvent`, `validateLedgerEntry`, `validateBundle` and `validateRequest(routeName, body)`, each returning `{ok, errors: [{code, path}]}` with the codes from `error_codes.json`.
6. **Conformance tests on both sides:** every valid fixture passes, and every invalid fixture fails with exactly its expected code. Dart round-trip (`fromJson` → `toJson`) equals the canonical fixture.
7. **Build flag:** `flag.dart` holds `const bool kSmsPipelineV2 = bool.fromEnvironment('SMS_PIPELINE_V2');` and a Riverpod provider `smsPipelineV2EnabledProvider` that tests can override.
8. **Phone schema:** `schema.dart` creates every phone table from Contracts → Storage. `SmsV2Schema.ensure(Database db)` is idempotent and records its version in `sms_v2_schema_version(module TEXT PRIMARY KEY, version INTEGER)`. Test it on an in-memory SQLite database, running `ensure` twice.
9. **Placeholder baseline:** commit `app/assets/sms_rules/baseline_bundle.json` as an empty bundle with `bundleVersion: 0`. The contract allows `signature: null` only for version 0, and the engine treats version 0 as "no rules".

```dart
// packages/pandapay_domain/lib/src/sms_v2/contract/interfaces.dart
class SmsMessage {
  final String sender;        // as received, e.g. VM-HDFCBK-S
  final String body;          // original text; never leaves the phone
  final DateTime observedAt;  // UTC
  final String sourceKey;
  final String? iosFilter;    // iPhone filter tag, e.g. smsft_fi or smsfp; null on Android
  const SmsMessage({required this.sender, required this.body, required this.observedAt, required this.sourceKey, this.iosFilter});
}

enum InterpretOutcome { matched, ignored, unknown }

class InterpretResult {
  final InterpretOutcome outcome;
  final List<Fact> facts;     // matched: 1..n facts; ignored: one InfoFact; unknown: empty
  final String? ruleId;
  final int? ruleVersion;
  final String templateHash;  // same algorithm as WP-00 `cluster`
  const InterpretResult({required this.outcome, required this.facts, this.ruleId, this.ruleVersion, required this.templateHash});
}

abstract interface class SmsInterpreter {
  InterpretResult interpret(SmsMessage message, RuleBundle bundle, {required String appVersion});
}

abstract interface class InstrumentResolver {
  InstrumentResolution resolve(InstrumentMention mention, Iterable<Instrument> known,
      {required String profileId, required DateTime observedAt});
}

abstract interface class EventLinker {
  LinkResult link({required List<Fact> incoming, required LinkContext context, required List<LinkRule> rules});
}

abstract interface class CategoryResolver {
  CategoryDecision resolve(CategoryInput input);
}

abstract interface class LedgerProjector {
  List<LedgerEntry> project(Event event, Map<String, Fact> factsById,
      Map<String, Instrument> instrumentsById, CategoryDecision? category);
  Totals totals(Iterable<LedgerEntry> entries, Iterable<Event> events, DateTime from, DateTime to);
}
```

WP-01 also defines the supporting value types:

- `InstrumentResolution`: `{Instrument instrument, bool created}`
- `LinkContext`: facts in the last 120 days, open events with status `awaiting_leg`, and instruments by id
- `LinkResult`: `{List<Event> created, List<Event> updated, List<ReviewItem> ambiguous}`
- `CategoryInput`: `{counterparty, senderBrand, contextTokens, mcc?, userRules, bundleRules, confirmedHistory}`
- `CategoryDecision`: `{slug, source, ruleId?, confidence}`
- `Totals`: `{spendMinor, refundMinor, incomeMinor, investmentMinor, transactionCount, byCategory}`
- `ReviewItem`: `{kind, payload}`

**Done when:**

- [ ] Both validators agree on 100% of the fixtures.
- [ ] Dart round-trips every valid fixture exactly.
- [ ] The interfaces and value types are exported from `package:pandapay_domain/sms_v2.dart`.
- [ ] The schema test passes, and the flag file and placeholder bundle exist.
- [ ] The CI Contracts step is green.
- [ ] The orchestrator marks the M0 gate "Contracts frozen".

**Out of scope:** any behaviour. This package is types, validation and interfaces only.

## WP-02 Rule engine

**Goal:** one pure-Dart engine that turns a message and a rule bundle into facts. It runs identically on the phone, in the admin console and in the CLI. There is no bank-specific code in the engine; all bank knowledge lives in rules.

**Milestone** M1 · **Depends on** WP-01 · **Model** Sonnet

**Owns:**

- `packages/pandapay_domain/lib/src/sms_v2/engine/`
- `tools/sms_rules_cli/lib/commands/{build,lint,sign_dev,fetch_baseline}.dart`
- the engine tests and benchmark

**Touch points:** one registration line per command in `tools/sms_rules_cli/bin/sms_rules.dart`.

**Build:**

1. **`normalizeSenderBrand(sender)`:** remove an iOS filter tag such as (smsft\_fi) and return it as iosFilter, then upper case, strip the operator prefix `^[A-Z]{2}-` and the suffix `-[STPG]$`, then resolve aliases through `bundle.senders`. This is the only implementation in the codebase.
2. **`CompiledBundle.compile(RuleBundle)`:**
   - Validate the bundle, then refuse it if `minEngineVersion` is newer than the engine.
   - Precompile every regex and index rules by brand.
   - Sort by `priority` descending, then `id`.
   - Compile once per bundle, never per message. A rule with match.templateHash applies only to messages whose templateHash equals it (provisional rules from WP-10).
3. **`RuleEngine implements SmsInterpreter`**, following the run order in Contracts → Rule bundle:
   - **Amounts** go through `parseAmountIndian` and return integer paise.
   - **`occurredAt`** tries the listed formats in IST and returns UTC. A date more than 1 day after `observedAt` becomes null.
   - **Instrument mention:** kind and issuer come from `emit`, or the issuer from the sender; `maskFrom` goes through `digitsOnly`, recording the length.
   - **References** come from named groups `ref_<key>`, for example `ref_upiRef`.
   - **Counterparty** goes through the named transforms; then the bundle's counterpartyPurposes may override purpose (see Contracts).
   - **Provenance** = rule id and version, bundle version, `engineVersion` and `appVersion`.
   - **`factId`** follows Contracts.
   - **Evidence spans:** Dart gives no group offsets, so find each captured value inside the match range, scanning left to right.
4. **Safety checks after each emit:**
   - Run `Fact.validate()`. On any error, drop that message's facts and return `unknown` with reason `rule_emitted_invalid`, counted in stats. The engine never throws.
   - Reject a mask whose span overlaps the date span (the "card 2026" bug).
5. **`templateHash`:** call the WP-00 template module.
6. **Transforms** (`transforms.dart`), each with table-driven tests:
   - `parseAmountIndian`: `Rs.1,23,456.78`, `INR 85,000.00`, `₹ 499`, `Rs 14250`, `Rs.5,000.00/-`, `1,48,701.00`
   - `parseDate`: `dd-MM-yy`, `dd-MM-yyyy`, `dd/MM/yy`, `ddMMMyy` (`01Nov26`), `dd-MMM-yy`, `dd MMM yyyy`, `yyyy-MM-dd:HH:mm:ss`, each with an optional time
   - `sanitizeNarration`: a faithful port of `app/lib/data/indian_narration_sanitizer.dart`, which WP-17 then deletes
   - `digitsOnly`, `upperTrim`, `vpaFromText`, `stripTrailingRefs`
7. **CLI commands:**
   - `build`: merge `rules/sms/v2/**` into one canonical bundle JSON, validate it, and run every rule's `examples`. Any mismatch fails the build.
   - `lint`:
     - the regex dialect rules (the lint core lives in engine/lint.dart so the console reuses it; the CLI only wraps it)
     - unique rule ids
     - every rule has positive and negative examples
     - every sender exists in `senders.json`
     - **shadowing:** no positive example of rule A may be matched first by a higher-priority rule B
   - `sign-dev`: sign with a local development key from `SMS_RULES_DEV_KEY`, for tests only. Production signing is server-side (WP-09).
   - `fetch-baseline`: download the latest published bundle through the admin API (`SMS_ADMIN_TOKEN`) into `app/assets/sms_rules/baseline_bundle.json`.
8. **Regex parity test:** `tools/sms_rules_cli/test/regex_parity.mjs` runs every pattern and example in Node and compares the named groups with Dart's result. CI runs it.
9. **Benchmark** (tagged `benchmark`): 10,000 messages against a 1,000-rule bundle in under 2 seconds on a CI desktop, and compile in under 300 ms.

**Tests:**

- each transform
- ordering (ignore first, brand before generic, priority then id)
- `requireAll` and `rejectAny`
- invalid-emit handling
- mask/date overlap
- `factId` stability
- determinism: the same input gives byte-identical JSON
- refusal of a bundle whose engine version is too new

**Done when:**

- [ ] `golden` reports extraction metrics through the real engine.
- [ ] All engine tests, the parity test and the benchmark pass.
- [ ] `build` and `lint` work on a sample rules folder, including one shadowing failure that is reported correctly.

**Out of scope:** writing bank rules (WP-03), linking, instruments, and network or storage code.

## WP-03 Baseline rule bundle

**Goal:** move all bank, wallet and investment knowledge out of the 3,500-line Dart grammar and the 1,750-line server parser into bundle rules, and measure them on the golden set. After this, no message format lives in code.

**Milestone** M1 · **Depends on** WP-00, WP-02 · **Model** Sonnet, 4 agents in parallel

### Sub-packages and owned files

Rule files are split by family, so the four agents never edit the same file. `build` merges them.

| Sub-package | Covers | Owns |
| --- | --- | --- |
| 03a Banks | Card spends with available limit; account debits and credits; UPI; IMPS, NEFT and RTGS; salary; cheques; ATM; own transfers; refunds and reversals; both sides of card bill payments; foreign spends | `rules/sms/v2/banks/<issuer>.json` (one per issuer: hdfc, icici, sbi, axis, kotak, idfc, yes, indusind, pnb, bob, canara, union, federal, au, rbl, sc, hsbc, citi, amex, plus `others.json`), `rules/sms/v2/senders/banks.json` |
| 03b Wallets and UPI apps | Paytm, PhonePe, Amazon Pay, Zomato Money, MobiKwik, Freecharge and others: wallet spends, loads, balances and cashback to wallet | `rules/sms/v2/wallets/*.json`, `rules/sms/v2/senders/wallets.json`, `rules/sms/v2/counterparty_purposes.json` (wallet top-up UPI IDs; card-payment payees such as CRED, CHEQ (printed by SBI as CHEQ DIGITAL PRI), BBPS and BillDesk billers, Tata Neu and PayZapp bill pay, and payees named "\<bank> credit card") |
| 03c Investments, mandates, bills | ASBA and UPI IPO holds, releases and allotment debits (including from bank senders); SIPs and mutual funds (Groww, Zerodha, Upstox, CAMS, KFintech); UPI AutoPay and e-NACH create, modify, revoke and execute; card statements and dues; utility, insurance and loan EMI dues; Pay Later | `rules/sms/v2/investments/*.json`, `rules/sms/v2/bills_mandates/*.json`, `rules/sms/v2/senders/{investments,billers}.json` |
| 03d Limits, rewards, links, categories | Limit changes; reward points earned, redeemed and expiring; cashback; ignore rules for promotions and service noise; the 7 link rules; category rules (ported from `api/src/merchant_category.js` and the FlashText catalogue, with the known collisions fixed); merchant aliases | `rules/sms/v2/rewards_limits/*.json`, `ignore_rules.json`, `link_rules.json`, `category_rules.json`, `merchant_aliases.json` |

Sub-agents never commit `app/assets/sms_rules/baseline_bundle.json`. The orchestrator builds it after merging all four.

### Method (every sub-package)

1. **Inventory.** List every branch in `app/lib/data/local_sms_parser.dart` and `api/src/sms_parser.js` that touches your families, and every fixture or test message in `app/test` and `api/test` for them. Treat the old code as a specification of formats and guards: port the meaning, not the code. Add any missing message as a synthetic golden case.
2. **Write rules in priority bands:**
   - 500–900: one exact issuer template
   - 300–499: an issuer's generic wording
   - 100–299: cross-issuer generic (`senders: ["*"]`)
   - 1–99: last-resort generic movement, with `purpose: unknown` and confidence 0.6 or lower, which the pipeline sends to review
3. **Examples:** each rule has at least 1 positive example and 1 near-miss negative (the failed, declined, scheduled or promotional variant of the same wording).
4. **Iterate.** Run `lint`, `build` and `golden` until the family gates below pass.
5. **Hand off.** The handoff note maps every old parser branch to its new rule ids, so WP-17 can delete the old code with confidence.

### Family gates (on the golden set for that family)

- [ ] Event kind at least 99%, amount and role at least 99.5%, instrument at least 99%.
- [ ] Zero financial cases caught by an ignore rule.
- [ ] Zero shadowing errors in `lint`.
- [ ] Every probe case from the review comes out right. For example: the ASBA block is a `hold`, the card "payment received" is a `movement` credit with purpose `card_payment`, "points worth ₹50" is a `reward`, and Amex "ending 10005 on 10 Nov 2026" gives mask `10005`.

### Round 2

Once the owner's real templates are labeled (after Full Disk Access), the same four owners work through them in order of weight, highest first, until the release gates in Test and release pass.

### Real templates to cover first

These come from the owner's 12 months (Overview → "Your real messages"). Each is listed by sender and kind only. The redacted examples arrive with WP-00's real golden set.

- **03a Banks:**
  - SBIUPI "A/C … debited by \<amount without Rs> … trf to", and the same account under SBIBNK, SBYONO, SBIPSG and CBSSBI
  - SBI credits "credit by \<payer> - \<company>", which are dividends (`purpose: dividend`; 15 NACH dividend credits from 13 companies in the owner's data); broker money: UPI debits to UPSTOX SECURITIE and NU INVESTORS TEC (investment) and NEFT credits from Kotak Securities and Upstox (investment withdrawal); employer NEFT credits (income, labelled salary by WP-06)
  - India Post (DOPBNK) account debits and credits
  - ICICI account "debited … Info BIL\*" (bill payments)
  - Kotak "transferred to your account"
  - YES BANK card "amount received on your card from \<payer>"
  - card "payment received" from ICICI (BBPS), HDFC and YES
  - refunds
- **03b Wallets:**
  - Zomato Money: payment from balance, and "added to" credits with an expiry date
  - Amazon Pay: card loads that print "AMAZON PAY WALL" or "AMAZON PAY IN E" (wallet top-up), and balance payments sent by Juspay and Pine Labs. Amazon Pay is walletSpendVisibility partial: emit the card load as a movement with purpose wallet\_topup to issuer amazonpay, and each balance payment as an evidenceOnly movement plus a balance\_snapshot
  - Pluxee: spends, deductions such as convenience fees (`purpose: fee`), and loads
  - store-account payments such as TinyMart, as `evidenceOnly` receipts; card-bill app payments, such as SBI UPI debits to CHEQ DIGITAL PRI (29 in the owner's data, about 20% of today's spending total), and app receipts such as Tata Neu "bill payment … is successful" (evidenceOnly)
- **03c Investments, mandates and bills:**
  - ICICI "account has been blocked / unblocked by an amount … against the UPI one-time mandate" (hold placed, released)
  - ICICI "approved the mandate of … raised by" and "… is revoked"
  - SBI "UPI-Mandate … created … Funds blocked" and "hold for … has been removed"
  - NSE IPO application receipts and BSE "No allotment" (instrument hints and info)
  - ICICI standing instructions: upcoming (`attempt`, `scheduled`), processed (`movement` with `mandateRef`) and "could not be processed" (`attempt`, `failed`)
  - card statements from ICICI, YES and SBI, and the CRED reminders for the same cards, as one `bill_due` each, never two
  - broadband and phone bills due (Jio, Alegra)
  - biller receipts (JioFiber, rent) as `evidenceOnly`
  - broker settlement payouts and notices (Kotak, Upstox, Univest); NSE and BSE "fund balance" reports as balance\_snapshot for a broker instrument (7 brokers in the owner's data); IPO issuer mandates ("mandate of … raised by \<company>") as mandate with oneTime and mandatePurpose ipo
- **03d Ignore and info rules:**
  - broker "payable to you for all trades" notices (NSE and BSE fund-balance reports are balance snapshots now, see 03c)
  - UPI collect requests (PhonePe, SBI)
  - YES BANK "funds … require consent to continue disbursement" loan offers
  - recharge and data-pack promotions, using the iOS `smsfp` tag as a supporting signal

**Out of scope:** engine changes (file a request to WP-02), linker logic (WP-05; link rules here only set its parameters), and category precedence (WP-07).

## WP-04 Instrument registry and detection

**Goal:** every account, card, wallet and broker account the user owns becomes a stored instrument, detected automatically from messages and kept up to date with balances, limits and points. Existing cards and detected bank accounts carry over.

**Milestone** M1 · **Depends on** WP-01 · **Model** Sonnet

**Owns:**

- `packages/pandapay_domain/lib/src/sms_v2/instruments/`
- `app/lib/features/sms_v2/storage/instrument_store.dart`
- `app/lib/features/sms_v2/instruments/`: seeder, card linker, bank-summary adapter

**Touch points:** none. Read-only use of `UserCardsRepository` and `LocalCardDiscoveryEngine` is allowed; editing them is not.

**Build:**

1. **`DefaultInstrumentResolver implements InstrumentResolver`**, using the matching order in Contracts. A new instrument gets a uuid v4, status `detected`, the default display name and the sender brand as an alias. Ambiguity (2 or more candidates) creates nothing; it returns a review flag.
2. **Who may create an instrument:**
   - A mention needs an issuer and either a mask, or a single instrument of that issuer and kind.
   - A sender whose `issuerKind` is `upi_app` never creates a bank account from a mask alone. Rules put a counterparty's digits in `counterparty.accountMask`, not in the instrument. This replaces today's "UPI" sender filter.
3. **`applyFactToInstrument(Instrument, Fact) → Instrument`**, a pure function:
   - `balance_snapshot` updates `available*` or `points*`, but only when its `asOf` (or `occurredAt`) is newer.
   - `limit_change` updates the credit limit unless `creditLimitSource == user`, and keeps a short `limitHistory`.
   - `instrument_hint` adds the product name and linked UPI IDs.
   - Every fact updates `lastSeenAt` and `evidenceCount`.
4. **`InstrumentSeeder`**, called by WP-16:
   - Each existing `user_cards` row becomes a `credit_card` instrument with status `confirmed` and its `userCardId`.
   - Each existing `BankAccountSummary` becomes a `bank_account`. It is `confirmed` if the user set a manual balance, `detected` otherwise.
   - Seeding is idempotent.
5. **`InstrumentCardLinker`.** When the user confirms a credit card without a `userCardId`:
   - If exactly one `user_cards` row matches issuer and last 4 digits, link it.
   - Otherwise return `needsProduct` with issuer, digits and up to 3 product suggestions from `LocalCardDiscoveryEngine` (read-only call). WP-15 then opens the existing add-card flow prefilled.
6. **`InstrumentStore`** on the WP-01 schema:
   - upsert by key, get by id, list by status and by kind
   - mark dirty and clean (for sync)
   - every query scoped to the account namespace
7. **`bankAccountSummariesFromInstruments()`** returns today's `BankAccountSummary` type, so the current Home and account screens render unchanged when WP-14 wires it in.

**Tests:**

- each matching step, including ambiguous candidates and never merging across issuers
- a card and an account with the same digits stay separate
- snapshot ordering by time rather than arrival order
- a user-entered limit is never overwritten, while a limit enhancement updates an SMS-learned limit
- points updates
- seeding from `user_cards` and bank summaries, twice in a row
- store round-trip and namespace isolation
- a UPI-app sender does not create a bank account

**Done when:**

- [ ] Instrument accuracy is at least 99% on the golden scenarios.
- [ ] Every account and card in the probe cases resolves correctly, including the Axis `XX123456`, Kotak `AC X1234` and ICICI `Acct XX1234` formats.
- [ ] The adapter returns the same summaries as today wherever today's answer is correct.

**Out of scope:** screens (WP-15), upload and sync (WP-14), and the server table (WP-08).

## WP-05 Event linker

**Goal:** join the messages that describe one real-world thing into one event, so nothing is counted twice and holds never count as money spent. Double counting is fixed here and nowhere else.

**Milestone** M1 · **Depends on** WP-01, WP-04 · **Model** Opus

**Owns:**

- `packages/pandapay_domain/lib/src/sms_v2/linker/`
- `app/lib/features/sms_v2/storage/event_store.dart`

**Touch points:** none.

**Build:**

1. **`RuleDrivenLinker implements EventLinker`.** `LinkContext` carries:
   - the last 120 days of facts
   - open events (`awaiting_leg`)
   - instruments by id
   - `instrumentIdByFactId`

   Process incoming facts in a fixed order: `occurredAt ?? observedAt`, then `factId`.
2. **Who takes part:** `movement`, `hold` and `mandate` facts. `attempt`, `reward`, `balance_snapshot`, `limit_change`, `bill_due` and `instrument_hint` never create money events; the pipeline handles them separately.
3. **For each fact, try the link rules in priority order:**
   1. Does the fact match a leg of the rule?
   2. Look for the other legs, first in open events, then in unlinked facts. A candidate must satisfy the rule's join:
      - equal amount on `amountRole`, within `amountTolerancePct`
      - inside `windowHours`
      - references: with `prefer`, a candidate sharing a reference wins; with `require`, one must be shared
      - any instrument constraints
   3. **Exactly 1 candidate:** join it, appending the leg.
   4. **No candidate:** apply `singleLeg`. `complete` makes a one-leg event of the rule's type (for example a card bill payment seen only from the bank is still a transfer). `await` makes an event with status `awaiting_leg`.
   5. **2 or more candidates:** status `ambiguous`, plus a `ReviewItem` listing them.
4. **No rule matches:** create a one-fact event typed by purpose and direction:
   - `purchase` → `purchase`
   - `p2p` debit → `p2p_out`; `p2p` credit → `p2p_in`
   - `salary` and `interest` → `income`
   - `refund` → `refund`
   - `cashback` → `cashback`
   - `atm` → `atm_withdrawal`
   - `fee` → `fee`
   - `emi` → `emi`
   - `bill_payment` → `bill_payment`
   - `investment` `debit → investment; investment credit → investment_withdrawal; dividend → dividend`
   - `wallet_topup` → `wallet_topup`, except into a wallet with walletSpendVisibility partial (Amazon Pay), where it is a purchase at the wallet's merchant
   - `card_payment` → `card_bill_payment`, even when no card message ever arrives; until one names the card, the ledger sends the money to ownUnresolved credit\_card
   - `transfer` → `own_transfer` if the destination is an own instrument, otherwise `p2p_out`
   - `unknown` → `unknown`
5. **IPO holds:**
   - `hold placed` opens an `ipo_application` event (`awaiting_leg`).
   - `released` joins as `hold_released`.
   - The allotment debit joins as `hold_converted` + `debit_leg`.
   - Partial allotment: the debit is smaller than the hold, and the later release of the rest also joins.
   - The investment amount is the debit amount, never the held amount.
6. **Other cases:**
   - **Own transfer:** a debit whose `counterparty.accountMask` matches an own bank account, or whose counterparty kind is `own`. The matching credit joins when seen.
   - **Refund:** a credit with purpose `refund` links to a purchase with the same instrument and counterparty, within 120 days, of at least the refund amount. Otherwise it stays a one-leg refund.
   - **Mandate to charge:** a debit with `mandateRef`, or whose counterparty equals an active mandate's merchant, becomes `subscription_charge` with the mandate fact as `original`. One-time and IPO mandates are excluded: they join their hold as an ipo\_application instead.
   - **Duplicate notice:** the second message of `LINK-DUP-NOTIFY` joins with role `duplicate_notice`. The ledger ignores that leg.
7. **Stability:**
   - `eventId` is the anchor `factId`.
   - Re-running gives identical events, and events never lose legs.
   - `user_confirmed` events are never changed by the linker.
   - `expire(now)` turns stale `awaiting_leg` events into single-leg `complete` events.
8. **`EventStore`:**
   - upsert, get by event id, find by fact id
   - list open events within a window
   - dirty flags
   - all queries namespace-scoped
9. **Performance:** link 20,000 facts in under 5 seconds on a CI desktop, using buckets by amount and day, never all-pairs comparison.

**Receipts:**

- A `movement` with `evidenceOnly: true` (a biller's or app's "payment received" receipt) never creates an event of its own.
- `LINK-RECEIPT` joins it to the bank, card or wallet debit with the same amount within 3 days, as role `duplicate_notice`.
- On a partial-visibility wallet (Amazon Pay) it is wallet activity only: no event and no review item. Elsewhere, if no debit arrives in the window, it becomes a review item: "We saw a receipt from \<biller> for \<amount> but no payment. Add it?"

The owner's real data had at least 18 such receipts booked as extra spends today.

**Tests:**

- each link rule, positive and negative
- legs arriving in either order
- a leg arriving after the window
- partial IPO allotment
- a refund larger than the purchase stays unlinked
- a duplicate notice across a bank and a UPI app
- ambiguity creates a review item
- an idempotent re-run
- `user_confirmed` events are untouched
- the performance budget

**Done when:**

- [ ] Zero double counts across the golden scenarios.
- [ ] At least 98% of expected pairs are linked.
- [ ] Every probe scenario (card bill, wallet top-up, IPO block and release, IPO allotment) gives the expected events.

**Out of scope:** totals (WP-06), categories (WP-07), and screens for ambiguous events (WP-15).

## WP-06 Ledger and projections

**Goal:** turn events into ledger entries, and make every total, count, balance, subscription and bill on screen come from one set of functions. Existing screens and the rewards engine keep their data types; only the source changes.

**Milestone** M1 · **Depends on** WP-05, WP-07 · **Model** Sonnet

**Owns:**

- `packages/pandapay_domain/lib/src/sms_v2/ledger/`
- `app/lib/features/sms_v2/ledger/`: projection writer and adapters
- `app/lib/features/sms_v2/storage/ledger_store.dart`
- the totals call sites as hotspot owner, all behind the flag: `app/lib/features/activity/activity_projection.dart`, the Home summary, Insights spending and category breakdown, subscriptions, bills, and card usage

**Touch points:**

- `app/lib/data/user_cards_repository.dart`: add `TxnEntryKind.refund('refund', 'Refund')` and `TxnEntryKind.unknown('unknown', 'Unknown')`; make `fromJson` fall back to `unknown` instead of `spend`; update every exhaustive `switch`. Old screens treat `refund` and `unknown` as excluded from totals. With the flag off they never occur, which a test proves.
- Each totals call site gets `if (ref.watch(smsPipelineV2EnabledProvider)) <ledger> else <today>`, and nothing else.

**Build:**

1. **`DefaultLedgerProjector implements LedgerProjector`**, following the Contracts tables:
   - **Card bill, wallet top-up, own transfer:** one own → own entry, `countsAsTransaction: false`.
   - **Hold-only IPO:** no entries.
   - **Converted IPO:** own bank → broker (or external issuer) for the debit amount, with `isInvestment`.
   - **Refund:** external → own, which reduces its category's spend.
   - **`duplicate_notice` legs** are ignored.
   - **Wallet spend:** own wallet → external, a spend. A top-up into a partial-visibility wallet (Amazon Pay) is own card or bank → external (the wallet's merchant, AMAZON), a spend in category online; that wallet's balance payments never create entries.
   - **Category** only on spend entries, taken from the `CategoryDecision`.
2. **`totals(entries, events, from, to)`** returns `Totals`: spend net of refunds, refund, income, investment, transaction count, and spend by category, exactly as defined in Contracts.
3. **Projection writer.** Each event that becomes a `transactions` row (Contracts table) is written as a `TransactionEntry`:
   - id `v2:<eventId>`, the anchor `sourceKey`, amount, `occurredAt`
   - merchant (counterparty display name) and category
   - `TxnInstrument` from the instrument kind: credit card → `creditCard`, debit card → `debitCard`, bank account → `upiBank`, wallet → `wallet`, otherwise `other`
   - `cardLast4` and `userCardId` from a linked credit card, so the rewards engine sees it
   - `accountLast4`, `entryKind`, status `active`, plus `pipelineVersion: 2` and `eventId`

   It writes through the existing local transaction store, so the Activity screen and server fetch-merge work unchanged.
4. **Adapters** that return the types today's screens already use (find them with `grep -rn "subscriptions_screen\|local_commitments\|credit_utilization" app/lib`):
   - `subscriptionsFromLedger()`: series from `mandate` facts plus `subscription_charge` events, excluding one-time and IPO mandates, with status active, cancelled, failed payment or lapsed, and past subscriptions kept; cadence from the mandate frequency, else the median interval; next expected date; last amount.
   - `billsFromFacts()`: `bill_due` facts mapped to the existing bills and commitments model. A bill is marked paid when a `card_bill_payment` or `bill_payment` event for that instrument follows it.
   - `cardUsage(instrument)`: limit − latest available credit, or unknown. investmentsSummary(): per platform, money put in, money taken out, net invested, latest fund balance and dividends. ipoApplications(): each IPO event with company, amount, platform, account and status. moneyIn(period): salary, dividends, refunds, cashback and money from people, never own transfers. Salary = credits from the same payer key in at least 2 consecutive months within ±7 days of the same day, or confirmed once by the user.
   - `CardStateAdapter`: pushes the SMS-learned credit limit and points balance to the linked `user_cards` row through `UserCardsRepository`, never overwriting values the user typed.
5. **`LedgerStore`:** upsert entries by event, list by period, and dirty flags.

**Tests:**

- the projector for each event type, including the four probe scenarios
- totals maths, including refund netting
- the Activity count excludes transfers
- card usage with and without a limit
- the writer's mapping, field by field
- widget tests for the Activity summary and Home with the flag on and off; flag-off output must equal today's
- `TxnEntryKind.fromJson('something-new')` returns `unknown`
- the subscription and bill adapters

**Done when:**

- [ ] The golden scenarios' expected totals match 100%: spend, income, investment, count and by-category.
- [ ] Every flag-off test is unchanged.
- [ ] No screen computes a total itself when the flag is on (checked in review with `grep` for `entryKind ==` in feature code).

**Out of scope:** linking (WP-05), category choice (WP-07), and new screens (WP-15).

## WP-07 Category resolver and taxonomy

**Goal:** one category resolver with one precedence order, used for every spend no matter how it was parsed. It matches on the merchant only, never on the whole message, and learns only from categories the user confirmed.

**Milestone** M1 · **Depends on** WP-01 · **Model** Sonnet

**Owns:**

- `packages/pandapay_domain/lib/src/sms_v2/category/`: resolver, `merchantKey`, `TaxonomyRegistry`
- `app/lib/features/sms_v2/category/`: adapters for user rules and confirmed history

**Touch points:** none. The category slug list in WP-01's `ledger_entry` schema is the contract, and a test checks the registry matches it.

**Build:**

1. **`TaxonomyRegistry` v1 (Dart const):**
   - The current 15 spend slugs: `groceries`, `fuel`, `dining`, `online`, `travel`, `bills`, `rent`, `insurance`, `education`, `government`, `wallet`, `entertainment`, `health`, `emi`, `other`.
   - Each has a display name, an icon key and a deprecated-alias map.
   - `income` and `investments` are event types, not spend categories.
   - `categoryIdForSlug(slug)` maps to today's category ids through the existing category catalogue, so stored rows stay compatible.
2. **`merchantKey(counterparty)`:**
   - upper case
   - strip legal suffixes (PVT LTD, LIMITED, LLP)
   - apply `merchantAliases` from the bundle (for example `AMAZON PAY IN` → `AMAZON`)
   - for a UPI ID, use the alias table first, then the readable local part

   Person names never become merchant keys.
3. **`DefaultCategoryResolver implements CategoryResolver`.** The first hit wins:

| Order | Source | Confidence |
| --- | --- | --- |
| 1 | The user's own rule for this merchant key (with sender and context when the rule is contextual), from `user_merchant_category_rules` and v2 corrections | 1.0 |
| 2 | Bundle category rules with source `admin` or `shared` (merchant key, optional sender and context tokens), by priority | 0.95 |
| 3 | Bundle category rules with source `catalogue`: whole-token match on the merchant key only, longest match wins | 0.9 exact, 0.8 token |
| 4 | Confirmed history: a category the user confirmed or corrected before for this merchant key; never one that was only assigned automatically | 0.85 |
| 5 | The AI suggestion carried on an AI fact | 0.6 |
| 6 | `other`, flagged uncertain | 0 |

4. **Ambiguous brands** (for example INDIGO the airline and INDIGO PAINTS) need a context token or sender in the rule; without one they resolve to `other`.
5. **Scope:** only spend events get a category. A refund takes its linked purchase's category, or runs the resolver on its own counterparty. `p2p_out` stays `other` unless the user has a rule.
6. **App adapters:**
   - read the existing `user_merchant_category_rules`
   - read confirmed history from the ledger (`categorySource` of `user` or `history_confirmed`)
   - write new user choices to the same `user_merchant_category_rules` store, plus a correction through WP-12
7. **Server:** no category logic. It stores slugs. The old server resolver stays only for old app versions until WP-17.

**Tests:**

- the precedence order, one case per row
- the collisions from the audit:
  - KUBER HARDWARE is not travel
  - SPARK ELECTRICALS is not groceries
  - SHELLY BOOK STORE is not fuel
  - UBER EATS is dining
  - SWIGGY INSTAMART is groceries
  - an Amazon purchase on a card is `online`, not `wallet`
- a brand in a footer is ignored
- automatic history never wins
- a contextual user rule applies only in its context
- an ambiguous brand gives `other`
- a refund inherits its purchase's category
- the registry matches the contract enum

**Done when:**

- [ ] Category accuracy is at least 95% on the golden set.
- [ ] Every audit collision is fixed.
- [ ] Every spend event in the golden scenarios carries a category source.

**Out of scope:** new categories (not in this release), and the category picker screens.

## WP-08 Server facts ingestion v2

**Goal:** the server accepts the phone's facts, instruments, events and ledger entries in batches, validates them, stores them with set-based SQL, and keeps `transactions` (and card rewards state) correct. The server never parses SMS text on this path.

**Milestone** M1 · **Depends on** WP-01 · **Model** Sonnet

**Owns:**

- `api/src/sms_v2/{index,guard,facts_route,sync_route,storage}.js`
- `api/test/sms_v2/` (its own files)
- `api/scripts/check_sms_v2.js`, `api/scripts/bench_sms_v2_facts.js`
- `db/supabase/migrations/2026111*_sms_v2_core.sql` and `db/tests/2026111*_sms_v2_core_test.sql`

**Touch points:**

- `api/src/index.js`: one line, `require('./sms_v2').registerSmsV2(app, deps)`, next to the other route registrations.
- `api/package.json`: append `&& node scripts/check_sms_v2.js` to `check`.
- `.github/workflows/build-and-test.yml`: one line in the smoke job to run the new SQL test.
- If the card-state update inside `insertTransactionAndUpdateState` cannot be called from outside `index.js`, extract it unchanged into `api/src/card_state.js` and call it from both places. Existing tests must pass untouched.

**Build:**

1. **Registration and hooks.** `registerSmsV2(app, deps)` registers routes and holds a hook object with safe defaults, so other packages plug in later without editing these files:
   - `security.checkRate(req, routeKey, units)` (allow)
   - `security.verifyAttestation(req)` (allow)
   - `aiResultsSince(profileId, cursor)` (empty), correctionStatusSince(profileId, cursor) (empty), afterEventsStored(client, profileId, events) (no-op, called inside the batch transaction)
   - `latestBundleVersion(profileId)` (0)

   WP-09, WP-10, WP-12 and WP-13 each add one registration line in `api/src/sms_v2/index.js`.
2. **`requireSmsV2`** returns `404` unless the `sms_pipeline_v2_enabled` flag is on, reusing the flag reader in `api/src/sms_observation_migration.js` (read the `feature_flags` shape in `db/supabase/migrations/0009_platform_ops.sql`).
3. **Migration `sms_v2_core`:**
   - the `sms_v2_instruments`, `sms_v2_facts`, `sms_v2_events` and `sms_v2_ledger_entries` tables from Contracts → Storage
   - `transactions.event_id` and `pipeline_version`, plus a unique index on `(profile_id, event_id) where event_id is not null`
   - `refund` allowed in the `entry_kind` check
   - row-level security exactly as in `0011_rls_policies.sql`
4. **`POST /sms/v2/facts:batch`:**
   - Validate with `contracts.validateRequest`. Refuse more than 500 items or over 1 MB, and reject `info` facts.
   - Write everything in one database transaction per request, using `jsonb_to_recordset` bulk statements, never one query per item.
   - **Facts:** insert with `ON CONFLICT DO NOTHING`; a conflict returns `duplicate`.
   - **Instruments:** upsert by id. A different id for an existing key returns `rejected: instrument_key_conflict` with the existing id; the phone adopts it (WP-14).
   - **Events:** upsert, and legs only grow. Allowed status changes: `awaiting_leg` → `complete` or `ambiguous`; `ambiguous` → `complete`; anything → `user_confirmed`. Nothing leaves `user_confirmed`. Every leg must reference a fact in the request or already stored for the profile.
   - **Ledger entries:** upsert by id. The amount of an own → own entry must equal its leg amount.
5. **`transactions` projection.** For each event that maps to a row (Contracts table), upsert `transactions` by `event_id`:
   - `pipeline_version = 2`, `entry_kind`, amount, merchant
   - `category_id` from the slug
   - `user_card_id` from the instrument
   - `occurred_at` and the anchor `source_key`

   For a card spend, apply card rewards state once through the card-state function, never for `backfill: true` requests, matching today's backfill rule.
6. **`GET /sms/v2/sync`:**
   - The cursor is an opaque `(updated_at, id)` per entity.
   - It returns the profile's instruments, events and ledger changes, plus `aiResults`, corrections and `latestBundleVersion` from the hooks.
   - At most 1,000 rows per entity per call, with `hasMore`.
7. **Benchmark:** a 500-item batch in under 1 second p95 on local Docker Postgres with 1 million stored facts.

**Tests:**

- every invalid fixture is rejected with its code
- duplicates
- instrument key conflict
- event leg growth and the status rules, including immutable `user_confirmed`
- the `transactions` mapping for each event type
- card state applied exactly once and never for backfill
- sync paging and cursors
- a disabled flag returns `404`
- batch limits
- SQL test: user A cannot read user B's rows

**Done when:**

- [ ] All tests pass, including the SQL test in CI.
- [ ] The benchmark meets its budget.
- [ ] The old routes behave exactly as before (the existing suite passes untouched).

**Out of scope:** rules (WP-09), AI (WP-10), corrections (WP-12), and real rate limits and attestation (WP-13 plugs into the hooks).

## WP-09 Rule service v2

**Goal:** rules live in the database and reach phones as signed bundles, rolled out by cohort, paused automatically when corrections rise, and rolled back in one call. No app release or backend deploy is needed to change a rule.

**Milestone** M1 · **Depends on** WP-01, WP-02 (the bundle shape and the CLI `build` output) · **Model** Sonnet

**Owns:**

- `api/src/sms_v2/{rules_route,rules_admin_route,bundle_builder,signer,rule_stats}.js`
- `api/scripts/import_sms_v2_rules.js` and `api/scripts/run_sms_v2_rule_jobs.js`
- the migration `2026111*_sms_v2_rules.sql` and its SQL test
- its tests and canonical-JSON test vectors in `api/test/sms_v2/fixtures/canonical/`

**Touch points:** one registration line in `api/src/sms_v2/index.js`, which also sets the `latestBundleVersion` hook.

**Build:**

1. **Migration:**
   - `sms_v2_rules`, `sms_v2_bundles`, `sms_v2_rule_cohorts` and `sms_v2_rule_stats_daily` from Contracts
   - `sms_v2_rule_stats_profile_daily` (kept 48 hours, then rolled up)
   - `sms_v2_testers(profile_id)`
   - admin-only RLS on the rule tables; stats are written only through a security-definer function
2. **Import:** `import_sms_v2_rules.js` takes the CLI `build` output and inserts every rule as version 1 on cohort `all`, builds and signs bundle 1, and marks it active. It is idempotent.
3. **Cohorts:**
   - A profile is `testers` if it is in `sms_v2_testers`.
   - Otherwise its bucket is `sha256(profileId) mod 100`: below 5 is `pct5`, below 25 is `pct25`, the rest are `all`.
   - Visibility nests: testers see pct5, pct25 and all; pct5 sees pct25 and all.
4. **Bundle builder:**
   - For each cohort, take each rule's newest version visible to that cohort, skipping paused versions; a paused version falls back to the previous one.
   - Produce canonical JSON (keys sorted, no whitespace, UTF-8) and its SHA-256.
   - A new `bundle_version` is minted only when the manifest changes.
5. **Signer:**
   - Ed25519 via `crypto.sign(null, data, key)`.
   - The key comes from `SMS_RULES_SIGNING_KEY` (PEM) and `SMS_RULES_KEY_ID`. It is never logged, and the route refuses to start in production without it.
   - Commit test vectors (input JSON, canonical bytes, SHA-256, signature from a test key). WP-13's Dart verifier uses the same vectors.
6. **`GET /sms/v2/rules?since=`:**
   - Passes through `requireSmsV2`, then the security hooks (`verifyAttestation`, and `checkEntitlement` with a default of allow).
   - Picks the cohort and returns the gzip bundle when newer, else `304`.
   - Sets `expiresAt` to 7 days ahead, with an `ETag`.
7. **Admin routes from Contracts:**
   - **List** joins 7-day metrics.
   - **Draft** validates the rule against the schema, compiles each regex in JS, and refuses dialect violations.
   - **Publish** needs a `goldenReport` produced by the console (WP-11) or the CLI. Its `bundleSha256` must equal the hash of the candidate bundle, and its metrics must meet `gates.json`.
   - **Pause** stops a version in its cohort.
   - **Rollback** republishes an older body as a new version on cohort `all`.
   - Every action writes `admin_audit_log`.
8. **`POST /sms/v2/rule-stats:batch`:**
   - Upserts profile-level daily rows.
   - The rollup job folds them into `sms_v2_rule_stats_daily`, counting distinct devices, and deletes profile rows older than 48 hours.
9. **Auto-pause job** (in `run_sms_v2_rule_jobs.js`, hourly):
   - **Condition:** a version on `testers`, `pct5` or `pct25` with at least 50 hits in 24 hours, and a correction rate above the larger of 1% and twice the previous version's rate.
   - **Action:** it is paused with reason `auto_correction_rate`, and the metrics endpoint flags it.
   - **Scheduling:** document the cron entry in the handoff note; deployment configuration is out of scope.

**Tests:**

- cohort assignment is deterministic
- bundle composition with a paused version and its fallback
- canonical JSON and signature round-trip on the vectors
- the `304` path
- publish refused without a matching passing report
- rollback creates a new version
- the stats upsert and rollup
- auto-pause thresholds, including the 50-hit minimum
- admin auth required
- `404` with the flag off

**Done when:**

- [ ] Bundle 1 imports from the WP-03 output and verifies with the dev public key.
- [ ] A draft can be published to testers, promoted to all, paused and rolled back in an integration test, with a bundle change visible at each step.
- [ ] All tests pass, including the SQL test.

**Out of scope:** the admin screens (WP-11), AI drafting (WP-10), and phone-side verification (WP-13).

## WP-10 AI per template

**Goal:** an unknown message format costs one AI call in total, not one per message, and AI never sees real values. AI drafts a provisional rule from a redacted template. The phone runs that rule on the real message, the user confirms once per format, and an admin can promote the rule to everyone.

**Milestone** M2 · **Depends on** WP-09 · **Model** Sonnet

**Owns:**

- `api/src/sms_v2/{ai_templates,template_worker}.js` and tests
- the migration `2026111*_sms_v2_templates.sql` (`sms_v2_unknown_templates` and `sms_v2_template_submitters(template_hash, profile_id)`) and its SQL test

**Touch points:** one registration line in `api/src/sms_v2/index.js`, which also sets the `aiResultsSince` hook. Do not edit `gemini_worker.js` or `ai_provider_quota_route.js`: they serve the old path until WP-17.

**Build:**

1. **`POST /sms/v2/unknown-templates`:**
   - Requires `sms_shared_learning` consent and the security hooks.
   - The server re-checks the redaction and rejects the item if it finds a digit run of 6 or more, an email, a phone number or a URL.
   - It upserts by `templateHash`, counting `seen_count` and distinct profiles, and records the submitter.
   - Each profile may submit at most 50 a day.
2. **Queue and priority.** One job per template hash. The worker picks the most distinct profiles first, then templates with `live: true` (received in the last 24 hours), then the oldest. Capacity comes from `SMS_V2_AI_RPM` (default 60) and `SMS_V2_AI_TPM`; nothing is hard-coded.
3. **Prompt.** Gemini receives:
   - the redacted body and sender brand
   - a compact summary of the fact contract
   - up to 5 existing rules for that brand as examples

   It must return JSON: one Rule with `status: "provisional"`, `createdBy: "ai:<model>"` and `match.templateHash` set to the hash. It must also return 2 positive examples with fresh synthetic values and 2 near-miss negatives.
4. **Validation, then at most one repair pass:**
   - the bundle schema for a single rule
   - the regex dialect
   - the regex compiles in JS and matches the redacted sample after its placeholders are filled with synthetic values
   - every `from` group exists
   - emitted fact types are consistent with the template's family words, so a "blocked" message cannot emit a `movement`

   A failure after the repair pass gives `ai_status = failed`, and the message stays an ordinary review item.
5. **Delivery.** `aiResultsSince(profileId, cursor)` returns `{templateHash, rule}` for the templates this profile submitted. The phone keeps them as a private overlay, and the engine applies a rule with `match.templateHash` only to messages with that hash.
6. **Admin.**
   - `GET /admin/sms/v2/templates` lists templates with counts, status and draft.
   - `POST /admin/sms/v2/templates/:hash/draft` copies the provisional rule into a WP-09 draft, for golden testing and publishing to everyone.
7. **Cost record.** Store the model, token counts and latency per job. `GET /admin/sms/v2/metrics` reports AI spend per day.

**Tests:**

- an unredacted body is rejected
- consent is required
- dedupe by hash, and distinct profile counting
- the per-profile daily cap
- priority order
- the prompt is built without real values
- validation and the single repair (with a mocked provider)
- `aiResultsSince` returns rules only to submitters
- promoting to a draft

**Done when:**

- [ ] With a mocked provider, an unknown template goes from submission to a provisional rule on the submitting device's sync, and then to an admin draft, in an integration test.
- [ ] No real value ever reaches the provider: a test asserts on the prompt.
- [ ] Capacity is configurable, with no hard cap in code.

**Out of scope:** the screen where the user confirms a format (WP-15), and the console screens (WP-11).

## WP-11 Admin Rules page and corrections UI

**Goal:** an admin can see every rule with its live numbers, fix a tester's case, prove the fix on the golden set in the browser, and roll it out by cohort. All of it happens in the console, with no deploy.

**Milestone** M2 · **Depends on** WP-09, WP-12 (endpoints) · **Model** Sonnet

**Owns:**

- `console/lib/features/sms_rules/`
- `console/lib/data/sms_v2_admin_api.dart`
- `console/tool/copy_golden.dart`
- the console navigation entries (hotspot owner of `console/lib/main.dart` routes)

**Touch points:** `console/pubspec.yaml` adds the `assets/sms_golden/` entry.

**Build:**

1. **Rules table:**
   - **Columns:** rule ID and name; bank and sender; template preview (the first positive example as a skeleton); fact types produced; source; status and cohort; version, changed by and changed on; 7-day hits, review rate and correction rate; golden cases covering it.
   - **Filters:** status, family, sender, text search.
   - **Sorts:** by hits, by correction rate.
2. **Rule detail:**
   - version timeline with a JSON diff between versions
   - cohort history
   - 7-day and 30-day metric charts
   - examples and the golden cases that use the rule
3. **Editor:**
   - JSON editor validated by the domain contract and `engine/lint.dart`.
   - Message tester: paste a message and the domain engine runs in the browser to show the facts. A banner says: synthetic or redacted text only; nothing leaves the browser.
   - Example management.
4. **Golden runner in the browser:**
   - `tool/copy_golden.dart` copies `tools/sms_golden/{cases,scenarios}` into console assets at build time.
   - The runner builds the candidate bundle (active bundle plus draft), scores it, and produces a report with `bundleSha256`, metrics and failures.
   - The report is attached to publish.
5. **Publish flow:**
   - The admin picks a cohort and gives a reason, with the golden report shown.
   - Promotion goes testers → pct5 → pct25 → all, with each cohort's numbers shown.
   - Pause and rollback ask for confirmation.
   - Publish is disabled without a passing report.
6. **Templates (WP-10):** a list with counts, AI status and the provisional rule, plus "Create draft".
7. **Corrections (WP-12):**
   - Cases are grouped by template, showing count, correction kinds, a redacted sample, the trace (stage, rule and version) and the testers affected.
   - **Data fix** opens the editor with the returned draft.
   - **Code fix** downloads the golden case JSON and copies `sms-fix-case <caseId>` to the clipboard.
   - **Not a bug** needs a reason.
8. **Metrics:**
   - golden score per bundle
   - review rate and correction rate
   - AI spend per day
   - rules paused automatically

**Tests:**

- widget tests for table filters and sorts
- editor validation errors
- the golden runner on a tiny fixture set (pure Dart)
- the publish button stays disabled without a passing report
- each correction action calls the right endpoint (mocked API)

**Done when:**

- [ ] An integration test with a mocked API goes from a correction case to a rule published to testers, entirely in the console.
- [ ] `flutter analyze` is clean for the console.
- [ ] The rules table loads 2,000 rules smoothly (paged or virtualized).

**Out of scope:** the server endpoints (WP-09, WP-10, WP-12).

## WP-12 Correction trace and `sms-fix-case` skill

**Goal:** every correction a tester makes is applied on their phone at once, and reaches the admin with the exact stage and rule that went wrong. Each admin decision turns it into a rule draft or a ready-to-fix golden case, and a project skill lets any agent fix a code case the same way every time.

**Milestone** M2 · **Depends on** WP-00, WP-08 · **Model** Sonnet

**Owns:**

- `api/src/sms_v2/corrections_route.js`
- `api/scripts/export_sms_v2_case.js`
- the migration `2026111*_sms_v2_corrections.sql` and its SQL test
- `app/lib/features/sms_v2/pipeline/trace.dart`
- `app/lib/features/sms_v2/corrections/`: the service that applies corrections locally
- `app/lib/features/sms_v2/sync/corrections_sync.dart`
- `.claude/skills/sms-fix-case/`

**Touch points:** one registration line in `api/src/sms_v2/index.js`, which also sets the `correctionStatusSince` hook.

**Build:**

1. **`DecisionTrace` for a source key:**
   - versions: app, engine, bundle
   - the winning rule and its version, and the outcome
   - fact types and amount roles
   - each instrument decision, with the matching step used
   - the event's link rule and legs
   - the category source and rule

   The trace holds no message text.
2. **Stage attribution from `correctionKind`:**

| Correction kind | Stage |
| --- | --- |
| `not_financial` | `gate` if an ignore rule or the gate decided, otherwise `extraction` |
| `wrong_kind`, `wrong_amount`, `wrong_date`, `wrong_merchant` | `extraction` |
| `wrong_instrument` | `instrument` when the extracted mask was right, otherwise `extraction` |
| `wrong_link`, `duplicate` | `linking` |
| `wrong_category` | `category` |
| `missing` | `gate` (capture receipts attached) |
| `preference_only` | none; not sent for review |

3. **`CorrectionsService.apply(correction)` (local effect first, then upload):**
   - **Category:** saved as a user rule (the WP-07 store).
   - **Not financial:** a user ignore rule for that template in the existing `user_sms_ignore_rules`, and the event is removed from the ledger.
   - **Amount, date or merchant:** a `user` fact replaces the rule fact in its event.
   - **Instrument:** the fact is reassigned.
   - **Link:** the event becomes `user_confirmed` with the corrected legs.

   The ledger is then re-projected for the affected events only.
4. **Redaction on the phone:** use `redact()` from WP-00's template module. The redacted template is attached only with `sms_shared_learning` consent; without consent the case carries the trace and the kind only.
5. **`POST /sms/v2/corrections`:**
   - Validate the request.
   - Recompute `templateHash` from the redacted template; it must match the client's.
   - Flag cases from `sms_v2_testers`.
6. **Admin endpoints from Contracts:**
   - **List:** grouped by template hash, or by stage when there is no template.
   - **`data_fix`** returns a prefilled draft. With a template, that is a rule whose pattern comes from the skeleton (escaped, with placeholders as named groups) and whose emit comes from the corrected roles. For category cases, it is a category rule.
   - **`code_fix`** returns a golden case JSON built from the redacted message and the corrected fields.
   - **`not_a_bug`** closes the case with a reason.
   - Every decision writes `admin_audit_log`. `correctionStatusSince` lets the tester's phone show "Fixed" or "Not a bug".
7. **Export script:** `export_sms_v2_case.js <caseId>` downloads a code-fix case with `SMS_ADMIN_TOKEN`.
8. **Skill `.claude/skills/sms-fix-case/SKILL.md`:**
   - **Description:** "Use when fixing an SMS classification correction case marked Code fix in the admin console."
   - **Steps:**
     1. Export the case into `tools/sms_golden/cases/_corrections/<caseId>.json`.
     2. Run `golden --only <caseId>` and confirm it fails at the recorded stage.
     3. Find the owner: `gate` → ignore rules; `extraction` → rule JSON, or `engine/` for a transform bug; `instrument` → `instruments/`; `linking` → `link_rules.json` or `linker/`; `category` → `category_rules.json` or `category/`; `sync` → the phone's `sync/` or `facts_route.js`.
     4. Prefer a rule or data fix over code. Never add issuer-specific code.
     5. Make the smallest change.
     6. Run every suite in the playbook, plus `golden --baseline` with no metric dropping.
     7. Write the PR with the case id, stage, root cause, fix and evidence.
   - **Rule:** never paste real message text.

**Tests:**

- one test per row of the stage table
- each local effect in `CorrectionsService`
- an offline correction queues and uploads later
- server validation and template hash check
- grouping
- each decision's output shape
- the SQL row-level security test
- the skill file has valid frontmatter

**Done when:**

- [ ] A correction made on the phone changes the screen immediately and appears in the admin list with the right stage.
- [ ] Both decision types produce usable output in an integration test.
- [ ] The orchestrator dry-runs the skill on one sample case at the M2 gate.

**Out of scope:** the console screens (WP-11), and the phone screens where a correction is made (WP-15).

## WP-13 Security

**Goal:** a modified app or a script cannot run up costs, poison shared learning or push fake rules. A user's own data stays theirs, and rule downloads are proven to come from the server. The subscription gate is ready to switch on later without rework.

**Milestone** M2 · **Depends on** WP-08, WP-09 · **Model** Sonnet

**Owns:**

- `api/src/sms_v2/security.js`, `api/test/sms_v2/security.test.js`
- the migration `2026111*_sms_v2_security.sql` (`sms_v2_rate_counters`)
- `app/lib/features/sms_v2/sync/{bundle_verifier,rule_keys,attestation}.dart` and their tests
- `docs/sms-pipeline-v2/runbooks/signing-keys.md`

**Touch points:**

- `app/pubspec.yaml`: add `firebase_app_check`.
- Android and iOS App Check setup in the platform files that Firebase documents. Keep it minimal, and do not touch the Shortcut or SMS native code.
- One registration line in `api/src/sms_v2/index.js` that sets the `security.*` hooks.

**Build:**

1. **Device attestation:** Firebase App Check, with Play Integrity on Android, App Attest on iOS, and the debug provider for debug builds.
   - `attestation.dart` fetches a token, caches it until near expiry, and the sync layer sends it as `X-Device-Attestation`.
   - `verifyAttestation(req)` checks the token with `jsonwebtoken` against the App Check JWKS (cached for 6 hours): issuer, audience (the project number) and expiry.
   - `SMS_V2_ATTESTATION_MODE` is `monitor` (log and lower limits) or `enforce` (reject). The release ships with `monitor`; WP-17 decides whether to switch to `enforce`.
2. **What "unverified" means:** the device keeps full access to its own data, but gets half the rate limits. Its corrections and unknown templates are stored but excluded from shared aggregates and AI drafting.
3. **Rate limits:** Postgres-backed, following the pattern in `api/src/feedback_rate_limit.js`, per profile and per device. Defaults are environment-configurable:

| Route | Limit |
| --- | --- |
| `facts:batch` | 60 requests a minute and 20,000 items a day |
| `rules` | 30 an hour |
| `sync` | 120 an hour |
| `unknown-templates` | 50 items a day |
| `corrections` | 200 a day |
| `rule-stats` | 24 a day |

Over the limit returns `429` with `Retry-After`.

4. **Bundle signature on the phone:**
   - `bundle_verifier.dart` rebuilds the canonical JSON and verifies Ed25519 with the `cryptography` package already in the app, against `rule_keys.dart` (a list of `{keyId, publicKey}` so keys can rotate).
   - A bundle that fails verification is discarded, and the last good bundle stays in use.
   - It must pass WP-09's test vectors.
5. **Entitlement hook:** `checkEntitlement(req)` returns allow while `SMS_V2_REQUIRE_ENTITLEMENT` is false. Its interface is final, so the subscription launch only fills in the check. When it is turned on:
   - `403 entitlement_required` on rules download
   - the phone keeps its last bundle and marks rule freshness stale
6. **Keys runbook:**
   - generating the Ed25519 key pair
   - storing the private key in the server's secret store
   - adding the public key to `rule_keys.dart` one release before using it
   - retiring the old key
   - what to do if the key leaks: rotate, then republish every bundle

**Tests:**

- token accepted, expired, wrong audience and missing, in both modes
- limits per route and `Retry-After`
- unverified devices are excluded from shared aggregates
- signature vectors pass, and a tampered byte fails
- key rotation: an old key still verifies until it is removed
- the entitlement hook in both settings

**Done when:**

- [ ] A script without a valid token gets lower limits in `monitor` and is rejected in `enforce`.
- [ ] A tampered bundle never reaches the engine.
- [ ] The runbook is reviewed by the orchestrator.
- [ ] `owasp-mobile-security-checker` is run over `app/lib/features/sms_v2/` with no high findings.

**Out of scope:** the subscription product itself, and per-device bundle encryption and watermarking (only when the subscription launches).

## WP-14 Phone pipeline wiring and batched sync

**Goal:** with the flag on, every captured message flows through the new pipeline on the phone, and every network call is batched. The old parser, the per-message uploads and the 90-second AI polling are not used. With the flag off, nothing changes.

**Milestone** M2 · **Depends on** WP-02, WP-04, WP-05, WP-06, WP-07, WP-08 · **Model** Opus

**Owns:**

- `app/lib/features/sms_v2/pipeline/`
- `app/lib/features/sms_v2/sync/` (except the WP-12 and WP-13 files)
- `app/lib/features/sms_v2/storage/{fact_store,outbox_store,bundle_store,stats_store}.dart`
- `app/lib/features/sms_v2/providers/`
- `app/lib/app/providers.dart` (hotspot owner)

**Touch points:** `app/lib/data/local/sms_import_store.dart` gets one guarded branch. When the flag is on, a captured financial candidate goes to `SmsV2Pipeline.process` instead of `LocalSmsParser` and the legacy upload. The safety gate, source key and capture bookkeeping before that point stay exactly as they are.

**Sender format on iPhone:** in the Messages archive, sender IDs look like `YESBNK-S(smsft_fi)`. They have no operator prefix and end with an iOS filter tag. First check what string the Shortcut actually delivers to `ios_sms_intake_controller.dart` and the native spool. Then pass the raw sender into `SmsMessage`, let `normalizeSenderBrand` split off the tag, and store it as `iosFilter`. Also strip the tag before the safety gate and triage (touch point: one normalisation call at the start of classifySmsTriage in sms\_text\_hint.dart and of IosShortcutSmsBatch.looksLikeContactName). Today a tagged sender counts as a personal contact, so 1,173 of 1,197 money messages are dropped. Add a test with each tag seen: `smsft`, `smsft_fi`, `smsft_rm`, `smsft_or`, `smsfp`.

**Build:**

1. **`SmsV2Pipeline.process(message)`, in this order:**
   1. **Bundle:** use the verified downloaded bundle, else the shipped baseline, plus the provisional overlay. Recompile only when the version changes.
   2. **Interpret:**
      - `ignored`: record the decision and stats.
      - `unknown`: create a review item of kind `template` and queue the redacted template (with consent).
   3. **Store** the facts.
   4. **Resolve instruments** for each mention and apply the fact to its instrument (balances, limits, points).
   5. **Non-money facts:** `bill_due` goes to the bills adapter; `attempt` is stored with no event.
   6. **Link** to events. An ambiguous result creates a review item of kind `event`.
   7. **Money events:** resolve the category for spend events, project the ledger, and write `TransactionEntry` rows.
   8. **Low confidence:** if the rule's or event's confidence is under 0.7, add a template-level confirm review item.
   9. **Queue** facts (never `info`), plus dirty instruments, events and ledger entries, in `v2_outbox`.
   10. **Record** the decision in `sms_source_decisions` with `pipeline_version = 2`. The same message twice produces nothing new.
2. **History import:**
   - Process in chunks of 500 messages, yielding to the UI every 200.
   - Budget: 20,000 messages in under 2 minutes on a mid-range Android phone.
   - The Android background isolate keeps only capturing, as today. Processing happens on resume, and iOS Shortcut intake feeds the same pipeline.
3. **Uploads:**
   - The outbox drains in batches of at most 500 items and 1 MB gzip.
   - It runs on start, resume, network return, after an import, and every 15 minutes in the foreground.
   - Backoff runs from 30 seconds to 30 minutes.
   - On `instrument_key_conflict`, adopt the server id and rewrite local references in one transaction.
4. **Pull:** `GET /sms/v2/sync` with a cursor, on start and resume and every 15 minutes in the foreground.
   - It merges other devices' instruments, events and ledger. The server wins only for `user_confirmed` events or a newer `updated_at`.
   - It stores provisional rules in the overlay and applies correction statuses.
5. **Bundle:**
   - Download from `GET /sms/v2/rules?since=` on start (if more than 6 hours have passed) or when sync reports a newer version.
   - Verify it (WP-13), store it, recompile.
   - A failure keeps the last good bundle.
6. **Stats** upload once a day. **Unknown templates** upload in batches of at most 50.
7. **Providers** live in `features/sms_v2/providers/`: `smsV2PipelineProvider`, `smsV2SyncProvider`, `instrumentsProvider`, `eventsProvider`, `ledgerTotalsProvider(period)` and `reviewItemsProvider`.
8. **In `providers.dart`, only when the flag is on:**
   - do not start the legacy upload, the AI status timer or the AI reconcile
   - start v2 sync
   - `bankAccountSummariesProvider` reads `bankAccountSummariesFromInstruments()`

   Keep the diff small, with every change behind the flag.

**Tests:**

- an end-to-end pipeline test per message family on an in-memory database with a test bundle
- idempotency
- a bundle change triggers recompile
- outbox batching, retry and the key-conflict id adoption
- sync merge rules
- with the flag on, a mock HTTP client sees no legacy calls (`/transactions/from-sms/batch`, `/sms/facts`, `/ai/jobs*`)
- with the flag off, the existing suites pass unchanged
- the 20,000-message performance test (tagged)

**Done when:**

- [ ] Every golden scenario passes end-to-end through the app pipeline with real stores (an app-level golden test).
- [ ] On an Android emulator, using the `android-emulator` skill, importing a synthetic backup XML gives the expected Activity totals and count (screenshot in the PR).
- [ ] On the iOS simulator, a Shortcut intake smoke test passes.
- [ ] The budgets are met.

**Out of scope:** new screens (WP-15), migrating existing data (WP-16), and deleting the old path (WP-17).

## WP-15 Review and confirmation screens

**Goal:** the user confirms their accounts and cards once, answers questions about a message format once instead of per message, can see why any entry looks the way it does, and can report a problem in two taps.

**Milestone** M2 · **Depends on** WP-14 (and WP-12 for corrections) · **Model** Sonnet

**Owns:**

- `app/lib/features/sms_v2/ui/` and its widget and golden tests
- `app/lib/app/router.dart` (hotspot owner)

**Touch points:**

- the Home screen gets one banner slot and one prompt-card slot, behind the flag
- the transaction detail screen gets one "Why this?" entry, behind the flag
- the card and account detail screens get one holds-and-usage section, behind the flag

Use the app's existing theme and widgets; no new design system.

**Build:**

1. **"Accounts and cards we found":**
   - Grouped by kind, each row showing issuer, •• digits, last activity, and balance or limit.
   - Actions: Confirm, Not mine, Rename.
   - Confirming a credit card calls `InstrumentCardLinker`. On `needsProduct`, it opens the existing add-card flow prefilled with issuer and digits.
   - **Entry points:** a one-time Home banner after migration or the first import; afterwards, a non-blocking Home card whenever a new card or account is detected.
2. **Review inbox v2.** With the flag on, it replaces the Needs Review screen at the same route, so badges and deep links keep working. Sections:
   - **New message formats:** one row per template, with the user's own message (it stays on the phone) and the provisional reading when WP-10 sent one (for example "₹14,250 blocked on HDFC ••1234 for an IPO"). The buttons are Correct, Fix and Not financial, applied to every message of that format with the count shown. Fix edits kind, amount role, instrument and merchant.
   - **Is this the same payment?:** ambiguous events; pick the match, or keep them separate.
   - **Please confirm:** low-confidence events, confirmed with one tap or edited. This includes "Which card did this pay?" for a card-bill payment that names no card (for example through CHEQ), asked only when the user has more than one confirmed credit card.
   - **What is this merchant?:** only for merchants seen at least twice, or with an amount of ₹2,000 or more (configurable). The answer applies to every payment to that merchant.

   Every action goes through `CorrectionsService` (WP-12), and the inbox badge shows the open count.
3. **"Why this?" sheet** on a transaction, in plain words from the `DecisionTrace`. For example:
   - "Read with the HDFC card rule (version 4)."
   - "Matched to your HDFC bank payment on 10 Nov, so it's a card bill, not spending."
   - "Category: you chose this before."

   Below it, "Report a problem" lists the correction kinds in user language.
4. **Account and card detail:** active holds ("₹14,250 blocked for an IPO"), available balance, limit and usage (or "unknown"), and points.
5. **Bills** keep their screens and read the WP-06 adapters. Subscriptions get a list with active and past sections (cancelled, failed payments). New screens: Investments (per platform: put in, taken out, net invested, fund balance, dividends), Your IPO applications (company, amount, platform, account, status) and Money in (salary, dividends, refunds, cashback, money from people).
6. **Router:** v2 routes under `/sms-v2/` exist only when the flag is on. Needs Review keeps its path and swaps the screen.
7. **States and polish:** empty, loading and error states for every screen; accessibility labels; then a `design-polish` pass on the inbox and the found-accounts screen.

**Tests:**

- widget tests for every screen state
- Alchemist golden tests (light and dark) for the found-accounts screen, the inbox and the "Why this?" sheet
- confirming a template resolves every item of that format
- Not mine stops future matches going to totals
- card confirmation reaches the prefilled add-card route
- the "Why this?" text for each category source and link rule
- with the flag off, Needs Review is unchanged

**Done when:**

- [ ] On an emulator, this flow works with screenshots in the PR: import a synthetic backup, confirm the found accounts, clear the inbox, and see the totals update.
- [ ] The Alchemist goldens are committed.
- [ ] `flutter analyze` adds no warnings.

**Out of scope:** new categories, and any change to the old Needs Review screen (deleted in WP-17).

## WP-16 Data migration and replay

**Goal:** existing users open the new release and their history is re-checked by the new pipeline. Duplicates merge, holds leave spending, transfers leave the count, and nothing they edited, deleted or entered by hand is lost. Old rows are hidden, never deleted, so support can reverse it.

**Milestone** M3 · **Depends on** WP-14, WP-08 (and WP-04's seeder, WP-12's service) · **Model** Opus

**Owns:**

- `app/lib/features/sms_v2/migration/`
- `api/src/sms_v2/legacy_supersede.js`
- the migration `2026111*_sms_v2_supersede.sql` and its SQL test
- a synthetic legacy-database fixture for tests

**Touch points:**

- One registration line in `api/src/sms_v2/index.js`, which sets the `afterEventsStored` hook.
- Every server query that totals or lists `transactions` must exclude superseded rows. First list them all with `grep -n "FROM transactions\|JOIN transactions" api/src/*.js` and record the list in the handoff note. Where a query does not already filter on active status, add the filter; that is the only edit allowed there.

**Build:**

1. **Inventory first.** Find which local tables keep message bodies (`sms_captured_messages`, `sms_intake`), and write a coverage report: messages with a body versus legacy transactions without one. Commit the method and the numbers from the fixture.
2. **Server migration:**
   - `transactions.status` allows `superseded`
   - add `transactions.superseded_by_event_id`
   - add an admin-only function `sms_v2_unsupersede(profile_id)`
3. **`afterEventsStored`:** for each stored event, find active `pipeline_version = 1` rows of that profile whose `source_key` belongs to any of the event's legs. Set them to `superseded` with the event id. The two legacy rows of a card bill pair are both superseded by one v2 event.
4. **Replay on the phone,** once per account (state kept in `sms_v2_migration_state`):
   1. Seed instruments with `InstrumentSeeder`.
   2. Run every retained body through `SmsV2Pipeline` in history mode with `replay: true`. Uploads carry `backfill: true`, so card rewards state is never applied a second time.
   3. Carry user choices over by source key:
      - an edited category becomes a user category decision
      - an edited merchant or amount becomes a `user` fact
      - a transaction the user deleted gets the local `not_financial` effect, which is not uploaded as a correction
      - manual (non-SMS) transactions are not touched at all
   4. Pending legacy review items re-run through v2 when a body exists; otherwise they become v2 `template` review items with what is available.
   5. Legacy rows with no body stay as they are, and the report counts them.
   6. If interrupted, the replay resumes where it stopped and is idempotent.
5. **Before and after report** (local, shown once from the Home banner):
   - duplicates merged
   - holds removed from spending
   - transfers removed from the count
   - the month-by-month change in totals
   - entries that could not be re-checked
6. **Dry run:** a debug-menu action computes the report without writing anything. The owner and testers run it before release.

**Tests:**

- **The fixture,** a synthetic legacy database with a card bill pair, an IPO hold booked as an investment, edited categories, a deleted row, manual entries and pending review items, migrates to the exact expected v2 state and totals.
- **Running twice** changes nothing.
- **Resume:** an interrupted run picks up where it stopped.
- **Supersede:** marks exactly the right server rows, and `sms_v2_unsupersede` restores them.
- **Reports exclude superseded rows,** checked with an SQL test over the listed report queries.
- **Card state is applied only once,** never again on replay.

**Done when:**

- [ ] The fixture migration matches its expected totals exactly.
- [ ] Zero user edits are lost in tests.
- [ ] The owner reviewed a dry-run report on their own device before the release gate.

**Out of scope:** deleting legacy code or data (WP-17).

## WP-17 Cutover, cleanup and release

**Goal:** the release contains only the new pipeline: no flag, no dead branches and no second parser. The current production app keeps working against the old server routes until a fixed cutoff date.

**Milestone** M3 · **Depends on** every other package · **Model** Opus, with the orchestrator

**Owns:** the deletion list below, flag removal, minimum-version enforcement on the legacy routes, `docs/archive/sms-v1/`, and running the release checklist in Test and release.

**Build:**

1. **Entry gate.** Before anything is deleted, all of these must hold:
   - every package is Done
   - every gate in Test and release passes with the flag on
   - the owner has reviewed the migration dry run
   - testers have used the candidate build for at least 7 days, with a correction rate under 1% of new events
2. **Remove the flag.** Keep the v2 side of every `kSmsPipelineV2` branch and delete the other side and the flag file. `grep -rn "kSmsPipelineV2\|smsPipelineV2EnabledProvider" app/lib` must return nothing.
3. **Delete old phone code.** Before deleting any file, `grep` for its imports. If a Gmail, email or card-discovery file imports it, keep it and record why. Candidates:
   - **Parsers:** `local_sms_parser.dart`, `indian_narration_sanitizer.dart` (ported in WP-02), `flashtext_merchant_extractor.dart` (replaced by category rules), `sms_fact_scoring.dart`
   - **Old AI and review:** `local/sms_auto_resolution_controller.dart`, `needs_review_screen.dart` and `needs_review_repository.dart`, once WP-16 converts their items
   - **v1 rule bundles:** `local/sms_rule_bundle_store.dart`, `local/sms_rule_bundle.dart`
   - **The v1 learning outbox:** `local/sms_learning_feedback.dart`, replaced by WP-12 corrections
   - **In `providers.dart`:** the 90-second AI timer, the AI reconcile and the legacy upload code
   - **The bank-account derivation and its "ponytail" filters** in `financial_store.dart` and `providers.dart`
   - **The v1-only branches of `sms_import_store.dart`:** keep the gate, source key and capture bookkeeping
   - **The tests of deleted code.** Use WP-03's handoff map to show each one is covered by a golden case or a v2 test.
4. **Legacy server routes:**
   - **Kept until the cutoff:** `/transactions/from-sms/batch`, `/sms/facts`, `/ai/jobs*`, `/sms/rules/active`, `gemini_worker.js`, `sms_parser.js`, `merchant_category.js`.
   - **Cutoff:** set the date, proposed as 8 weeks after release, in `config.js`.
   - **Upgrade notice:** a middleware on those routes returns `426 Upgrade Required` for an `X-App-Version` below the first v2 version.
   - **After the cutoff,** a server-only follow-up deletes them, except anything `email_ingest.js` or other frozen Gmail code imports.
5. **Docs:** move the old SMS docs (`docs/sms-*`, `docs/SMS_*`, `smsextractionimple.md`, `TRANSACTION_CLASSIFICATION_PLAN.md`) into `docs/archive/sms-v1/`, with a README pointing to `docs/sms-pipeline-v2/`. Nothing is deleted from history.
6. **Gmail stays frozen:** none of its files, nor anything they import, is changed or deleted.
7. **Release:** run the checklist and staged rollout in Test and release. Afterwards, triage the correction queue daily and watch the metrics page for 2 weeks.

**Tests:**

- the full suite after each deletion step
- `flutter analyze` with no warnings about removed imports
- the golden set and every scenario unchanged after deletions
- the app bundle no larger than before

**Done when:**

- [ ] Nothing references the deleted files, and every suite passes.
- [ ] The `426` middleware is tested.
- [ ] Every release gate passes.
- [ ] The staged rollout has started.
