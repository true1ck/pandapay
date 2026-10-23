# Security foundation rollout and approved test-contact resolution

Status: preparation and disposable-copy verification. No live migration,
contact change, key rotation or service restart has been performed.
Parent: [implementation plan](security-implementation-plan-2026-10-22.md).
Evidence: [progress record](security-implementation-progress-2026-10-22.md).

## Preserved decisions and data

- Keep PostgreSQL and change hosting/provider later. Retain both databases,
  all account UUIDs, financial/history rows and original encryption/index keys.
- Deleted accounts release their email/phone claims; their rows and history
  remain. A new claim does not inherit the deleted account's data.
- The owner approved the exact encrypted test-account proposal. It covers two
  duplicate phone groups and four accounts. The selected account in each group
  retains its existing phone; the other two retain verified email login.
- Selection prefers a phone-verified account, then the oldest creation time
  and UUID. Both actual groups currently have no phone-verified account, so
  the approved proposal selects the oldest account. Verification flags are
  preserved for keepers; this operation does not certify phone ownership.
- Before clearing a secondary phone, the tool archives its original selected
  contact state with age in the restricted `contact_resolution_history` table.
  It changes only that account's phone, hash and phone-verification flag
  (plus the existing update timestamp trigger). It never merges accounts,
  deletes an account, rewrites UUIDs or removes financial/session history.

The private proposal, owner decision, encrypted proposal digest and retained
keys are outside Git in
`/Users/chandresh_kerkar/Documents/PandaPay-Recovery`. Do not attach the private
proposal, environment, plaintext rows or recovery identity to a PR or CI job.
That Documents path is a shortcut. The canonical owner-only folder is
`~/Library/Application Support/PandaPay/Recovery`, allowing the background
launch agent to run without Documents access. It is still one local copy.

## 1. Review the exact release before downtime

The initial security work started at `aca220a`. Read-only inspection found the
server at `da2b1a086a1a05e9093ec09c872031eb1ff8d13f`, with migration files and
SMS features absent from that older checkout. The security changes were
integrated with the newer source; do not deploy the older checkout or copy
just the missing SQL files. The isolated integration checkout started at
`89d98e2` and was advanced through `1cdd44a` to `6544d79`, preserving the
portable-export work and main's later revert of unrelated SMS changes before
final verification.

All 97 applied product migration files in the integrated baseline match the
deployed commit's exact bytes. Preserve their filenames and contents. The
read-only product preflight reports 97 legacy entries and one pending security
migration. A fingerprint alone is not proof of correct migration effects;
compare the actual schema/data/permissions on the restored copy and rehearse
the upgrade before adopting these checksums.

The final v5 actual-data proof passed the complete product/auth upgrade and
replay, including cluster parameter grants missing from older archives. Use a
fresh v5 generation with the current strict verifier; retain older archives as
historical recovery material. Auth requires Node 22 or later. Review its locked
dependency and SMTP transport update with the release.

Use a PostgreSQL 17 dump client for baseline capture and verification. Supply
the reviewed baseline through the protected mounted directory documented in
[migration baselines](../deploy/migration-baselines/README.md). JSON baselines
are gitignored. `product_migrate.js --write-baseline <new-file>` captures the
ledger and schema under one held read-only snapshot. `--check` validates
history, checksums, reviewed legacy baseline and pending SQL without changing
schema, roles or ledger rows.

Migration connections must be direct PostgreSQL or a session pooler. Session
advisory locks and exported snapshots require a stable backend session; do not
use a transaction or statement pooler for these operator commands.

Normal deployment runs product `--check` and the count-only auth audit with
`--require-unique` before stopping services. Existing test-phone conflicts
intentionally block that automatic path. The initial approved resolution must
use the coordinated operator sequence below; it is not an automatic repair.

Review every writer: API, auth, rewards, optional Gemini and SMS learner,
database jobs, external importers and callbacks. The reviewed legacy maps
scraper is stateless and has no database configuration; leave it running.
Any other unreviewed production service blocks downtime until classified.
Prevent external jobs or another deployment from restarting writers during
the maintenance window. A Compose stop does not fence an external SQL client.

## 2. Rehearse from encrypted recovery before the live operation

The approved local PC mode contains one encrypted copy per generation.
Daily launchd runs at 07:45 Mac local time when the Mac is awake, connected
and Docker is running. Retention is seven generations/seven days, bounded by
1 GiB of ciphertext, a 5 GiB free-space floor and 95% disk usage ceiling.
The newest two complete and two restore-verified generations are protected;
a quota failure stops the new export and preserves protected recovery data.
Check `status/last-run.log`; installation of a schedule is not proof that a
sleeping or offline Mac took a new backup.

Use the original application key environment and explicit source configuration
through the protected local shell, without printing either. Run
`rehearse_local_backup.py <recovery-folder> --image <reviewed-PG-image>
--contact-upgrade`, optionally adding `--product-baseline <reviewed-file>`
and `--dump-image <matching-reviewed-client-image>` for the complete
product/auth upgrade proof. The helper creates its own
loopback-only, memory-backed cluster, verifies source equality before any
upgrade, applies the approved changes, checks original data and replay, then
removes the cluster. It refuses a live or non-generated upgrade target.

The private age identity stays on the recovery/operator PC. A production
backup process receives only public recipients. The current server automation
also requires two independently hosted destination mounts. Local PC mode is
the owner's temporary setup; two folders on one disk do not satisfy independent
copies. Configure the future off-host copies and repeat recovery there before
claiming protection from loss of this Mac.

## 3. Read-only contact proposal check on the operator PC

Run from the reviewed release checkout with auth dependencies installed. Load
the protected connection/key environment through the existing local secret
channel. Set `AUTH_MIGRATION_DATABASE_URL` explicitly to the confirmed auth
database. Use verified TLS and the original encryption/HMAC keys.

```sh
node db/scripts/resolve_test_contacts.js \
  --plan "$RECOVERY_ROOT/contact-review/contact-conflict-proposal.json.age" \
  --identity "$RECOVERY_ROOT/keys/recovery-identity.txt" \
  --recipients "$RECOVERY_ROOT/public-recipients.txt"
```

This default command is read-only and does not install schema. It verifies the
entire current conflict membership and exact proposed state. If state has
changed, stop and create/review a replacement proposal; do not edit the
encrypted approved proposal or force its state checks to pass.

## 4. One coordinated maintenance operation

Do this only with the reviewed release images, current/oldest supported-client
results, recovery evidence and original keys ready. Build images before
downtime. Hold the real writer fence until every migration and readiness gate
passes. Take a fresh paired encrypted backup after stopping writers; the
separate DB snapshots then share the same application write boundary.

1. Capture the existing writer container IDs and confirm every writer stopped.
   Keep the maintenance window bounded (default 30 minutes). A failure before
   any source/schema change can resume captured original containers.
2. Run the canonical product migration CLI with the reviewed matching legacy
   baseline and explicit one-time checksum adoption. Use the source release's
   role setup and preserve optional worker credentials/configuration.
3. On the operator PC, run the approved resolver with `--apply` and the exact
   encrypted proposal digest from the private approval record. Set these two
   explicit attestations only after confirming the owner decision and fence:

   ```sh
   export CONTACT_RESOLUTION_APPROVAL=I_APPROVE_THE_REVIEWED_TEST_ACCOUNT_PROPOSAL
   export CONTACT_RESOLUTION_WRITERS_FENCED=ALL_AUTH_API_AND_BACKGROUND_WRITERS_ARE_STOPPED
   node db/scripts/resolve_test_contacts.js \
     --plan "$RECOVERY_ROOT/contact-review/contact-conflict-proposal.json.age" \
     --identity "$RECOVERY_ROOT/keys/recovery-identity.txt" \
     --recipients "$RECOVERY_ROOT/public-recipients.txt" \
     --apply --approved-proposal-sha256 "$APPROVED_PROPOSAL_SHA256"
   ```

   These environment values are operator assertions, not automatic proof.
   The tool uses the canonical auth runner's advisory lock, verifies the
   complete ledger, applies additive migrations, verifies/backfills hashes,
   archives/resolves contacts transactionally, then applies `9001` unique
   indexes. Use explicit one-time auth `0001` adoption only after its verified
   historical effects match. Never upload the private identity to the VM.
4. Keep writers stopped through `9001`. The contact transaction commits before
   the later constraint transaction; a failure there requires forward repair.
   Repeating the same approved apply command verifies encrypted history and
   resolved state before reporting `already_applied`. Do not resume an old
   binary or restore a stale dump over accepted writes.
5. Run the count-only audit with `--require-unique`, full retained-key/hash and
   product/auth identity checks, and the product read-only preflight. All
   active conflicts must be zero. Check expected account/archive counts and
   every migration checksum. Remove one-time adoption flags after success.
6. Start only the reviewed compatible service images and configured workers.
   Verify readiness, unauthenticated denial, operator email sign-in, phone
   sign-in, recovery, refresh, sync, imports and supported-client behavior.
   The secondary test accounts use verified email; their old phone is archived.
7. Take and restore-verify a fresh paired encrypted generation after the
   upgrade. Record the release/version, evidence and current backup status.

Once any source or schema mutation begins, a failure keeps writers fenced.
Retain the new schema and original data, resolve forward, rerun the idempotent
tools, and reopen only after verification. Rehosting later must preserve the
same keys, repeat full role/extension/data checks, fence the old host and have
one active worker generation. After target writes begin, DNS-only failback
would lose data; use the separately rehearsed reverse-transfer/replay path.

## Remaining releases

The owner explicitly retained existing phone/email OTP recovery and rejected
an additional password or recovery-key prompt. The password-protected-export
proposal for device recovery is superseded. The separate portable-export
primitives on main do not enable a new password prompt in login/device recovery
and are not a complete backup/restore flow. Device-only data recovery remains a separate design
and test gate before device encryption activation. Existing account login is
preserved, and phone-only data is not silently uploaded to add recovery.

This runbook covers the current recovery and identity foundation. Email/profile
and raw-payload encryption, the IMAP versioned envelope transition, remaining
abuse controls/jobs/deletion, full least-privilege review, console cookie/BFF
transition, device database/receipt encryption and signed-device verification
remain separate phases of the parent plan. Source tests and this operation
do not certify those unfinished controls.
