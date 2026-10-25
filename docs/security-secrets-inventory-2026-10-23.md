# Secrets and recovery locations

Updated: 24 October 2026 (IST). This index contains names and locations, never
secret values. The detailed local index is
`/Users/chandresh_kerkar/Documents/PandaPay-Recovery/SECRETS-INDEX.md`.

## Protected recovery folder

Canonical root:
`/Users/chandresh_kerkar/Library/Application Support/PandaPay/Recovery`, outside
Git. `/Users/chandresh_kerkar/Documents/PandaPay-Recovery` remains a shortcut
to that same folder, not a second copy. The physical folder was moved because
macOS refused launchd access to the original Documents script.
Directories are owner-only; private configuration and key files use mode 0600.

| Item | Location relative to recovery root | Purpose |
| --- | --- | --- |
| Private age identity | `keys/recovery-identity.txt` | Decrypt backup sets, environment escrow and the approved contact proposal. |
| Public age recipient | `public-recipients.txt` | Encrypt exports; safe to install on a future backup server. |
| Original application keys | `keys/application-keys.env` | Original phone AES key, phone lookup HMAC key, IMAP encryption key and referral/engagement protection keys. |
| Saved deployed environment | `keys/deployed-server.env.age` | Encrypted snapshot of the deployed server environment, including database connections, JWT secrets and configured service/provider credentials. |
| Confirmed backup connections | `backup.env` | Product/auth source URLs, verified TLS CA path and bounded local-backup policy. |
| Encrypted database generations | `sets/<set-id>/` | Product/auth dumps, encrypted inventory, checksums and completion/verification markers. |
| Approved test-contact proposal | `contact-review/contact-conflict-proposal.json.age` | Exact approved account selection and original contact state; approval metadata is alongside it. |
| Reviewed migration baseline | `baseline-review/product-source-v2-recovery-v5.json` | Reviewed schema/history evidence; contains no passwords. |
| Restore/backup status | `status/` | Count-only results and encrypted bounded diagnostics. |

`application-keys.env` preserves these names: `ENCRYPTION_ENABLED`,
`ENCRYPTION_KEY`, `PHONE_LOOKUP_HMAC_KEY`, `IMAP_ENCRYPTION_KEY`,
`REFERRAL_IDENTITY_HMAC_KEY`, `REFERRAL_IDENTITY_HMAC_KEY_VERSION`,
`REFERRAL_PREVIEW_SECRET` and `ENGAGEMENT_RECEIPT_SECRET`.
Original keys were retained, not rotated. An encryption key's original value
must accompany its existing ciphertext when changing hosting.

## Existing runtime and developer locations

- The deployed runtime environment was found at
  `/home/ubuntu/apps/pandapay/.env` on the existing API/auth VM. The encrypted
  escrow above records the captured configuration, not future edits.
- Existing local developer files are `api/.env`, `auth/.env` and
  `auth/.env Working` under the project root. They are not the authoritative
  production restore configuration and were not overwritten.
- The existing SSH private key is
  `PEM_PandaPay/ssh-key-2026-08-01 (3).key` under the project root. It was used
  through the existing trusted-host configuration; no new SSH identity was made.
- Android signing configuration exists at `app/android/key.properties`.
  Signing-key recovery and signed-device upgrade validation are separate
  unfinished release checks; this database recovery exercise does not claim
  to escrow the signing keystore.

The listed existing local environment, SSH, Android signing configuration and
keystore files were restricted to mode 0600 without changing their contents.

The encrypted environment includes the configured database, JWT, SMTP,
internal-service, webhook, referral/engagement, rewards-worker, Places,
Gemini/AI and SMS-learning credential names. It is not proof that every
external account, AWS SSM-only value or provider console can be recovered.
Those independently managed sources still require inventory before rehosting.

## New service credential names — source only

The [24 October capability runbook](security-service-capabilities-2026-10-24.md) lists the separate partner callback, IMAP worker, backup-status publisher and dashboard-operator variables. Their tracked examples are blank; this source task has not created live credentials or changed the protected original-key file. When provisioning an approved release, store the separate runtime URLs/bootstrap passwords in protected deployment configuration and refresh its encrypted recovery escrow. The backup-only host must not receive the private age identity. Preserve the existing `IMAP_ENCRYPTION_KEY` when creating a distinct worker database login.

## Recovery procedure

1. Preserve the entire recovery folder and a completed encrypted set. Check
   checksums and the latest successful v5 restore marker.
2. Make the age identity and original application keys available to the
   authorized recovery operator through a protected channel. Do not print
   decrypted environments or place them in chat, Git, CI logs or this index.
3. Follow the [rollout runbook](security-rollout-runbook-2026-10-23.md) and
   [backup guide](../db/backup/README.md). Rehearse first in a fresh isolated
   cluster; do not replay cluster-wide grants on a shared/live cluster.
4. Reconfigure verified TLS, paths and provider connections for the new host.
   Keep existing encryption/HMAC keys while restoring all original data.
   Confirm account links and application behavior before reopening writes.

## Schedule, limits and remaining custody work

Local launchd job: `app.pandapay.local-recovery`, daily **07:45 Mac local time**
(currently IST). The Mac must be awake, online and running Docker. Inspect
`status/last-run.log`; a scheduled job is not evidence of a successful export.
The launch agent runs the canonical Application Support path; do not point it
back through the Documents shortcut. Its private startup diagnostic is
`~/Library/Logs/PandaPay/recovery-agent.log`.
Retention is seven days/seven sets, capped at **1 GiB ciphertext**, with a
**5 GiB free-space floor**, **95% disk usage ceiling** and **30-minute runtime
limit**. Recent complete and verified sets are protected from quota cleanup.

There is currently **one local recovery location**. Its identity and encrypted
archives are on the same Mac. Two independent off-host copies and a separately
recoverable private identity remain release gates. A second folder on this
disk would not provide that protection. No extra end-user password is added;
phone-only data recovery and device encryption activation remain deferred.

For completed work and open phases, see the
[implementation progress](security-implementation-progress-2026-10-22.md).

## Additional optional feature secrets — 24 October source batch

No value for these features was generated, provisioned or added to the retained original-key file by this batch. Tracked examples contain blank values. During approved provisioning, store them in protected deployment environment configuration and update encrypted environment escrow and the private location index.

| Name | Purpose / custody |
| --- | --- |
| `CONSOLE_SESSION_ENCRYPTION_KEY` | Separate canonical base64 32-byte key for server-held browser credentials. Retain across rehosting; changing it invalidates outstanding sessions. Never expose it to Flutter web. |
| `CONSOLE_SESSION_DATABASE_URL` / `CONSOLE_SESSION_DB_PASSWORD` | Dedicated restricted runtime connection / optional migration-only bootstrap credential. Existing password is preserved on replay. |
| `ACCOUNT_LIFECYCLE_DATABASE_URL` / `ACCOUNT_LIFECYCLE_DB_PASSWORD` | Product lifecycle service connection / migration-only bootstrap. |
| `AUTH_LIFECYCLE_DATABASE_URL` / `AUTH_LIFECYCLE_DB_PASSWORD` | Separate auth lifecycle function executor / migration-only bootstrap. |
| `ACCOUNT_RECOVERY_WRAPPING_KEY` / `ACCOUNT_RECOVERY_WRAPPING_KEY_ID` | Separate retained base64 32-byte escrow-wrapping key and stable non-secret version label. Existing encrypted recovery snapshots require their original version; no implicit rotation/key replacement. Keep recoverable separately from ciphertext database backups. |
| `AUTH_RETENTION_DATABASE_URL` | Operator-only maintenance connection for explicitly approved bounded retention; no scheduler or maintenance account was installed. |
| `PRIVILEGE_AUDIT_DATABASE_URL` / `DATA_REVIEW_DATABASE_URL` | Explicit operator read-only audit/restored-copy connections; never emitted in reports. |

Feature flags, origins, quota values and key **names** belong in release records; passwords and key values do not. The new password-free recovery modules do not request an end-user password. Their UI/operation barriers and native-device acceptance remain open; phone-only data is not silently uploaded. See the [source runbook](security-remaining-source-implementation-2026-10-24.md).


## External lifecycle journal — follow-up names

The [follow-up runbook](security-followup-implementation-2026-10-24.md) adds `ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY` (separate retained 32-byte base64 authentication key), stable non-secret `ACCOUNT_LIFECYCLE_JOURNAL_ID`, two ciphertext-root paths, `ACCOUNT_LIFECYCLE_CHECKPOINT_ROOT` and a public-recipient file path. Source examples remain blank. No live key, mount or checkpoint was provisioned. During approved setup, escrow the original authentication key and preserve the journal ID across rehosting; retain the newest authenticated checkpoint independently of paired DB backups. The worker must not receive the private age identity. Recovery-only operator paths/connections are named in the runbook; do not add their values to Markdown/Git.

## Maintenance and reviewed-repair configuration — additional source

Names/locations only; no credential or original key was generated, changed or copied by this batch. Keep actual connection URLs/passwords in protected operator/deployment configuration and encrypted environment escrow, outside Git.

| Name | Purpose |
| --- | --- |
| `MAINTENANCE_DATABASE_URL` / `MAINTENANCE_DB_PASSWORD` | Dedicated product job capability connection / optional migration bootstrap. |
| `AUTH_MAINTENANCE_DATABASE_URL` / `AUTH_MAINTENANCE_DB_PASSWORD` | Separate product-ledger capability for auth retention coordination. |
| `MAINTENANCE_READER_DB_PASSWORD` | Optional operator status/notice-reader bootstrap; generation acknowledgement access is separate from workers. |
| `AUTH_RETENTION_DATABASE_URL` | Independently reviewed narrow auth maintenance identity; never substitute the product URL or ordinary auth login. |
| `PRIVILEGE_REPAIR_DATABASE_URL` / `PRIVILEGE_REPAIR_DB_SSL_CA_FILE` | Exact reviewed repair target and verified CA file; no implicit app/ambient URL. |

Public build/feature flags include `PANDAPAY_OTP_V2_ENABLED`, `PANDAPAY_ACCOUNT_RECOVERY_ENABLED`, `AUTH_RETIRE_LEGACY_OTP`, `AUTH_RETIRE_PUBLIC_LOOKUP`, `MAINTENANCE_ENABLED` and `AUTH_RETENTION_MAINTENANCE_ENABLED`. They are not keys; defaults remain off and activation requires the current-source acceptance described in the [runbook](security-recovery-maintenance-source-2026-10-24.md).


## Operational alert adapter — 25 October source only

No live destination, connection, token or identity was generated. `MAINT_ALERT_READER_DATABASE_URL` is the separate restricted reader connection; `MAINT_ALERT_WEBHOOK_URL` may contain a receiver-owned path token and belongs in protected deployment configuration. Keep both values out of Git and logs. `MAINT_ALERT_DB_SSL_CA`/`MAINT_ALERT_DB_SSL_CA_FILE` name reviewed CA trust. `MAINT_ALERT_SOURCE_ID`, `MAINT_ALERT_WEBHOOK_HOSTS` and `MAINT_ALERT_DELIVERY_STATE` name non-secret identity/allowlist/private-state locations; preserve source identity and delivery state during rehosting. `MAINT_ALERT_DELIVERY_ENABLED=false` remains the tracked default. See the [adapter runbook](maintenance-alert-delivery-source-2026-10-25.md). These names do not establish real receiver/custody provisioning.

## 25 October implementation checkpoint

A fresh paired encrypted backup (`4f383a48d3111523e663f8791e4819f0`) was restored locally with the existing original application keys. The optional bounded actual-data review is encrypted at `status/data-review.json.age` under the canonical recovery root. Tracked evidence contains counts/digests only. No original key was rotated and no new live DB-encryption, recovery-wrapping or mobile-storage key was provisioned by this source batch.

Automatic account-recovery consent records contain opaque device hashes and consent generations, not a new user password. Server-assisted recovery still depends on the original separately retained `ACCOUNT_RECOVERY_WRAPPING_KEY` when that disabled feature is eventually provisioned. Per-install mobile keys will stay in device secure storage; production provisioning/conversion remains unfinished. See the [recovery flow](security-recovery-flow-2026-10-25.md) and [implementation checkpoint](security-dnmw-implementation-2026-10-25.md).

## Later 25 October storage-source checkpoint

The [storage implementation record](security-storage-implementation-2026-10-25.md) adds install-key serialization and independent random account/guest receipt-key custody. The checked source uses secure-store slots; test keys exist only in private synthetic stores or the isolated emulator fixture. Normal application storage/key provisioning is not activated, and no original server key was changed. Authentication of migration progress uses a domain-separated local key; it does not introduce a user password or reuse a JWT, phone/email value or server credential as an encryption key.

## Optional retained reader lists — source only

`ENCRYPTION_READ_KEYS_JSON` and `ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON` are optional secret-bearing runtime lists. Checked-in examples are blank; this source batch created no keys or live lists and did not modify the protected original-key file. If later provisioned, retain the complete lists privately alongside the original keys and refresh the encrypted recovery escrow before relying on new IDs. Never put their JSON/key values in this index or release metadata.

Release inputs use optional `retainedReadKeyIds` with nonsecret key IDs and escrow/version labels only. Phone legacy ciphertext still requires the original `ENCRYPTION_KEY`; lookup HMAC and IMAP keys must remain stable. Recovery snapshots require their original wrapping ID/key, or a compatible retained reader. See the [reader contracts and rollout limits](security-key-readers-implementation-2026-10-25.md).
