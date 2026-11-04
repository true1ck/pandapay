# Contracts

Every agent codes against this tab. Nothing here changes without a contract change request (Agent playbook). When this tab and code disagree, this tab wins and the code is the bug.

## Code layout

All interpretation logic lives once, in pure Dart inside `packages/pandapay_domain`. The phone, the admin console and the rules command-line tool all run that same code. The server never parses SMS; it validates and stores.

| Area | Path | Holds |
| --- | --- | --- |
| Shared contracts (source of truth) | `contracts/sms/v2/` | JSON Schemas: `fact`, `instrument`, `event`, `ledger_entry`, `rule_bundle`, `api/*`. Fixtures in `fixtures/valid/` and `fixtures/invalid/`. |
| Domain logic (pure Dart, no Flutter) | `packages/pandapay_domain/lib/src/sms_v2/` | `contract/` (types, `fromJson`/`toJson`, `validate`), `engine/`, `instruments/`, `linker/`, `ledger/`, `category/`. Public API exported from `lib/sms_v2.dart`. |
| Phone app | `app/lib/features/sms_v2/` | `storage/` (SQLite), `pipeline/` (orchestrator), `sync/` (batched outbox, bundle download, verification), `ui/`, `providers/`, `flag.dart` |
| Admin console | `console/lib/features/sms_rules/` | Rules page, rule editor, golden-set runner (domain engine running in the browser), correction cases v2 |
| Server | `api/src/sms_v2/` | `contracts.js` (Ajv validators built from `contracts/sms/v2`), `facts_route.js`, `sync_route.js`, `rules_route.js`, `rules_admin_route.js`, `corrections_route.js`, `ai_templates.js`, `security.js`, `storage.js`, and `index.js` exporting `registerSmsV2(app, deps)` |
| Database | `db/supabase/migrations/2026111*_sms_v2_*.sql`, `db/tests/2026111*_sms_v2_*_test.sql` | New tables, RLS, functions |
| Rule source before release | `rules/sms/v2/` | `senders`/\*.json, banks/\<issuer>.json, counterparty\_purposes`.json`, `wallets/*.json`, `investments/*.json`, `bills_mandates/*.json`, `rewards_limits/*.json`, `link_rules.json`, `category_rules.json`, `ignore_rules.json`, `merchant_aliases.json` |
| Tools | `tools/sms_rules_cli/` (Dart) | Commands: `build`, `lint`, `golden`, `cluster`, `sign-dev`, `fetch-baseline` |
| Golden set | `tools/sms_golden/` | `cases/*.json` (single messages), `scenarios/*.json` (message sequences), `templates/` (clustering output, git-ignored when built from private data) |
| Shipped baseline | `app/assets/sms_rules/baseline_bundle.json` | Built by the CLI; never edited by hand |

Where rules live: before release, `rules/sms/v2/` is the source and bundle 1 is imported from it. After release, the database is the source, edited on the admin Rules page. Each app build pulls the latest published bundle into `app/assets` with `fetch-baseline`.

## Fact contract v2

A fact is one thing a message states. A message produces zero or more facts. Facts never decide totals; the linker and ledger do.

### Envelope (every fact)

| Field | Type | Rule |
| --- | --- | --- |
| `contractVersion` | string | Always `"2.0"` in this release |
| `factId` | string | `sha256(sourceKey + "\|" + ruleId + "\|" + emitIndex)` as hex. AI facts use `ruleId = "ai:" + model`, user-entered facts `"user"`. |
| `sourceKey` | string | Today's source key from `api/src/import_source_key.js` and its Dart mirror, unchanged |
| `factType` | enum | One of the 10 types below |
| `observedAt` | ISO-8601 UTC | Message receipt time |
| `occurredAt` | ISO-8601 UTC or null | Time printed in the SMS; null when none is printed. Consumers fall back to `observedAt`. |
| `instrument` | InstrumentMention or null | Which of the user's accounts or cards the message is about |
| `counterparty` | Counterparty or null | The other side of the movement |
| `amounts` | list of Amount | At most one per role |
| `references` | map of string | Allowed keys: `upiRef`, `impsRef`, `neftUtr`, `rtgsUtr`, `umrn`, `chequeNo`, `txnId`, `asbaRef`, `orderId` |
| `attrs` | map | Type-specific fields (table below) |
| `provenance` | Provenance | Who produced the fact |
| `evidence` | list of Span | `{field, start, end}`: character offsets in the original body. Stays on the phone and is never uploaded. |
| `confidence` | number 0–1 | From the rule; AI facts carry their calibrated score |

- **Amount** = `{role, minor, unit, original?}`.
  - `minor` is an integer: paise for INR, whole points for POINTS.
  - `unit` is `INR`, `POINTS` or an ISO currency.
  - `original` = `{minor, currency}` for foreign spends.
- **Amount roles:** `posted`, `held`, `released`, `scheduled`, `due_total`, `due_minimum`, `outstanding`, `available_balance`, `available_credit`, `credit_limit`, `ceiling`, `points_earned`, `points_redeemed`, `points_balance`, `cash_value`.
- **InstrumentMention** = `{kind, issuerSlug, maskDigits, maskLength, productName, raw}`.
  - `maskDigits` holds digits only, 2–6 of them.
  - `maskLength` is the full printed length when known (for example 16).
  - `raw` is the printed token, such as `XX1234`, and stays on the phone.
  - Any field may be null.
- **Counterparty** = `{name, vpa, kind, accountMask}`.
  - `kind` is `merchant`, `person`, `own`, `bank` or `unknown`.
  - `accountMask` is the destination account's digits.
- **Provenance** = `{engine, ruleId, ruleVersion, bundleVersion, engineVersion, appVersion, model?}`, where `engine` is `rules`, `ai` or `user`.

### The 10 fact types

| `factType` | Meaning | Required amount roles | `attrs` |
| --- | --- | --- | --- |
| `movement` | Money actually moved | exactly one `posted` | `direction` (`debit`, `credit`); `purpose` (`purchase`, `p2p`, `atm`, `salary`, `interest`, `refund`, `cashback`, `reversal`, `fee`, `emi`, `card_payment`, `wallet_topup`, `investment`, `bill_payment`, `tax`, `transfer`, dividend, `unknown`); `rail` (`upi`, `card`, `imps`, `neft`, `rtgs`, `cheque`, `nach`, `wallet`, `cash`, `unknown`); `mandateRef?`; evidenceOnly? (true for a biller's or app's receipt, which never counts as money on its own) |
| `attempt` | Did not move, or not yet | `posted` or `scheduled` | `status` (`failed`, `declined`, `pending`, `scheduled`, `cancelled`); `direction`; `purpose`; `dueAt?` |
| `hold` | Money blocked, not moved | `held` or `released` | `phase` (`placed`, `released`, `converted`); `purpose` (`ipo_asba`, `upi_mandate_block`, `preauth`, `lien`, `other`); `issueName?` |
| `balance_snapshot` | A balance at a point in time | one of `available_balance`, `available_credit`, `outstanding`, `points_balance` | `asOf` |
| `limit_change` | A card or loan limit changed | `credit_limit` | `previousMinor?`; `reason` (`increase`, `decrease`, `assigned`) |
| `bill_due` | An amount owed by a date | `due_total` and/or `due_minimum` | `dueDate` (date); `statementDate?`; `billerName?` |
| `mandate` | A standing instruction changed | `ceiling` optional | `phase` (`created`, `modified`, `paused`, `resumed`, `revoked`, `expired`); `frequency?`; `merchantName?`; oneTime?; mandatePurpose? (ipo, subscription, bill, sip, loan, other). A one-time or IPO mandate never becomes a subscription. |
| `reward` | Points earned or redeemed | `points_earned` or `points_redeemed`; `cash_value` optional | `program?`; `expiresAt?` |
| `instrument_hint` | Identity only, no money | none | `hint` (`card_issued`, `card_activated`, `account_opened`, `product_name`, `linked_upi`) |
| `info` | Not financial | none | `category` (`otp`, `security`, `promotion`, `service`, `delivery`, `other`); `amountMinor?` (positive integer paise, a printed amount that is informational only and never money, CCR-002). Never stored or uploaded; only counted. |

### Invariants (checked on the phone and the server)

- `minor` is above 0, except balances, which may be 0.
- A `movement` has exactly one `posted` amount. A `hold` has a `held` or `released` amount.
- `maskDigits` contains digits only. The engine must never take a year or a date as a mask; the CLI lint has a test for this.
- `occurredAt` is at most 1 day after `observedAt`.
- `info` facts never leave the phone. Evidence spans and `raw` tokens never leave the phone.

### Mapping from today's facts (used by WP-16)

| v1 `factType` | v2 |
| --- | --- |
| `posted_movement` | `movement` |
| `pending_or_failed_attempt` | `attempt` |
| `balance_snapshot` | `balance_snapshot` |
| `bill_obligation` | `bill_due` |
| `bill_payment` | `movement` with `purpose: bill_payment` |
| `mandate_lifecycle` | `mandate` |
| `card_identity_hint` | `instrument_hint` |
| `security_or_service_alert`, `promotion` | `info` (dropped on upload) |

## Instrument, event and ledger entry

### Instrument (one per account, card or wallet the user owns)

| Field | Type | Rule |
| --- | --- | --- |
| `instrumentId` | uuid v4 | Created on the phone at detection; the server keeps the same id |
| `kind` | enum | `bank_account`, `credit_card`, `debit_card`, `prepaid_card`, `wallet`, `broker`, `loan`, `pay_later` |
| `issuerSlug` | string | From `senders.json` (for example `hdfc`, `paytm`, `groww`) |
| `maskDigits`, `maskLength` | string, int or null | Part of the identity key |
| `displayName` | string | User-editable. Default: issuer + kind + "••" + digits |
| `status` | enum | `detected`, `confirmed`, `rejected`, `archived` |
| `userCardId` | uuid or null | Link to the existing `user_cards` row, so the rewards engine keeps working unchanged |
| `parentInstrumentId` | uuid or null | Debit card or UPI handle → its bank account |
| `aliases` | `{senders, vpas, productNames}` | Lists of strings |
| `creditLimitMinor`, `creditLimitSource`, `creditLimitAt` | int, `sms` or `user`, time | A user-entered limit is never overwritten by SMS |
| `availableMinor`, `availableAt` | int, time | Latest snapshot, chosen by `occurredAt` (not arrival order) |
| `pointsBalance`, `pointsAt` | int, time | Latest points snapshot |
| `firstSeenAt`, `lastSeenAt`, `evidenceCount` | time, time, int | Detection bookkeeping |

The identity key is `(profile, kind, issuerSlug, maskDigits)`. Matching order (implemented once, in `instruments/`):

1. Exact key match.
2. If the mention has no kind: the one instrument with that issuer and mask.
3. If the mention has no mask: the one instrument with that issuer and kind.
4. Otherwise create a new `detected` instrument.

Never merge across issuers. A card and an account with the same digits stay separate, because `kind` differs. When the user rejects an instrument, later facts for that key go to review; the instrument is not deleted.

### Event (one real-world thing, possibly several messages)

| Field | Type | Rule |
| --- | --- | --- |
| `eventId` | string | The `factId` of the first (anchor) leg; never changes when more legs arrive |
| `type` | enum | `purchase`, `refund`, `cashback`, `income`, `p2p_out`, `p2p_in`, `own_transfer`, `card_bill_payment`, `wallet_topup`, `investment`, `ipo_application`, investment\_withdrawal, dividend, `atm_withdrawal`, `fee`, `emi`, `bill_payment`, `subscription_charge`, `unknown` |
| `status` | enum | `complete`, `awaiting_leg`, `ambiguous`, `user_confirmed` |
| `legs` | list | `{factId, role}`, where `role` is one of `debit_leg`, `credit_leg`, `hold_placed`, `hold_released`, `hold_converted`, `original`, `reversal`, `charge`, duplicate\_notice |
| `linkRuleId`, `confidence` | string, number | Which link rule joined the legs |
| `occurredAt`, `amountMinor` | time, int | From the earliest posted leg |

### Ledger entry (money or points moving between two places)

| Field | Type | Rule |
| --- | --- | --- |
| `entryId` | string | `sha256(eventId + "\|" + index)` |
| `eventId` | string | Owning event |
| `from`, `to` | `{instrumentId}``, {external: counterpartyKey}, or {ownUnresolved: kind} when money went to one of the user's own instruments that the SMS does not name (for example a card bill paid through CHEQ); it still counts as own to own` | `counterpartyKey` = normalised merchant, UPI ID or person name |
| `amountMinor`, `unit` | int, `INR` or `POINTS` |  |
| `occurredAt` | time |  |
| `category`, `categorySource` | slug, enum | Set when `to` is external and the event is a spend type. Also allowed on a refund entry (external to own, with `isSpend`, `isIncome` and `isInvestment` all false), where it is the category of the purchase the refund reverses (CCR-003); a standalone refund carries its resolved category or `other` with source `default`. Source is `user`, `shared`, `catalogue`, `mcc`, `history_confirmed`, `ai` or `default`. |
| `countsAsTransaction`, `isSpend`, `isIncome`, `isInvestment` | booleans | Derived from the event type, using the table below |

### Totals and counts

Screens must call the functions in `ledger/`. A screen that adds up anything itself is a bug.

| Event type | Counts as a transaction | Spend | Income | Investment | Becomes a `transactions` row as |
| --- | --- | --- | --- | --- | --- |
| `purchase`, `subscription_charge`, `fee`, `emi`, `bill_payment`, `atm_withdrawal`, `p2p_out` | yes | yes | no | no | `spend` |
| `refund` | yes | reduces that category | no | no | `refund` (new kind) |
| `cashback` | yes | no | yes | no | `income` |
| `income`, `p2p_in` | yes | no | yes | no | `income` |
| `investment`; `ipo_application` once converted | yes | no | no | yes | `investment` |
| `ipo_application` while only held or released | no | no | no | no | no row; shown as "blocked" on the account |
| `own_transfer`, `card_bill_payment`, `wallet_topup` | no | no | no | no | `transfer` (visible in history, excluded from counts and totals) |
| `unknown` | no | no | no | no | no row; goes to review |
| investment\_withdrawal (money back from a broker or fund) | yes | no | no | reduces net invested | transfer (shown in Investments) |
| dividend | yes | no | yes | shown in Investments too | income |

- **Card usage** = credit limit − latest `available_credit`. When either is missing, usage is unknown, never 0.
- **Holds** never change any total.
- **Points** stay in points. Rupee value shows only when the SMS prints a `cash_value`.

Existing consumers keep their inputs:

- **Rewards, budgets and reports** keep reading `transactions` and `TransactionEntry`. Only the writer changes: WP-06 projects events into rows.
- **`TxnEntryKind` gains `refund`.** `fromJson` stops defaulting unknown values to `spend`; it maps them to a new `unknown` kind that no total includes.

## Rule bundle JSON v2

A bundle is data, never code. The phone downloads it, checks the signature and runs it. The same file ships inside the app as the offline baseline.

### Top level

```json
{
  "schema": "pandapay.sms.rules/2",
  "bundleVersion": 1,
  "createdAt": "2026-11-20T00:00:00Z",
  "expiresAt": "2026-11-27T00:00:00Z",
  "minEngineVersion": "2.0.0",
  "taxonomyVersion": 1,
  "senders": [],
  "ignoreRules": [],
  "rules": [],
  "counterpartyPurposes": [],
  "linkRules": [],
  "categoryRules": [],
  "merchantAliases": [],
  "signature": { "alg": "Ed25519", "keyId": "sms-rules-2026-11", "value": "<base64>" }
}
```

- **Signature:** Ed25519 over the canonical JSON of the bundle without `signature` (keys sorted, no whitespace, UTF-8).
  - The phone holds the public keys in `app/lib/features/sms_v2/sync/rule_keys.dart`, as a list so keys can rotate.
  - The private key lives only in the server's secret store.
- **Expiry:** after `expiresAt` the phone keeps using the bundle but marks rule freshness stale, and refreshes on the next sync. Only WP-13's entitlement check can stop a refresh.
- **Senders:** `{"brand": "HDFCBK", "issuerSlug": "hdfc", "issuerKind": "bank", "aliases": ["HDFCCC"]}`.
  - The brand is the sender in upper case, with a 2-letter operator prefix (`VM-`) and a `-S`, `-T`, `-P` or `-G` suffix removed. On iPhone an iOS filter tag such as (smsft\_fi) comes last; it is removed first and kept as iosFilter. Wallet senders also carry walletSpendVisibility (sms or partial). With sms (Zomato Money, Pluxee, Paytm) a top-up is a transfer and each wallet purchase is the spend. With partial (Amazon Pay) a top-up counts as a purchase at the wallet's merchant, and balance-payment messages are wallet activity only: never counted, never sent to review. Gateway senders (Juspay, Pine Labs) name the real issuer in the text, so their rules set issuerSlug explicitly.
  - `normalizeSenderBrand` in `engine/` is the only implementation.

### Rule

```json
{
  "id": "HDFC-CARD-SPEND-03",
  "version": 4,
  "family": "card_spend",
  "senders": ["HDFCBK"],
  "priority": 500,
  "match": {
    "pattern": "^(?:rs\\.?|inr)\\s*(?<amt>[\\d,]+(?:\\.\\d{1,2})?)\\s+spent on hdfc bank card x(?<mask>\\d{4}) at (?<merchant>.+?) on (?<date>\\d{4}-\\d{2}-\\d{2}:\\d{2}:\\d{2}:\\d{2})\\.\\s*avl lmt:\\s*(?:rs\\.?|inr)\\s*(?<avl>[\\d,]+(?:\\.\\d{1,2})?)",
    "flags": "i",
    "requireAll": ["spent"],
    "rejectAny": ["declined", "failed", "will be debited"]
  },
  "emit": [
    {
      "factType": "movement",
      "attrs": { "direction": "debit", "purpose": "purchase", "rail": "card" },
      "amounts": [{ "role": "posted", "from": "amt", "unit": "INR" }],
      "occurredAt": { "from": "date", "formats": ["yyyy-MM-dd:HH:mm:ss"] },
      "instrument": { "kind": "credit_card", "issuerSlug": "hdfc", "maskFrom": "mask" },
      "counterparty": { "nameFrom": "merchant", "kind": "merchant", "transforms": ["sanitizeNarration"] }
    },
    {
      "factType": "balance_snapshot",
      "amounts": [{ "role": "available_credit", "from": "avl", "unit": "INR" }],
      "instrument": { "sameAs": 0 },
      "attrs": { "asOf": { "sameAs": 0, "field": "occurredAt" } }
    }
  ],
  "confidence": 0.99,
  "examples": [
    { "sender": "VM-HDFCBK-S", "body": "Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00", "expectFactTypes": ["movement", "balance_snapshot"] },
    { "sender": "VM-HDFCBK-S", "body": "Txn of Rs.499.00 declined on HDFC Bank Card x5678 at SWIGGY", "expectFactTypes": [] }
  ],
  "status": "active",
  "createdBy": "baseline",
  "updatedAt": "2026-11-20T00:00:00Z"
}
```

How the engine runs a message:

1. Normalise the sender brand.
2. Run `ignoreRules`. A match produces one `info` fact and stops.
3. Collect the rules for that brand, then generic rules (`senders: ["*"]`). Sort by `priority` descending, then `id`.
4. The first rule whose `pattern` matches and whose `requireAll` and `rejectAny` checks pass wins. Only one rule wins per message.
5. Build the facts from `emit`, run the named transforms, and attach provenance and evidence spans.
6. No rule matches: the message becomes an `unknown` review item. With consent, its redacted template goes to WP-10.

**Provisional rules** have `status: "provisional"`, `createdBy: "ai:<model>"` and an optional `match.templateHash`. A rule with `templateHash` applies only to messages with that template hash. Provisional rules reach only the users who submitted that template (WP-10), as a private overlay on top of the bundle.

Regex dialect: patterns must behave the same in JavaScript and Dart.

- **Allowed:** named groups, and flags `i`, `m`, `s`.
- **Not allowed:** backreferences, variable-length lookbehind, and nested quantifiers such as `(a+)+`.
- **Limit:** at most 2,000 characters per pattern.
- **Enforcement:** `sms_rules_cli lint` rejects violations.

Named transforms are implemented only in `engine/transforms.dart`:

- `parseAmountIndian`: the default for amounts. Handles `Rs.`, `INR`, `₹`, commas and lakh grouping, and returns paise.
- `parseDate`: tries the listed formats, interprets them in IST, and returns UTC.
- `digitsOnly`
- `sanitizeNarration`: a port of `IndianNarrationSanitizer`.
- `upperTrim`
- `vpaFromText`
- `stripTrailingRefs`

`examples` must hold at least one positive and one negative message. `build` and publish both fail when the engine's output disagrees with them.

### Link rules (parameters for the WP-05 linker)

```json
{
  "id": "LINK-CARD-BILL",
  "eventType": "card_bill_payment",
  "legs": [
    { "role": "debit_leg", "match": { "factType": "movement", "direction": "debit", "purpose": ["card_payment"], "instrumentKind": ["bank_account"] } },
    { "role": "credit_leg", "match": { "factType": "movement", "direction": "credit", "purpose": ["card_payment"], "instrumentKind": ["credit_card"] } }
  ],
  "join": { "amountRole": "posted", "amountTolerancePct": 0, "windowHours": 72, "reference": "prefer" },
  "singleLeg": "complete",
  "priority": 100
}
```

The baseline set:

| Link rule | Joins |
| --- | --- |
| `LINK-CARD-BILL` | Bank debit and card "payment received" |
| `LINK-WALLET-TOPUP` | Bank debit to a wallet top-up UPI ID and the wallet credit |
| `LINK-IPO` | Hold placed, then released or converted, then the allotment debit |
| `LINK-REFUND` | Refund to the original purchase: same counterparty and instrument, amount up to the original, within 120 days |
| `LINK-OWN-TRANSFER` | Debit whose destination mask matches an own instrument, and the matching credit |
| `LINK-MANDATE-CHARGE` | Debit carrying `mandateRef`, or naming the mandate's merchant, to its mandate |
| `LINK-DUP-NOTIFY` | Same amount and instrument within 10 minutes from two senders (for example a bank and a UPI app) |

LINK-RECEIPT joins an evidenceOnly receipt to the bank, card or wallet debit it confirms, on the same amount within 3 days; a receipt never creates money on its own. The matching algorithm is code (WP-05); link rules only set its parameters.

### Category, ignore and alias rules

```json
{ "merchantKey": "SWIGGY INSTAMART", "match": "token", "senders": ["*"], "context": [], "category": "groceries", "priority": 900, "source": "catalogue" }
```

```json
{ "id": "IGN-LIMIT-OFFER", "senders": ["*"], "pattern": "eligible for an? (?:credit )?limit (?:increase|enhancement)", "flags": "i", "reason": "promotion" }
```

```json
{ "alias": "AMAZON PAY IN", "merchantKey": "AMAZON", "kind": "marketplace" }
```

`counterpartyPurposes` run after `emit`. They may only replace a movement's `purpose` when it is `unknown`, `p2p`, `purchase` or `transfer`. For `wallet_topup` and `card_payment`, they also set `counterparty.kind` to `own`.

```json
{ "id": "CPP-PAYTM-TOPUP", "vpaPattern": "^add-money@paytm$", "namePattern": null, "purpose": "wallet_topup", "targetInstrument": { "kind": "wallet", "issuerSlug": "paytm" } }
```

```json
{ "id": "CPP-CRED", "vpaPattern": "^cred\\.club@", "namePattern": "^CRED(?: CLUB)?$", "purpose": "card_payment", "targetInstrument": { "kind": "credit_card" } }
```

```json
{ "id": "CPP-CHEQ", "vpaPattern": "^cheq[\\w.-]*@", "namePattern": "^CHEQ(?: DIGITAL)?", "purpose": "card_payment", "targetInstrument": { "kind": "credit_card" } }
```

A `card_payment` debit is a card payment on its own. If no card "payment received" message names the card, the money goes to `ownUnresolved: credit_card` and is never spending.

## API endpoints

All new routes live under `/sms/v2` and `/admin/sms/v2`.

- **Writes are idempotent by id.** A repeated item returns `duplicate`, never an error.
- **Errors** are `{"error": "<code>", "detail": "..."}`.
- **Every request needs** `Authorization`. Phone routes also send `X-App-Version` and `X-Device-Attestation` (WP-13).
- **Request bodies** are validated with Ajv against `contracts/sms/v2/api/*.schema.json`.

### Phone routes

| Route | Purpose | Request | Response |
| --- | --- | --- | --- |
| `POST /sms/v2/facts:batch` | Upload facts, instruments, events and ledger entries in one call | `{contractVersion, appVersion, deviceId, items: [{sourceKey, senderBrand, observedAt, bodyHash, facts: [Fact]}], instruments: [Instrument], events: [Event], ledger: [LedgerEntry]}`. At most 500 items and 1 MB gzip. | `{results: [{id, kind, status, errors?}], serverTime}`; `status` is `accepted`, `duplicate` or `rejected` |
| `GET /sms/v2/rules?since=<bundleVersion>` | Download the signed bundle for this user's cohort | none | `200` bundle JSON (gzip), `304` when not newer, or `403 entitlement_required` |
| `GET /sms/v2/sync?cursor=<opaque>` | Changes since the cursor: instruments, events and ledger from other devices, AI results, latest bundle version | none | `{cursor, instruments, events, ledger, aiResults, corrections, latestBundleVersion}`. Replaces per-item AI status polling. |
| `POST /sms/v2/rule-stats:batch` | Daily counters per rule; no message text | `{day, appVersion, bundleVersion, stats: [{ruleId, ruleVersion, hits, toReview, corrected}]}` | `202` |
| `POST /sms/v2/unknown-templates` | Redacted unknown templates for AI rule drafting (needs `sms_shared_learning` consent) | `{items: [{templateHash, senderBrand, redactedBody, observedAt}]}`, at most 50 | `{accepted: [templateHash]}` |
| `POST /sms/v2/corrections` | A correction with its trace | `{sourceKey, factIds, eventId?, correctionKind, corrected, trace: {appVersion, engineVersion, bundleVersion, ruleId, ruleVersion, stage}, redactedTemplate?}` | `{caseId}` |

`stage` is one of `gate`, `extraction`, `instrument`, `linking`, `category` or `sync`.

`correctionKind` is one of:

- `not_financial`
- `wrong_kind`
- `wrong_amount`
- `wrong_instrument`
- `wrong_link`
- `wrong_category`
- `wrong_date`
- `wrong_merchant`
- `duplicate`
- `missing`
- `preference_only`

### Admin routes (existing admin authority checks)

| Route | Purpose |
| --- | --- |
| `GET /admin/sms/v2/rules?status=&family=&sender=&q=` | Rules table with 7-day metrics |
| `GET /admin/sms/v2/rules/:id` | Every version, cohort history, metrics and golden coverage |
| `PUT /admin/sms/v2/rules/:id/draft` | Create or update a draft (body = Rule) |
| `POST /admin/sms/v2/rules/:id/publish` | `{version, cohort, goldenReport}`; `cohort` is `testers`, `pct5`, `pct25` or `all`. Refused when `goldenReport` is missing, fails, or does not match the bundle hash. |
| `POST /admin/sms/v2/rules/:id/pause` and `/rollback` | `{reason}` and `{toVersion, reason}` |
| `GET /admin/sms/v2/bundles` | Bundle history: version, manifest, signer, cohort |
| `GET /admin/sms/v2/corrections?groupBy=template&status=` | Correction cases grouped by template |
| `POST /admin/sms/v2/corrections/:caseId/decision` | `{decision, reason}`; `decision` is `data_fix`, `code_fix` or `not_a_bug`. `data_fix` returns a prefilled rule draft; `code_fix` returns a redacted golden case JSON. |
| `GET /admin/sms/v2/templates?status=` and `POST /admin/sms/v2/templates/:hash/draft` | Unknown templates and their AI-drafted rules |
| `GET /admin/sms/v2/metrics?days=7` | Golden scores per bundle, review rate, correction rate, AI spend |

The old routes stay unchanged for the current production app until WP-17's minimum-version cutoff: `/transactions/from-sms/batch`, `/sms/facts`, `/ai/jobs*`, `/sms/rules/active`.

## Storage

New data goes into new tables, and existing tables only gain columns. Nothing is dropped in this release except in WP-17's cleanup list.

### Server (new migration files, same RLS pattern as existing user tables)

| Table | Key columns | Notes |
| --- | --- | --- |
| `sms_v2_instruments` | `instrument_id` pk, `profile_id`, `kind`, `issuer_slug`, `mask_digits`, `mask_length`, `display_name`, `status`, `user_card_id` (fk `user_cards`, null), `parent_instrument_id`, `aliases` jsonb, `credit_limit_minor` bigint, `credit_limit_source`, `credit_limit_at`, `available_minor`, `available_at`, `points_balance`, `points_at`, `first_seen_at`, `last_seen_at`, `evidence_count`, `updated_at` | Unique `(profile_id, kind, issuer_slug, mask_digits)` |
| `sms_v2_facts` | `fact_id` pk, `profile_id`, `source_key`, `fact_type`, `contract_version`, `observed_at`, `occurred_at`, `instrument_id`, `payload` jsonb, `provenance` jsonb, `created_at` | Index `(profile_id, observed_at)`. No evidence spans or raw tokens. |
| `sms_v2_events` | `event_id` pk, `profile_id`, `type`, `status`, `legs` jsonb, `link_rule_id`, `confidence`, `occurred_at`, `amount_minor`, `updated_at` | Upsert by `event_id`; legs only grow |
| `sms_v2_ledger_entries` | `entry_id` pk, `profile_id`, `event_id`, `from_instrument_id`, `from_external`, `to_instrument_id`, `to_external`, `amount_minor` bigint, `unit`, `occurred_at`, `category_slug`, `category_source`, `counts_as_transaction`, `is_spend`, `updated_at` |  |
| `sms_v2_rules` | pk `(rule_id, version)`, `status`, `family`, `senders` text\[\], `body` jsonb, `created_by`, `created_at` | Immutable rows; a change is a new version |
| `sms_v2_bundles` | `bundle_version` pk, `manifest` jsonb (rule id → version), `sha256`, `signature`, `key_id`, `cohort`, `golden_report` jsonb, `status`, `published_by`, `created_at` | `status` is `active`, `superseded` or `rolled_back` |
| `sms_v2_rule_cohorts` | `rule_id`, `version`, `cohort`, `started_at`, `paused_at`, `pause_reason` | Drives staged delivery and auto-pause |
| `sms_v2_rule_stats_daily` | pk `(day, rule_id, rule_version, app_version)`, `hits`, `to_review`, `corrected`, `devices` |  |
| `sms_v2_unknown_templates` | `template_hash` pk, `sender_brand`, `redacted_body`, `first_seen`, `seen_count`, `distinct_profiles`, `ai_status`, `ai_draft` jsonb, `ai_model` |  |
| `sms_v2_corrections` | `case_id` pk, `profile_id`, `source_key`, `template_hash`, `correction_kind`, `corrected` jsonb, `trace` jsonb, `status`, `decision`, `decided_by`, `decided_at`, `reason` |  |
| `transactions` (existing) | add `event_id text null`, `pipeline_version smallint not null default 1`; allow `entry_kind = 'refund'` | Rows written by v2 have `pipeline_version = 2` |

### Phone

The file is `app/lib/features/sms_v2/storage/schema.dart`. It keeps its own `sms_v2_schema_version` table and does not touch `PRAGMA user_version`, which `app_database.dart` owns.

| Table | Columns |
| --- | --- |
| `v2_facts` | `namespace`, `fact_id`, `source_key`, `fact_type`, `observed_at`, `instrument_id`, `payload` json (evidence included), `uploaded_at` |
| `v2_instruments` | `namespace`, `instrument_id`, `kind`, `issuer_slug`, `mask_digits`, `status`, `payload` json, `dirty` |
| `v2_events` | `namespace`, `event_id`, `type`, `status`, `payload` json, `dirty` |
| `v2_ledger` | `namespace`, `entry_id`, `event_id`, `occurred_at`, `payload` json, `dirty` |
| `v2_outbox` | `namespace`, `id`, `kind`, `payload` json, `attempts`, `next_attempt_at` |
| `v2_rule_bundle` | `bundle_version`, `json`, `sha256`, `signature`, `expires_at`, `fetched_at` (global, not per account) |
| `v2_rule_stats` | `day`, `rule_id`, `rule_version`, `hits`, `to_review`, `corrected` |
| `v2_review_items` | `namespace`, `review_id`, `kind` (`template`, `event`, `instrument`), `payload` json, `status` |

These existing tables are reused as they are:

- `sms_intake`, `sms_captured_messages` (raw bodies stay on the phone for replay)
- `sms_source_decisions` (gains a `pipeline_version` column)
- `user_sms_ignore_rules`, `user_merchant_category_rules`, `user_self_transfer_rules`

The Activity, Home and Insights screens keep reading `TransactionEntry`. WP-06 writes those entries from the ledger.

## Versioning and change rules

- **Contracts** are versioned `2.MINOR`. An optional new field is a minor change; anything else is major and not allowed in this release. The Dart validators and the Ajv validators must both pass every fixture in `contracts/sms/v2/fixtures`, and the CI `contracts` job runs both.
- **Rules** are immutable. A change is a new `version`, and a bundle names exact versions.
- **Engine** versions are semver. A phone refuses a bundle whose `minEngineVersion` is higher than its engine and keeps its last good bundle.
- **Taxonomy** is versioned in the registry (WP-07). A category is never renamed; it is deprecated and given an alias.
- **Who may change:** only WP-01 changes `contracts/`. After the M0 gate, any change needs a contract change request (Agent playbook).


## CCR-001 additive sync context, approved 3 November 2026

The sync response may also include `facts` with empty evidence and sanitized instrument mentions, `updatedAt` maps keyed by instrument/event/ledger IDs, and `aiResults[].rule` using the existing Rule type. The response schemas and conformance fixtures define these optional fields. The opaque cursor may page immutable source facts by their creation time.

Local schema version 2 adds `v2_sync_state(namespace, key, value)` and `v2_rule_stats_by_account(namespace, day, rule_id, rule_version, hits, to_review, corrected)`. The old unscoped stats table remains available for compatibility. New account-specific stats never read its unowned counters.
