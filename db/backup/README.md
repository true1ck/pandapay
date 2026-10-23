# Paired PostgreSQL backup and recovery

The backup job streams the product and auth custom archives through `age`,
then encrypts the private schema/data/grants manifest. Plaintext dumps are
never written to the persistent backup directory. The backup host receives public
recipients only; the age identity used to decrypt belongs on the separate
recovery host.

## Backup host contract

Required environment:

- `PRODUCT_DATABASE_URL`: privileged read/dump URL for the product database.
- `AUTH_DATABASE_URL`: privileged read/dump URL for the separate auth database.
- `BACKUP_AGE_RECIPIENTS_FILE`: readable file containing one or more public
  `age1...` recipients. Private `AGE-SECRET-KEY` identities are rejected.
- `BACKUP_DESTINATION_A`, `BACKUP_DESTINATION_B`: existing writable mounted
  directories on two independent off-host failure domains. They must not be
  two paths on the backup host's local disk. The script cannot prove the
  physical failure-domain claim; the operator must provision and verify it.
- Optional `BACKUP_DIR` (default `/var/backups/pandapay`) and
  `BACKUP_MAX_RUNTIME_SECONDS` (default 1800, allowed 60–7200; terminates the
  export/inventory pipeline before releasing held snapshots on timeout),
  `RETENTION_DAYS` (default 7), `BACKUP_MAX_SETS` (default 7, minimum 5),
  `BACKUP_MAX_BYTES` (default 1073741824 = 1 GiB per location including pending
  ciphertext), `BACKUP_MIN_FREE_BYTES` (default 536870912 = 512 MiB) and
  `BACKUP_MAX_USAGE_PERCENT` (default 85). Measure pair size and host capacity
  before choosing deployment values. These are hard stop thresholds.

The job fails closed if either database URL, recipient file, or destination is
missing. Each destination receives an opaque set directory with
`product.dump.age`, `auth.dump.age`, `manifest.json.age`, ciphertext checksums
and `OFFSITE_COMPLETE`. The completion marker is written
only after both copies have been copied and verified. Retention considers only
completed sets and leaves at least the two newest sets in each location.
The two newest `RESTORE_VERIFIED` generations are also protected; older
verified generations can expire once newer verified evidence exists. Copy
verification markers to both destinations so each retention job has that evidence.
A job lock prevents cron/predeploy runs from interleaving. Retention applies
both age and count limits, including multiple predeploy backups in a day.
Ciphertext writes and copies check the byte cap and filesystem reserve before
every 1 MiB chunk. If protected generations cannot fit, the new backup fails
and retains recovery data. Incomplete generations from a failed run are cleaned.
The cron runs once per day at **02:15 UTC (07:45 IST)**. With seven ordinary
successful daily runs, the intended window is seven daily generations within
the byte quota; protected recovery evidence can exceed the age limit, but never
permits an unbounded new write. Backups need at least one pair's temporary headroom.
Restore verification is tracked separately; a successful copy is not called a
successful restore.

The encrypted manifest records database/server versions, encodings,
collations, schemas, extensions, table/partition/materialized-view exact row
counts and canonical row digests, sequences, RLS policies, column/constraint/
index/trigger definitions, application functions, database ACLs,
default ACLs, role attributes/memberships, migration ledger rows, and archive
checksums. The manifest is encrypted with the data. No database URL or secret
value is written to it or emitted in routine logs. Foreign tables are not
portable row storage and must be separately inventoried/exported before this
backup format can claim full data coverage.

The manifest captures database ownership, effective database ACLs, connection
limits, database/per-role settings, and PostgreSQL cluster-level parameter ACLs
such as `GRANT SET ON PARAMETER log_min_messages`. Parameter grants preserve
their parameter name, original grantor, grantee, privilege and grant-option
state in canonical `archives.*.database.parameter_grants` groups. Product and
auth databases share one PostgreSQL cluster, so their captured parameter ACL
inventories must be identical. Restore reconciles those
global ACLs exactly only on a freshly initialized isolated recovery cluster;
these grants affect the whole cluster, not just the generated restore
databases. Required object owner, ACL, RLS and per-role-setting roles are checked
with their attributes and all membership admin/inherit/set options. Functions,
aggregates, view definitions and user-defined type definitions are compared
alongside table data.
The archives preserve object ownership and ACLs, but do not import cluster
globals or provider-managed roles. Restores require a reviewed
`RESTORE_ROLE_BOOTSTRAP_FILE` that creates only the application's required
roles/memberships on the recovery PostgreSQL instance. Do not feed an
unreviewed `pg_dumpall --globals-only` file into a managed provider.

Provider initial schema grants can be absent from ordinary archive ACL entries.
After archive restore, the tool explicitly replays recorded schema ACLs with
their original grantors and grant options, inside a transaction on the generated
recovery database. Strict comparison still runs afterward; unsupported delegated
grant chains fail rather than silently broadening or omitting permissions.

## Temporary local PC setup approved by the owner

The owner chose this Mac as the initial recovery location while live server
hosting is unresolved. Set `BACKUP_MODE=local` and `BACKUP_DIR` to an owner-only
local directory. This explicit mode needs no destination A/B and produces a
`LOCAL_COMPLETE` marker plus `status=local_saved copies=1`. It uses the same
paired archives, encryption, manifest, quotas and independent restore checks.
It is a single local recovery copy; the two independent off-host copies remain
a later deployment/recovery gate.

`setup_local_recovery.py <folder> --age <binary> --age-keygen <binary>` prepares
owner-only keys, public recipients, scripts, an empty protected connection file
and a **not yet installed** 07:45 local-time launchd schedule. Setup itself never
activates it. On this Mac the canonical recovery folder is
`~/Library/Application Support/PandaPay/Recovery`, outside Git. The historical
`~/Documents/PandaPay-Recovery` path may remain as a symlink for interactive
convenience; launchd privacy permissions are path-sensitive and the symlink
does not grant a background job access to Documents.

macOS does not guarantee a launchd job can access protected Documents,
Desktop, or Downloads locations merely because an interactive terminal can.
Prefer Application Support for the recovery folder. After installing the plist,
verify the scheduled job by explicitly kickstarting it and checking
`status/last-run.log`; preparing the plist, bootstrapping it, or completing a
manual run alone does not prove the actual scheduled export works. The Mac must
also be awake and connected; this is not a continuous server job. Logs replace
`status/last-run.log` each run instead of accumulating indefinitely.

The recovery folder is configured with a 1 GiB archive cap, seven-generation
limit, 5 GiB minimum free space and 95% filesystem usage ceiling. Never copy
URLs or keys into this tracked documentation. A single local copy is not an
offsite recovery gate.

On this Mac, `--pg-dump-image pandapay-security-backup-test` installs a small
adapter using the reviewed local PostgreSQL 17 client image, matching the
source major. Docker Desktop must be running for these local backups. The
adapter mounts only the temporary connection workspace read-only; it receives
no recovery identity. An unavailable image or Docker engine causes a failed
run, without downloading another image. The archive manifest records the dump
client major as well as the server major, and rejects an older restore target.

Copy each whole completed set to the future recovery server, keeping its
marker and checksums. Transfer the private identity through a separate protected
channel and retain original application encryption/HMAC keys in secret escrow.
Mac-native binaries are not portable to Linux; install age/PostgreSQL clients
for the destination platform and use the included scripts.

## Recovery host contract

Required environment:

- `RESTORE_ADMIN_DATABASE_URL`: privileged URL on the independent recovery
  PostgreSQL host, used only to create/drop random drill databases and apply
  the role bootstrap.
- `RESTORE_PRODUCT_DATABASE_URL`, `RESTORE_AUTH_DATABASE_URL`: PostgreSQL URI
  templates on that same recovery host; their database names must differ. The
  drill derives random temporary database names from these URLs and drops only
  those generated names on exit.
- `RESTORE_AGE_IDENTITY_FILE`: readable recovery private identity. Never mount
  it into the production backup container.
- `RESTORE_ROLE_BOOTSTRAP_FILE`: operator-reviewed SQL for application roles,
  not provider/system roles.
- `RESTORE_STATUS_DIR`: protected writable directory on the recovery host for
  `RESTORE_VERIFIED-<set-id>` status records.
- `BACKUP_SET_DIR` to select a specific complete set, or `BACKUP_DIR` to
  select the newest complete set from a mounted/synced backup location.

The drill locks the selected backup root against concurrent retention, verifies
the completion marker and ciphertext checksums, decrypts the small manifest into
a restricted temporary directory, and streams both decrypted custom archives
directly to `pg_restore`. It never materializes full plaintext dumps. It checks
both PostgreSQL archives, restores both databases, and
compares exact row counts/digests plus schema/extension/RLS/function/grant
inventories against the encrypted source manifest. It writes a
`RESTORE_VERIFIED` marker only after both comparisons pass and removes the
throwaway databases and plaintext temporary files on exit. Keep the recovery
host and its URLs separate from the production host; this script accepts no
source DB URL and never creates a drill database on the source by derivation.

This is a paired logical recovery path, not point-in-time recovery. PostgreSQL
gives each database dump its own consistent snapshot; use a coordinated write
barrier (or a separately rehearsed cross-database journal) when one exact
cross-database boundary is required. Logical archives do not contain
provider-side files, Firebase/notification subscribers, mobile SQLite data or
unsynced device queues; inventory and recover those through their own paths.
Key bytes remain separate from archives and must be recoverable from the
operator's separately controlled escrow before a restore can be considered
useful. The recovery host can set `RESTORE_APPLICATION_CHECK` to the executable
`db/scripts/verify_recovery.js` from this checkout, install `auth/` npm
dependencies, and supply the retained phone encryption/HMAC keys through its
secret channel. This verifies phone decrypt/index behavior and product/auth
identity references without rewriting data. The status distinguishes
`database_restore_verified` from `application_check=passed` or `not_run`.
The full release still requires real-role and supported-client checks from
the implementation plan; the small built-in recovery check is not that full
release certification.

`RESTORE_UPGRADE_CHECK` can run a reviewed executable after exact restore and
application checks. It receives only the generated recovery targets and must
refuse live endpoints. Its result is recorded separately as
`upgrade_check=passed` or `not_run`. The local helper's `--contact-upgrade`
rehearses the approved test-account operation and idempotent replay; adding
`--product-baseline <reviewed-file>` also exercises canonical product checksum
adoption and verifies all original table data and migration history. See the
[controlled rollout runbook](../../docs/security-rollout-runbook-2026-10-23.md).

Each database's dump and row inventory share a held exported repeatable-read
snapshot. Sequence increments are not MVCC data: the dump's sequence setval is
authoritative, while the separately recorded live sequence values are advisory
and are excluded from strict equality. Two independently exported database
snapshots still require a write barrier/reconciliation journal for a coordinated
cross-database cutover. Recovery must use an independent endpoint; the encrypted
manifest contains source endpoint fingerprints and the drill refuses a match.

Portable recovery preserves object owners and ACLs. The reviewed role bootstrap
must recreate the required owner/grantee names and memberships. A provider that
cannot supply equivalent roles requires an explicit reviewed role mapping and
another rehearsal; do not bypass failed ownership or grant checks.

## Manifest compatibility and cluster checks

New backups use `pandapay-paired-postgresql-backup-v5`. It includes all v4
coverage plus canonical cluster parameter ACL inventories. Older v1/v2/v3/v4
sets lack required strict catalog coverage and are rejected; take a fresh v5
paired backup before using the current verifier. The v4 inventory used catalog
ACLs independent of the backup user's privilege visibility, captured original
extension/member owners, fixed the catalog deparse search path, and included
custom schemas such as `pgbouncer`; v4 remains historical evidence only and is
not sufficient under the v5 verifier.
Before any target role/database mutations,
the drill compares PostgreSQL `system_identifier` values and rejects the source
cluster, including a different hostname that reaches it. Endpoint fingerprints
remain supplementary evidence. If either endpoint denies `pg_control_system()`,
set `RESTORE_INDEPENDENCE_ATTESTATION=I_HAVE_VERIFIED_A_DIFFERENT_POSTGRES_CLUSTER`
only after verifying the target cluster independently. Do not set this blindly
on a production scheduler. Review required roles before running bootstrap SQL.

Use a newly initialized, isolated recovery cluster for the complete provider
schema and global-parameter-ACL rehearsal. Parameter ACL replay is refused
unless `RESTORE_PARAMETER_ACL_ATTESTATION=I_HAVE_VERIFIED_FRESH_ISOLATED_RECOVERY_CLUSTER`
is set. The drill connects to the `postgres` database, checks that `postgres`
and `template1` contain no user relations, and requires the cluster to contain
only `postgres`, `template0`, and `template1` before restore, then only those
databases plus the two generated restore databases before global ACL replay.
Do not set the attestation on a shared or live cluster: exact parameter ACL reconciliation
may revoke target-side parameter grants that are not in the source inventory.
The bootstrap superuser must match the recorded `plpgsql`
owner. Schemas and extensions are prepared with original owners; their archive
comments and ACLs are still restored. Recreating an extension owned by a
non-superuser temporarily needs that role to be superuser on the isolated
target, with its original flag restored in `finally`. This is refused unless
`RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION=THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER`.
Never attest this on a shared or live target. `rehearse_local_backup.py` sets it
only for the fresh, loopback-only, RAM-backed Docker cluster that it creates
and removes. It verifies all data and permission inventories plus the retained
application keys before writing recovery success.

The actual v4 local set `c5a7cb98fcf5d49eb784a26136be8959` passed this complete
restore and application check on 23 October 2026 IST: 173 product tables
(17,917 rows) and 8 auth tables (4,463 rows). This proves the local recovery
path for that snapshot. A future managed provider still needs its own full
capability/role/extension and write-barrier cutover rehearsal.

The confirmed source project runs PostgreSQL 17.6. Product extensions are
`citext 1.6`, `pg_stat_statements 1.11`, `pg_trgm 1.6`, `pgcrypto 1.3`,
`plpgsql 1.0`, `supabase_vault 0.3.1` and `uuid-ossp 1.1`; auth uses `plpgsql`
and `uuid-ossp`. A future host must support required extensions or receive an
explicit reviewed migration replacing their use, followed by another full
rehearsal. Stored Supabase Storage rows do not contain the external object
bytes. The actual source backup includes provider schemas; none are silently
excluded to make an export succeed.

Provider capabilities are checked by restoring and comparing actual extension
versions and ownership, not by assuming a `VERSION` clause was honored. Current
hosted Supabase can ignore extension version pins for ordinary users; see its
[extension version policy](https://supabase.com/changelog/extension-version-pinning-ignored).
The isolated recovery helper uses reviewed installed extension files as an
administrator. A future managed target that cannot reproduce these semantics
needs a separately reviewed role/extension mapping and another rehearsal.

Verified source TLS uses Supabase's official production root CA, downloaded
from the URL in its public dashboard source. SHA-256 certificate fingerprint:
`807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA`.
Keep this public CA separate from private application/age keys. See
[Supabase SSL guidance](https://supabase.com/docs/guides/platform/ssl-enforcement).
