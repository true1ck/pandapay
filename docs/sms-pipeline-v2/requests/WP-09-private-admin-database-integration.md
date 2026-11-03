# WP-09 integration: exercise the real private admin boundary

Found during the WP-06 integration checkpoint on 3 November 2026. This is an existing WP-09 issue, not a ledger regression. It must be resolved before declaring the complete M1 integration gate green.

## Reproduction

All product migrations were applied, through `20261111120000_sms_v2_core.sql`, to a new disposable Postgres 17 instance. No production database or existing development database was changed.

- `facts_pg.test.js`: **19/19 pass**.
- `20261111120000_sms_v2_core_test.sql`: **passes**, including owner isolation.
- `rules_pg.test.js`: fails at its `admin_users` fixture because `email` is required.
- Running the rule SQL test with only that fixture insert amended in memory to include a synthetic email then fails at the first rule insert: `new row violates row-level security policy for table "sms_v2_rules"`.

The later failure is expected under the current security boundary. `20261030100000_private_admin_authority.sql` makes `pandapay.is_admin()` true only for an authenticated `admin_api_runtime` session with the private actor context. A public `app_user` session plus `app.user_id` does not become an admin.

## Integration work required

- Use the existing private admin API authority and connection helper for rule administration, imports and jobs; retain the public user helper for phone rule downloads and stats.
- Register rule administration on the private admin surface, with its permission checks. Inspect the current public `/admin` denial before changing route registration.
- Adapt the real-Postgres and SQL tests to the actual admin schema and authenticated private connection. Include negative cases proving a public profile or forged GUC cannot publish rules.
- Preserve forced RLS and the existing `is_admin()` boundary. Do not make the old stub fixture pass by weakening policies or replacing the real predicate.
- Run both rule-service and ingestion database tests and the SQL tests against every migration, then update the WP-09 handoff.

This is an orchestrator integration request for WP-09/WP-13. It does not approve changes to applied migrations, frozen wire contracts, or the legacy public admin security policy.
