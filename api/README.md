# PandaPay product API

Node/Express product service. [src/index.js](src/index.js) mounts routes/workers; [src/config.js](src/config.js) defines configuration and safe defaults; [src/db.js](src/db.js) owns PostgreSQL pools and user transaction context. Authentication uses auth-issued credentials plus authoritative current-session checks. Product/auth database/provider/schema mappings must be verified per deployment.

See the [current source architecture](../docs/security-current-architecture-2026-10-25.md), [deployment/rehosting guide](../deploy/DEPLOY.md), [paired backup guide](../db/backup/README.md) and [current progress](../docs/security-implementation-progress-2026-10-22.md). The maintained product migration chain lives in `db/supabase/migrations`; root `database.sql` is historical.

`npm ci --omit=dev` installs the reviewed lock and `npm test` runs local checks. Use isolated test configuration and disposable fixtures; do not run migration/recovery tests against a live database. New recovery/lifecycle/maintenance capabilities remain opt-in and require their own acceptance before activation.

Reader compatibility: [retained-key source contracts](../docs/security-key-readers-implementation-2026-10-25.md) document optional bounded read lists, unchanged writers/original keys, and remaining backfill/custody/provider gates. Defaults stay unset and recovery remains off.
