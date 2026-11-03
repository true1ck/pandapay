# WP-16 server handoff

Server half implemented locally. The phone replay/dry-run/report is owned by the orchestrator, and the owner-device dry-run release gate remains open. No WP-17 deletion, flag change, legacy cutoff or push.

- Additive `20261112170000_sms_v2_supersede.sql` adds the status and source-event pointer, retained-history index, stale-reactivation trigger and private `pandapay.sms_v2_unsupersede(profile_id)`.
- `legacy_supersede.js` composes into `afterEventsStored` inside the existing profile-locked transaction. Source keys come from profile-owned persisted fact IDs in every event leg, never SMS text or caller-supplied source claims. Active pipeline-1 SMS/SMS-bulk rows become superseded. Manual, deleted, ignored, missing-source and other-profile rows remain intact. A card-bill pair can retain two legacy rows linked to one v2 event.
- Projection preserves superseded legacy rows instead of adopting them; the v2 row uses the existing event-suffixed source identity when necessary. Events backed by legacy rows produce `is_backfill` rows even if the caller omits the history URL option, preventing repeated card-state application.
- Report/list query inventory is [WP-16-server-query-inventory.md](WP-16-server-query-inventory.md). Existing active filters cover all nine reports. Narrow filters added where needed; archive/identity reads stay complete. No frozen Gmail files changed.
- Private SQL rollback requires separately authenticated `admin_api_runtime`, active actor with `learning.publish`, and the matching transaction permission. Public permission GUC forgery fails. It hides the mapped v2 transaction rows, restores only superseded legacy rows, records an audit event and leaves historical reward/card-state flags untouched. No public/private HTTP route was added.

## Operator rollback sequence

Stop new v2 admissions for the affected rollout using the existing feature control before invoking rollback; WP-16 does not change that control or set a cutoff. Through the existing trusted private database transport, establish the verified admin actor/learning.publish transaction context, then execute `SELECT pandapay.sms_v2_unsupersede('<profile UUID>');` in a transaction. Review the resulting audit counts. This is a server visibility rollback; retain the app's migration state/history for diagnosis and use the existing release rollback procedure to stop phone v2 projections. Re-enabling replay can supersede restored legacy history again. The SQL function preserves raw rows and does not rewrite rewards, issue refunds, or delete v2 facts/events/ledger.

## Validation

- Failing-first PG tests confirmed missing supersede module before implementation.
- 49 focused logic/real disposable Postgres tests pass, including paired source keys, unchanged retained edits, profile/manual/ignored/no-body isolation, duplicate replay, stale status reactivation denial, no-backfill card-state suppression and actual queries for all nine spend-report aggregations.
- 53 existing consumer tests pass (splits, bulk category, merchant preferences, self-transfer, duplicate resolution and reports).
- Supersede SQL test passes: owner isolation, public denial, forged private GUC denial, untrusted SET ROLE denial, insufficient private permission denial, trusted rollback counts, v2 hiding, retained deleted/card-state flags, idempotency and audit.
- API syntax/assets `npm run check` passes; broader SMS server suite has 96 passing tests and 27 database/environment skips.

The synthetic phone legacy fixture and retained-body coverage numbers belong to the orchestrator's migration/report tests; this server fixture covers only persisted source-key history and does not claim a phone raw-body coverage measurement.
