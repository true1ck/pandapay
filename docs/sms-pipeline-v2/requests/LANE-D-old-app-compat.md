# Request LANE-D-old-app-compat: two old-app issues once a profile has v2 rows

**From:** Lane D (release safety). **To:** orchestrator. **Status:** open, owner decision needed. Nothing was changed in the legacy routes.

Neither issue appears in a dark deploy (flag off, no v2 rows). Both appear for a profile that has v2 rows **and** is also served to a v1 client: an old app on a second device, or the new app with the flag turned back off. Both are reproduced by `todo` tests in `api/test/sms_v2/old_app_compat_pg.test.js` (they run and print, but do not fail the suite; remove `todo` when fixed).

Run: `SMS_V2_TEST_DATABASE_URL=<scratch> node --test --test-name-pattern=FINDING test/sms_v2/old_app_compat_pg.test.js` from `api/`.

## LANE-D-1: a v1 app shows a `refund` row as spending

- **Evidence.** v2 projects a refund event to `transactions.entry_kind = 'refund'` (`api/src/sms_v2/projection.js`, enum value added by `20261111120000_sms_v2_core.sql`). `GET /transactions` and `GET /transactions/:id` return `t.entry_kind` unchanged. The shipped app, `6c17d46:app/lib/data/user_cards_repository.dart`, has `TxnEntryKind { spend, income, investment, transfer }` and `fromJson` uses `orElse: () => TxnEntryKind.spend`. So the refund is rendered and totalled client-side as spending. (The current app already knows `refund` and `unknown`; only old builds are affected.)
- **Not affected.** Server-side reports (`spend-by-category`, `spend-report`, `home-summary`, `monthly-reports`) ignore the row; verified equal to a twin profile without it.
- **Failing test.** `FINDING 1: legacy GET /transactions must not emit entry_kind values a v1 app maps to spend`.
- **The v1 app cannot be identified by header.** `git grep -i x-app-version 6c17d46 -- app/lib api/src` finds nothing: the old app sends no `X-App-Version`. WP-17's `426` middleware (keyed on `X-App-Version`) must therefore treat an absent header as legacy, and the v2 app must send it from its first release.

**Minimal safe fix (proposal).** In the three places that return a transaction's kind to the client (`GET /transactions`, `GET /transactions/:id`, and the `RETURNING entry_kind` of `PATCH /transactions/:id`), project:

```sql
CASE WHEN t.entry_kind::text = 'refund' AND $legacyClient THEN 'transfer' ELSE t.entry_kind::text END AS entry_kind
```

where `$legacyClient` is true when `X-App-Version` is absent or lower than the first v2 version. `transfer` is neutral for a v1 app (not spend, not income), which matches how v1 treated refunds (ignored rows tagged `[ignored: refund]`). `income` is the alternative and would raise "money in"; owner to choose. The v2 app, which sends the header, still receives `refund`. No schema change, no change for rows that are not refunds, and every existing test and the parity test stay green.

## LANE-D-2: a legacy SMS replay rewrites a v2-owned row

- **Evidence.** `insertTransactionAndUpdateState` (`api/src/index.js`, around line 3225) inserts with `ON CONFLICT (profile_id, source_key) DO NOTHING`. When the key exists it loads the row and runs `UPDATE transactions ... SET entry_kind = $6 ...` with the legacy parser's kind, plus card-state reverse/apply if the kind changes, regardless of `pipeline_version` or `status`. v2 projected rows keep the SMS `source_key`, so a replay of the same SMS through `POST /transactions/from-sms/batch` flips a v2 `refund` row to the legacy kind (test: `refund` becomes `transfer`, `pipeline_version` stays 2). For a `superseded` row the same path edits a hidden row, and the batch answer echoes it with `status: "superseded"`.
- **When it happens.** Any v1 client (or the new app with the flag off) re-importing an SMS whose key already has a v2 row, for example the old app's "import SMS backup" or reconcile on a second phone.
- **Failing test.** `FINDING 2: a legacy SMS replay must not rewrite a row projected by v2`.
- **Already fine.** A replay over a `superseded` row never makes it active and never returns 5xx (passing test).

**Minimal safe fix (proposal).** In that duplicate branch, right after `const old = existing.rows[0]` (the `SELECT t.*` already contains `pipeline_version` and `status`), return the stored row untouched:

```js
if (old.pipeline_version === 2 || old.status === 'superseded') {
  return { status: 200, duplicate: true, duplicateKind: 'exact_retry', transaction: old };
}
```

No observation is recorded and no card state is touched, so v2 stays the single writer of its rows. Rows with `pipeline_version = 1` follow the existing path unchanged. The extracted-function tests in `duplicate_ingestion.test.js` pass rows without `pipeline_version`, so they are unaffected. Echoing `status: 'superseded'` to the old app can stay (it stores the status string); optionally answer `outcome: 'duplicate'` with the row omitted.

## Smaller observations (no action requested)

- `PATCH /transactions/:id/note` still saves a note on a `superseded` row (returns 200). Harmless, the row is hidden; tell me if you want it to answer 409 like `PATCH /transactions/:id`.
- The v2 projection never writes an `unknown` entry kind (it is not in `txn_entry_kind`); an `unknown` event has no `transactions` row, so it cannot leak into a legacy answer. The test asserts the enum has no such label.
- `api/package.json` `npm test` runs `node --test test/*.test.js` only; `test/sms_v2/` runs in its own CI step. The new compat test lives in `test/sms_v2/` and skips unless `SMS_V2_TEST_DATABASE_URL` is set.
