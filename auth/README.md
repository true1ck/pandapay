# PandaPay authentication service

Node/Express service owning account/contact verification, phone/email OTP, device/refresh sessions, auth audit and controlled recovery/admin capabilities. The mobile and console clients are Flutter applications. There is no new user recovery password.

[src/index.js](src/index.js) mounts routes; [src/config.js](src/config.js) defines flags/provider configuration; [scripts/migrate.js](scripts/migrate.js) checks migrations and retained-key prerequisites. Auth and product have separate source configuration/data responsibilities; actual database/schema/provider mappings are deployment inputs.

See the [current source architecture](../docs/security-current-architecture-2026-10-25.md), [recovery examples](../docs/security-recovery-flow-2026-10-25.md), [deployment guide](../deploy/DEPLOY.md) and [security progress](../docs/security-implementation-progress-2026-10-22.md). The old AuthServiceSDK/farm-domain labels are historical context and do not define the current service.

`npm ci --omit=dev` installs the reviewed lock; `NODE_ENV=test npm test` runs local tests using isolated configuration. Preserve original encryption/HMAC keys for existing ciphertext when rehosting. Never print or commit real credentials; the [secret-location index](../docs/security-secrets-inventory-2026-10-23.md) stores locations only.

Reader compatibility: [retained-key source contracts](../docs/security-key-readers-implementation-2026-10-25.md) document optional bounded read lists, unchanged writers/original keys, and remaining backfill/custody/provider gates. Defaults stay unset and recovery remains off.

OTP capacity: [bounded work/delivery source](../docs/security-otp-admission-implementation-2026-10-25.md) adds per-process `OTP_WORK_MAX_CONCURRENT`, `OTP_EMAIL_MAX_CONCURRENT` and `OTP_SMS_MAX_CONCURRENT` (each defaults to 2; strict integer range 1–16). Saturation is immediate retryable 503 with no waiting queue. Shared abuse quotas remain required; failed provider admission discards the undelivered challenge. Verify replica/provider budgets and the new exact-candidate `otp_capacity_acceptance` proof before release. These limits do not establish production throughput or independent monitoring.
