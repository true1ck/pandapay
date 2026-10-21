# SMS Intelligence — Phase 1 Report (Typed Source/Fact Contract)

**Date:** 2026-10-21
**Scope:** additive schema + device/server DTOs + validation + override precedence. No legacy path touched; nothing wired into the live pipeline yet (wiring is Phase 2/3 by design).

## Changed files

| File | Change |
|---|---|
| `db/supabase/migrations/20261021120000_sms_source_facts.sql` | NEW. Three additive tables: `sms_sources` (envelope: profile_id + legacy `source_key` identity, sender, body **hash** — never raw text), `sms_source_facts` (typed facts with deterministic `fact_index`, type/status checks), `fact_overrides` (user corrections on `(source_id, fact_index)`). RLS owner policies + `app_user` grants on all three, mirroring `transaction_observations`. |
| `api/src/sms_facts.js` | NEW contract module: fact types, amount/date roles (`posted | due_total | due_minimum | outstanding | ceiling | proposed`), shipment `PAYLOAD_FIELD_SHAPES` validation, per-type required fields, deterministic slot ordering (code-unit compare — deliberately not `localeCompare` for Dart parity), `bodyHashOf`, `applyOverride`, `resolveFactsWithOverrides`, `upsertSmsSourceFacts` (replay-safe upserts), `loadSmsSourceFacts` (override-wins read). |
| `app/lib/data/sms_fact_contract.dart` | NEW device mirror of the same contract (identical field names, enum sets, rules, sorting); `smsBodyHash` parity hash. |
| `api/test/sms_fact_contract.test.js` | NEW 11 tests incl. fake-client replay identity + override-survives-replay + invalid-override-refused. |
| `app/test/data/sms_fact_contract_test.dart` | NEW 7 tests mirroring the same cases + pinned cross-language body-hash parity value `28dd854f…58d5`. |

## Contract essentials

- One source → several facts. Families: `posted_movement`, `pending_or_failed_attempt`, `balance_snapshot`, `bill_obligation`, `bill_payment`, `mandate_lifecycle`, `card_identity_hint`, `security_or_service_alert`, `promotion`.
- Amount roles separate "money mentioned" from "money moved": a `due_total` reads `amountDueInr` + `dueDate`; a `ceiling` reads `limitInr`; `posted` reads `amountInr` + `occurredAt`. Non-posted families may never use the `posted` role; an OTP alert may never carry any amount; a registered mandate must carry its ceiling.
- `fact_index` comes from a stable canonical sort of the fact content, so replays upsert the existing rows: same source → same fact IDs, and `fact_overrides` is never rewritten by a replay.
- Validation refuses (abstain → review) rather than posting half-trusted facts.

## Evidence

- `api`: `npm test` → **533 tests / 532 pass / 0 fail / 1 skip** (DB-required skip unchanged; 505 legacy all green + 16 corpus + 11 contract).
- Flutter: `sms_fact_contract` (7) + `sms_family_corpus` (24) → **31 pass, 0 fail**; body hash pinned equal to Node (`28dd854f5c943a06f19a390121698bbf9e62f563585fcb3c0382b166f44558d5`).
- Replay gate (fake client, same semantics as pg `ON CONFLICT`): second `upsertSmsSourceFacts` with the same source → `replayed: true`, identical `sourceId` and fact IDs; different profile → fresh rows.
- Override gate: user patch `amountInr: 350` survives a replay (read path returns 350, `errors: []`); an invalid patch (negative amount) is refused with errors, not silently fallen back.
- Migration itself is syntax-checked as part of test bootstrapping; DB-copy application is deferred to the Phase 2 wiring gate (no DB available in this environment; the DB-required suite remains skipped as before).

## Compatibility gate

- `POST /transactions/from-sms`, `/from-sms/batch`, `import_source_key.js`, `transaction_observations` and receipts untouched — 505 legacy tests pass unchanged.
- No checkpoint, source-hash or review-path edits. Legacy 21-case parity corpus still green.

## Risks / next

- The contract is additive and idle until Phase 2 routing feeds it: device fact extraction (balance/bill/mandate families currently `local_ignore`-acked) and a server route to accept fact sets.
- Phase 2 (device/server routing) per handoff: broaden relevance gate, safe-discard vs recognized non-spend, specialist extractors wiring facts into `sms_facts.js`, plus the historical-backfill checkpoint only if needed.
