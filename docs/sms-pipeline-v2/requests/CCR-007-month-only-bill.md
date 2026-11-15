# CCR-007. A bill that names only a month, and what a bill is

Status. Implemented. Additive and backward compatible.

## What

Two optional attributes on the `bill_due` fact, and one relaxed rule.

- `attrs.dueMonthOnly`: `true` when the message named a month and no day ("Next Premium falls due on 09/2026"). Only `true` is valid (error `fact.bill_due.dueMonthOnly_invalid`). `attrs.dueDate` stays required: for a month-only bill it is that month's last day, so ordering and every existing reader keep working, and the flag says the day was never stated.
- `attrs.billKind`: what the bill is, when the rule that read it says so: `utility`, `telecom`, `insurance`, `loan`, `rent`, `education`, `tax` (error `fact.bill_due.billKind_invalid`). Absent, the reader classifies the bill from the biller's name as before.
- An amount is required for a `bill_due` unless `dueMonthOnly` is `true`. It moved from the schema (`contains`) to the semantic check in both validators (`api/src/sms_v2/contracts.js`, `contract/validate.dart`), with the same code and path (`fact.bill_due.amount_required`, `…/amounts`). A month-only bill may still print an amount.
- Engine: a date attribute spec may set `"monthEnd": true` (`formats` of month and year only; defaults `MM/yyyy`, `MM-yyyy`, `MMM yyyy`, `MMM-yyyy`). `parseMonthEnd` reads `9/2026`, `09-2026`, `Sep 2026` and `September 2026` and returns that month's last day at midnight IST. The rule spec is an open object, so no schema change.
- Dart: `BillDueFact.dueMonthOnly`, `BillDueFact.billKind`.
- Regenerated: `schema_data.g.dart` (`node contracts/sms/v2/embed_dart.js`) and `api/sms_v2_assets` (`node api/scripts/sync_sms_v2_assets.js`).
- Fixtures: valid `bill_due.month_only.json`; invalid `fact.bill_due.dueMonthOnly_invalid.json`, `fact.bill_due.billKind_invalid.json`. The existing `fact.bill_due.amount_required.json` still fails with the same code.

## Why

"Next Premium falls due on 09/2026" prints no day and no amount, so no bill fact could carry it, and the app read it with its own wording match. Owner direction (15 Nov 2026): knowledge about a message belongs in the rule set. Now `GENZ-INS-PREMIUM-NEXT-MONTH` reads it and says what it is; the app reads the typed fact (`premium_notices.dart`) and no wording.

## Never a made-up day or amount

A month-only bill has no amount and no stated day. The app lists it as a reminder for its month (upcoming) or as history that needs confirming (past), never as a bill due on the last day. Dated-bill code (`billsFromFacts`, card ledgers) skips it.

## Compatibility

- Old payloads validate unchanged. Bills with an amount behave exactly as before.
- A phone on an older build reading a bundle with the new rule drops the fact (unknown attrs on `bill_due`); publish the rule with a `minEngineVersion` that includes this change.
- The server stores facts generically; nothing indexes into `amounts` for a `bill_due`, so an empty `amounts` needs no server change.
- Messages already read before the rule existed are read again at the next rule revision (checked in `bills_rules_e2e_test.dart`).

## Rollback

Unpublish the rule, then revert. Month-only facts live only as stored facts; no migration is needed.
