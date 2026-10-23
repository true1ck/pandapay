# Secrets and recovery locations

Updated: 23 October 2026 (IST). This index contains names and locations, never
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
