# WP-C7: insights, bills, subscriptions and budgets work offline

Branch `offline/c7` (from `feature/offline-first`). Kill switch: `kInsightsLocalFirst`
in `app/lib/features/insights/insights_local_first.dart` (set `false` to restore the
old behaviour at every guarded call site; the `v2:` prune exemption in
`FinancialStore` and the v2 commitment copy rules are not behind it).

## What changed

| Finding | Fix |
|---|---|
| V9 Bills tab error offline | `paymentsDueProvider` skips the transaction load in SMS-v2 mode (that branch reads the ledger model) and degrades to an empty list otherwise. |
| V5 / L-04 card-bill payment pruned | The manual "paid" transaction now goes through `TransactionOutboxRepository` (stable uuid-v5 mutation id from `payment-<card>-<yyyy-mm>`), so it is a pending provisional row the prune skips, and it reaches the server. Undo cancels the queued copy or deletes the delivered row (`card_bill_payment.dart`). |
| L-04 `[I]` v2 rows | Proven by a failing test: `saveTransactions(completeQuery:)` pruned `v2:<eventId>` rows the server did not list. They are now exempt (`id NOT LIKE 'v2:%'`). Once uploaded they are remapped onto the server row by event id as before. |
| V4 mark-paid / dismiss on SMS bills | The saved copy is `isUserConfirmed: true`; `billsFromFacts(manualCopies:)` applies a paid/dismissed copy by id, else by bill identity + due day, so it survives re-projection. `v2:` copies are device-local: never queued to the server (`CommitmentsRepository._queueChanges`, `delete`). |
| V3 v2 subscription ids | New device-local table `subscription_overrides` (`LocalFirstSchema` migration 2, namespace first). UI actions on `v2:` / `projection:` / `manual:` ids write it and never queue a command. `recurringReportProvider` lays the overrides over the report (`applySubscriptionOverrides`). Server uuid series keep the command path. Manual "Add subscription" in SMS-v2 mode is a `manual:<uuid>` override shown as `detectionSource: 'manual'`. |
| Budgets offline | New table `user_budgets` (migration 2). Saving a budget (new or edit) is local first: a row in `user_budgets` plus a `budget_save` command carrying a client `id` and `clientEditedAt` (UTC ISO). Delete carries `clientEditedAt` as `X-Client-Edited-At`. `budgetsProvider` merges local rows (target not yet on the server) with spent computed by `computeBudgetSpend` (`data/local_first/budget_local.dart`) from the current period's rows read through `ResponseCache.readTransactions` (read worker), flagged `isEstimate` and captioned "Estimate from this phone...". With no server list and no cache the local rows are the list. 200 replies (`replayed`, `superseded`) count as success. |
| Central bills offline | `/bills/projections` raw response cached under `<ns>:bills_projections`; served stale on any failure except 401/403. |
| Stale figures | `AsOfLastSyncCaption` ("Saved data, as of last sync ...") on caps, fee waivers, milestones, monthly savings while offline/unreachable. |

## Golden fixtures
`app/test/fixtures/budget_spent_cases.json`: synthetic transactions plus expected
spent / count / period bounds (overall, category incl. child user categories, card,
tag, weekly anchored, quarterly, yearly, exclusions). Replayed in
`test/data/local_first/budget_local_test.dart`; the API repo can replay the same file
against `budgetSpend` / `budgetPeriodBounds`.

## Backup
`subscription_overrides` and `user_budgets` are not send queues, so they are not in
`QueueRegistry`; both are listed in `LocalPortableSnapshotSource.declaredExclusions`.

## Known gaps
* Legacy-mode (non-v2) manual "Add subscription" still calls `POST /recurring` online
  only; it is not queued. Server ids are `id`/`clientEditedAt`-capable (WP-S4) but the
  client does not send them yet. v2-mode manual subscriptions are local-only.
* A budget parked with 422 `tag_unknown` stays parked (no tag-alias resolve + retry).
* Server-wins on `superseded:true` is treated as success; the local `user_budgets` row
  is dropped when the server list carries the target, so the server value wins then.
* Local budget spent scans the current period's rows (read worker), not an O(history)
  scan; a yearly budget on a very large ledger still reads a year of rows once per build.
* Points caption not added (the points screens have no common list header here).
* Plan claim: `MonthlyReport.valueMissed/baselineSingleCard = 0` is not shown by any
  screen (the savings screen computes its own extras), so there was nothing to hide.
