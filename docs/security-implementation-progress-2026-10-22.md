# Security implementation progress — 22 October 2026

## Legacy sync isolation and saved-role review — 25 October 2026

[Current implementation](security-sync-isolation-implementation-2026-10-25.md) adds an additive seven-signature profile/device/search-path/ACL repair, strict exposure-role denials, recovered historical action SQL and encrypted read-only paired-restore privilege/history review. 1,024 API passes (two skips), 340 auth passes, 217 tools and 45 Python database/backup tests passed; native synthetic PG18 upgrade/replay/data/OID/dump/restore/financial checks passed. Existing encrypted PostgreSQL17 backup restore/review passed; its earlier upgrade attempt stopped at missing history, and the recovered file still requires an updated independently reviewed baseline. Saved strict role matrices remain unaccepted. [Evidence](../artifacts/security-sync-isolation-2026-10-25/verification.json). No deployment, original-key/data change or package/finding closure.

## OTP work and delivery admission — 25 October 2026

The first [next launch batch](security-next-launch-batches-2026-10-25.md) is implemented and locally verified: immediate per-process OTP work/email/SMS limits, shared dummy initialization, safe retryable 503 and exact undelivered-challenge cleanup, plus configuration-bound release acceptance. [Implementation](security-otp-admission-implementation-2026-10-25.md) · [Evidence](../artifacts/security-otp-admission-2026-10-25/verification.json). 340 auth, 211 tool and 22 deployment tests passed; 132 focused passes overlap those suites. Synthetic native PostgreSQL OTP/abuse regressions passed. No live send/deployment/data/key/password change; LP01/LP02 and actual provider/host/load acceptance remain open. Canonical counts are unchanged.

## Aggregate connection budget source — 25 October 2026

The [LP03 implementation](security-connection-budget-implementation-2026-10-25.md) adds an offline physical-cluster calculator and a bound aggregate release gate. Pools, replica ceilings, rollout overlap and provider/operations/safety reserves are counted; scalar totals alone cannot pass. 209 tool tests passed, including 42 focused checks (overlapping scopes). Runtime, data, keys, feature defaults and live services are unchanged. Production topology/capacity, independent recovery and the other launch gates remain unaccepted; counts are unchanged. [Scoped evidence](../artifacts/security-connection-budget-2026-10-25/verification.json).

## Production launch priority review — 25 October 2026

The [report now starts with ten ranked launch requirements](security-and-backend-audit-2026-10-20.html#production-launch-priorities) for the owner-confirmed target of 100,000 signups across day one. Read-only Supabase metadata/advisors were reviewed; capacity, provider, independent recovery and deployed-build acceptance remain open. No application/runtime change, live mutation, load test or finding closure occurred. [Priorities](../artifacts/security-production-launch-2026-10-25/launch-priorities.json) · [Metadata scope](../artifacts/security-production-launch-2026-10-25/live-metadata-summary.json).

## Typed sync and recovery coverage — 25 October 2026

The [new implementation record](security-sync-financial-recovery-implementation-2026-10-25.md) adds default-off typed sync with financial-state reconciliation, closes raw transaction status/delete paths in the API, and adds compatible recovery coverage manifests. Verification: 1,024 API passes (two existing skips), 195 tool passes, 1,634 app passes and 36 Node 22 sync/configuration passes; scopes overlap. Fresh/repeated PostgreSQL18 migrations, real-role typing/financial checks and full synthetic dump/restore passed. [Exact evidence](../artifacts/security-sync-financial-recovery-2026-10-25/verification.json). All 22 scoped findings remain unfinished; original keys, other data and normal mobile-storage defaults remain. No activation/deployment.

## Current sync/recovery checkpoint — 25 October 2026

The [new implementation record](security-sync-recovery-implementation-2026-10-25.md) records sync request checks, redacted per-item errors, recovery scope validation and bounded opt-in history provenance. Local results: 1,004 API passes (two existing skips), 193 tool passes, 1,631 app passes, 30 focused recovery passes and 16 Node 22 sync passes; scopes overlap. Analysis has zero warnings/errors and 80 infos. No finding was newly closed; 22 scoped findings remain unfinished. [Exact evidence](../artifacts/security-sync-recovery-2026-10-25/verification.json). Normal encryption/feature defaults remain off; full snapshot coverage and device/provider/custody acceptance remain.

## Current retained-reader batch — 25 October 2026

The [P05 source batch](security-key-readers-implementation-2026-10-25.md) adds compatible phone/recovery key readers and release inventory checks. Original keys and writers remain unchanged; no rotation/backfill/activation. [Exact verification](../artifacts/security-key-readers-2026-10-25/verification.json). All 22 scoped findings remain unfinished.

## Current execution batch — 25 October 2026

[Implementation and verification](security-execution-implementation-2026-10-25.md) records the first bounded P00/P01/P03/P04/P11 slices: transaction boundaries, retained-text history coverage, inventories and protected v1 data review. Existing app storage, keys and runtime flags remain unchanged; 22 scoped findings remain unfinished. [Exact evidence](../artifacts/security-execution-2026-10-25/verification.json).

## Remaining implementation plan — 25 October 2026

The [revised execution plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md#10-execution-backlog-and-ownership) maps all 22 unfinished D/N/M/W findings to 12 small batches inside the existing 14-package backlog. It defines dependencies, file ownership, tests, recovery rules and signed-device/actual-data/provider gates. First: freeze the candidate, review the protected current clone and prepare dependency/API boundary work. This was a documentation-only planning update; no implementation, application test, activation or status promotion occurred.

## Latest catalogue and gap-review checkpoint — 25 October 2026

The [catalogue batch](security-catalogue-implementation-2026-10-25.md) adds normalized uniqueness without rewriting labels, IDs or history, safe admin conflict responses, and corrected catalogue policy comments. D05 is partial: current-clone/pending-history and intended-provider acceptance remain. The [per-finding review](security-focused-gap-review-2026-10-25.md) lists all 22 unfinished scoped findings (19 partial, three open). [Current batch verification](../artifacts/security-catalogue-2026-10-25/verification.json). Earlier test counts below remain scoped to their dated batches.

## Current storage/dependency/documentation checkpoint — 25 October 2026

The [new implementation record](security-storage-implementation-2026-10-25.md) supersedes earlier batch counts for this scope. W01 architecture documentation is implemented in source; **22 scoped findings remain unfinished**. Cross-isolate key custody, verified encrypted DB-copy/receipt components and authenticated migration-state source were added. 1,625 full-app tests, 30 final focused storage tests, 154 tooling units and five isolated Android checks passed (overlapping scopes); exact source boundaries and current regressions are recorded in the [verification record](../artifacts/security-storage-2026-10-25/verification.json). Normal app storage/dependency locks and disabled feature flags remain unchanged. Atomic startup/switch, integrated receipt/recovery readers, signed-device/provider/custody acceptance remain.

Parent: [implementation plan](security-implementation-plan-2026-10-22.md).

## Earlier D/N/M/W checkpoint — 25 October 2026

The [current implementation record](security-dnmw-implementation-2026-10-25.md) and [verification](../artifacts/security-dnmw-2026-10-25/verification.json) supersede earlier local-test counts for this batch.

| Area | Current progress |
| --- | --- |
| App | 1,606 tests passed; zero analysis errors/warnings; current dev debug APK built locally |
| Backend | API: 968 passed, two DB-dependent skips; auth: 312 passed; changed recovery routes: 12 Node 22 container tests passed |
| Database tools | 28 focused unit tests and disposable PostgreSQL index/data/automatic-consent fixtures passed |
| Recovery | Fresh encrypted PostgreSQL pair restored with retained original keys; 355 product and 10 auth read-only checks completed, zero checked FK orphans |
| Mobile recovery | Automatic updates after explicit opt-in, existing OTP and no extra password implemented in source; two isolated Android key/encryption component tests passed |
| Finding counts | 76 total: 26 implemented in source, 43 partial, seven open; D03/D04/D05 moved to partial; 50 remain unfinished |
| Remaining scope | 14 implementation packages / six release gates; signed-device, complete storage conversion, target-provider, full secret/native-dependency and custody/rollout acceptance remain |

Recovery and live storage encryption remain disabled. No production deployment or live database data/schema/key change occurred. See the [recovery flow and scenarios](security-recovery-flow-2026-10-25.md).

## Remaining-work count — 25 October 2026

The [numbered remaining-work register](security-remaining-work-2026-10-25.md) groups the full backlog into **14 implementation packages and 6 validation/rollout gates**. Across 76 tracked findings, 26 are implemented in source, 43 are partial and seven are open. These counts describe different units and must not be added together. Source implementation is not production closure.


## Earlier follow-up — 25 October 2026

The [25 October follow-up](security-next-implementation-2026-10-25.md) adds opt-in six-digit verified contact replacement, bounded DB-aware reconciliation of journaled recovery receipts and a disabled operational webhook adapter with its own release gate. [Current evidence](../artifacts/security-followup-2026-10-25/batch-verification.json) records the combined local verification; the [preceding Docker batch](security-local-docker-verification-2026-10-24.md) remains historical. Supported-client/provider acceptance, native key custody/resumable live storage encryption, complete native crash/writer coverage, actual-data/provider reconciliation, monitored operations and independent recovery custody remain open. No live configuration, data, key, contact, provider or deployment change occurred.

## Additional source — recovery, maintenance and permission repair

The [local Docker verification](security-local-docker-verification-2026-10-24.md) now records fresh current-source results: 964 API passes (two database cases passed separately), 300 auth, 131 database/tool, 45 backup/setup, 22 deployment, 1,576 app, 31 console and 227 domain cases. Four current security fixtures passed on Docker PostgreSQL 17; the complete 14-script/15-database harness and paired encrypted v5 recovery passed on temporary PostgreSQL 18. Exact images, non-root source readability, both services’ real health/readiness, console CSP build and zero-known-vulnerability dependency audits passed. Earlier approval-review usage failures have been resolved for these local runs. Flags remain off; actual-data/provider/browser/signed-device/custody acceptance and deployment remain pending. Original keys/data and all twelve notification edits are preserved.

## Latest source batch — 24 October 2026

The [R1–R10 plan](security-remaining-implementation-plan-2026-10-23.md) now includes R3 bounded retention, R4 privilege audit, R6 browser cookie sessions and proof-only own-account status, R7 durable two-database soft deletion/tombstones, R8 password-free recovery modules, R9 restored-copy reports and R10 strict exact-source release gating. Existing OTP/masked-email recovery and original UUID/history/key semantics are preserved. No new end-user password is introduced.

The [source runbook](security-remaining-source-implementation-2026-10-24.md) records configuration, limits and activation gates; [remaining-batch verification](../artifacts/security-implementation-2026-10-24-remaining/batch-verification.json) records current hashes/tests. Earlier [capability evidence](../artifacts/security-implementation-2026-10-24/batch-verification.json) and actual-data recovery below are historical scopes. Current synthetic role/recovery tests are not actual-data/provider/signed-device certification.

**The full plan is not complete.** Broader privilege repair, legacy anonymous lookup/OTP transition, actual browser/provider acceptance, independently retained lifecycle journal, remaining monitored jobs/outboxes, recovery UI/operation barriers and resumable live storage encryption remain. Lifecycle/recovery/optional logging/polling stay off; no actual secret was generated or rotated. The new web bundle and cookie gateway must ship together. Actual-data current-candidate recovery, independent off-host copies, separate key custody and intended PostgreSQL cutover/failback remain release gates. All 12 notification edits are preserved. Changes are local and uncommitted on `dev`; no live mutation, provider message or deployment occurred.

## Follow-up implementation — 24 October

The [OTP/journal/OCR runbook](security-followup-implementation-2026-10-24.md) records additive six-digit v2 OTP, external age-encrypted deletion intents and separate latest checkpoint before denial commit, existing-tombstone bootstrap/reconciliation, account export/session fencing and active OCR temporary-file cleanup. The API body-parser lock is patched and a compressed-body crash regression added. [Follow-up verification](../artifacts/security-implementation-2026-10-24-followup/batch-verification.json) records fresh suites, managed PostgreSQL 17 and exact source. Feature activation, actual provider/device/custody acceptance and remaining broader source work remain open. Original keys/data/login/notification semantics are preserved; no live change or extra password is introduced.

## Earlier foundation record

Updated: 23 October 2026 (IST). The first implementation batch prepares the recovery/migration foundation and
selected containment controls. It has not been deployed and does not close the
entire security audit. No deployed schema, application data or encryption key
was changed. The owner confirmed Supabase project `chgkmvmoqehbgkccrqbs`.
Verified read-only connections identified product database `postgres` (~40 MB)
and auth database `pandapay_auth` (~11 MB), both PostgreSQL 17.6. The live
API/auth services were located on their existing trusted Oracle VM
(`api.pandapath.site` / `auth.pandapath.site`, same machine), with ~31 GB free.
No server configuration or service was changed. Eight historical restore-drill databases
(~180 MB combined) were inventoried and left untouched.

## Release source reconciliation

The initial checkout was `aca220a`; the live server was found at the newer
`da2b1a086a1a05e9093ec09c872031eb1ff8d13f`. An isolated integration branch,
`codex/security-portability-20261023`, was prepared from `origin/master` at
`89d98e2`, preserving newer SMS features, all deployed migration files and
optional worker setup. It was subsequently advanced through `1cdd44a` to
`6544d79729b0b421e88eb08f793cbf8b79269126`, retaining the portable-export
feature and main's later revert of unrelated SMS changes. All 97 applied
product migration files match the exact
deployed source bytes. A held-snapshot read-only schema/history baseline and
read-only `--check` passed: 97 legacy entries, one pending security migration.
No live checksums were adopted. The complete actual-copy product upgrade and
replay passed against the reviewed v2 baseline, preserving every original
product table and ledger timestamp. The v2 fingerprint retains definitions,
CHECK semantics, ownership and effective ACLs. It accounts for PostgreSQL
deparser formatting, provider initial-grant serialization and locale-dependent
catalog ordering without excluding those security properties. Version 1
baselines require fresh capture and review.

The reviewed source was transferred into the normal project folder on
`codex/security-foundation-20261023`, based on `6544d79`. The owner subsequently
requested committing and publishing this source on the `dev` branch. All 1,553 tracked
source paths matched the tested isolated checkout byte-for-byte at transfer.
The original `aca220a` working changes remain in a recoverable Git safety stash;
its identifier and the preserved old ignored auth lockfile are recorded in
the private recovery folder. Verification preceded source publication;
publishing `dev` does not deploy services or change the live databases.

The [controlled rollout runbook](security-rollout-runbook-2026-10-23.md)
records the approved account operation, writer fence and forward recovery.
The [secrets inventory](security-secrets-inventory-2026-10-23.md) records key,
credential, backup and private recovery-index locations without secret values.
The [completion checklist](security-completion-checklist-2026-10-23.md) maps
the completed foundation and remaining work to every phase of the parent plan.

## Implemented in source

- One local/staging/production migration orchestration path now invokes auth
  schema and data work. Product migration DDL and ledger writes are atomic,
  historical outer transactions are normalized, and migration role changes
  are reset before recording success. Both runners lock a dedicated session,
  use timeouts and record/validate checksums.
- Existing product ledgers without checksums require a read-only generated,
  independently reviewed schema/history baseline plus explicit adoption.
  Unknown/changed history fails. Auth verifies its known legacy migration's
  columns/indexes before adoption; empty auth databases bootstrap their schema.
- Phone hash work uses bounded keyset batches, original-value conditional
  updates, restart verification and full digest checks. Existing non-null
  hashes are checked before missing hashes are written. Original phone
  ciphertext and encryption/HMAC keys remain unchanged.
- Production/staging phone encryption configuration fails closed. Wrong keys,
  tampered/unknown ciphertext and unrecognized legacy phone values cannot
  silently become plaintext. Explicit local development plaintext mode remains.
- API/auth database connections verify trust/hostname, including SSM auth and
  parsed URL TLS settings. Optional extra public CA roots are configurable.
  Live read-only access passed with Supabase's official 2021 CA. Its public
  certificate and confirmed source URLs were saved in the protected local
  recovery config; no credentials were emitted in chat.
- Both databases stream into portable encrypted backups with per-database
  snapshot-consistent inventories and two verified destination copies. Recovery
  runs against a different cluster, streams decrypted archives, restores
  owners/database ACLs/settings and compares all-table digests, view/function/
  type definitions and required role semantics. Cluster IDs are checked before
  any recovery mutation; hidden IDs require independent operator attestation. Key/identity checks are separate from database restore
  status. Physical independence of destination mounts needs operator evidence.
- Backups run daily at 02:15 UTC / 07:45 IST. Storage now has a seven-set,
  seven-day policy, a 1 GiB per-location ciphertext cap, filesystem reserves,
  bounded writes/copies and multi-root job locks, interrupted-run cleanup and bounded same-snapshot retries. The newest two complete and newest two
  restore-verified generations are protected; older verification markers no
  longer pin every backup forever. Quota failures preserve recovery data.
- The owner chose a local PC folder until server hosting is resolved:
  `/Users/chandresh_kerkar/Documents/PandaPay-Recovery`. It contains an owner-only
  recovery identity, public recipients, tooling, protected confirmed source config
  and a daily 07:45 local launchd schedule. Final launch verification found that
  macOS refused background access to the original Documents script (exit 126).
  The physical folder was moved to owner-only
  `~/Library/Application Support/PandaPay/Recovery`; the Documents path remains
  a shortcut to the same location. The launch agent uses the canonical path.
  An actual kickstarted launchd run completed with exit 0 and saved fresh v5
  set `0d6c2853aaf4a5417e0628ed7f33bb63`; this verifies background execution,
  rather than only schedule installation. The backup folders remain well
  below the 1 GiB cap (about 30 MB across five sets at this check). This fresh
  set also passed the complete independent local restore, retained-key checks,
  product/auth upgrade and replay at `2026-10-23T05:48:24Z` (11:18:24 IST).
  The job is installed in `~/Library/LaunchAgents` to reload at login; the Mac
  still needs to be awake/connected with Docker running at execution time.
  Live paired exports completed with matching PostgreSQL 17.11 dump tools:
  173 product table digests and 8
  auth table digests, about 7.3 MiB total including encrypted manifest. Both
  archives passed full age authentication and streamed pg_restore SQL parsing.
  An earlier v4 set passed actual independent PostgreSQL 17.6 restore,
  exact schema/data/ACL comparisons and retained-key/application checks at
  2026-10-22 18:36:55 UTC (23 October 00:06:55 IST). All 17,917 product rows
  across 173 tables and 4,463 auth rows across 8 tables were verified,
  including 8 users, 97 OTP records and 7 profile references. The recovery
  cluster used loopback-only access and RAM-backed data storage and was removed.
  Local mode reports one local copy. Its
  archive cap is 1 GiB, with 5 GiB free-space floor and 95% usage ceiling.
- Expanded fingerprint review found a real recovery gap: the cluster-wide
  `log_min_messages` parameter ACL was absent from v4's inventory. Fresh v5
  set `8d7a225f3dc569431b91be96fb9d1c64` captures matching global policies in
  both archives, preserves original grantors/options and passed the complete
  actual-data restore plus product/auth upgrade and replay. That proof covers
  172 original product data tables plus the separately checked product ledger
  (98 entries after upgrade), seven original auth data tables plus its ledger,
  all eight account IDs, seven profile references and two encrypted contact
  archives. Old archives remain preserved; the current strict verifier requires
  v5. Global ACL replay additionally requires a fresh isolated-cluster
  attestation, an empty `postgres` and `template1`, and the exact expected
  database inventory. Shared/live targets are refused.
- Supabase's published [security policy](https://supabase.com/security) states
  that all customer data is encrypted at rest with AES-256. This is provider
  attestation, not an independent inspection of the physical disks. Export
  encryption and application keys remain portable and separately controlled;
  a future host must supply its own disk-encryption evidence.
- Recovered the original running auth encryption/lookup keys into owner-only
  `keys/application-keys.env` as requested. Live read-only key verification
  passed all 8 users and 97 OTP rows; 7 product profile identities reconcile.
  Existing API data-protection keys were also preserved. The deployed server
  `.env` was streamed into a separate age-encrypted recovery artifact. No key
  values were printed, committed, replaced or rotated.
- Durable OTP purposes are stored for new challenges. Sign-in, recovery and
  contact replacement scope lookup, resend deletion, attempts, atomic consume
  and delivery cleanup separately. Historical NULL purposes remain sign-in
  only. The additive migration must run before the new auth service; old
  writers must be fenced before relying on purpose-aware behavior.
- Hosted OTP and enumeration quotas use bounded PostgreSQL storage with opaque,
  domain-separated HMAC keys, fixed database-clock expiry and atomic counters.
  Expired rows are removed in bounded locked batches; a configured live-row cap
  refuses new keys at capacity. Counters saturate at the policy threshold plus
  one. Hosted storage failures return 503 before delivery and never downgrade
  to process memory. Atomic active-OTP claims occur before OTP-row changes, so
  concurrent requests cannot send competing codes. Compare-delete cleanup cannot
  clear a newer claim. Contact replacement requests and verification attempts
  additionally consume stable account/channel budgets, preventing randomized
  challenge identifiers from resetting their quota.
- A separate auth runtime principal can receive only the new bucket table's
  SELECT/INSERT/UPDATE/DELETE rights via the explicit actual PostgreSQL role
  setting `AUTH_RUNTIME_ROLE`. Its existing public-schema USAGE is required.
  Hosted readiness checks all four permissions and relation access before
  traffic is reopened. Pooler URL usernames are not treated as role names.
- Product runtime access to the migration ledger is revoked, including after
  the role bootstrap's broad grants. The complete role/definer audit and a
  separately provisioned limited auth login covering the whole auth schema
  remain later work. `AUTH_RUNTIME_ROLE` only configures the new bucket table's
  grants; it does not create a role or complete that broader privilege audit.
- Added a count-only, read-only contact uniqueness audit with bounded database
  timeouts. The owner chose contact reuse after deletion, with deleted rows
  and their original history preserved. The live audit found 8 non-deleted
  users, unique valid email identities, 6 complete phone hashes and no undefined
  deletion states. It also found **2 duplicate phone groups across 4 accounts**.
  No unique index, account merge, contact reassignment or data deletion was
  applied live. The owner confirmed these are test accounts and approved the
  private proposal's exact keeper accounts. Selection prefers phone-verified
  accounts, then the oldest account. Both actual groups contain no
  phone-verified account, so the approved oldest accounts retain their
  existing unverified flag. Secondary accounts retain
  verified email login and original contact values are archived with age.
  A second actual-copy rehearsal passed this approved resolution, all original
  auth-table data checks, preservation of all 8 account UUIDs and 7 profile
  references, new partial unique indexes and idempotent replay. That copy was
  discarded; live test identities remain unchanged until the controlled rollout.
- Auth migrations reserve `9xxx_` for post-backfill constraints, prevalidate the
  complete ledger before either phase and allow checksum-less adoption only
  for historically deployed `0001`. A restricted contact history table is
  created by `0003`; the approved operator tool runs under the same advisory
  lock after hash verification and before `9001`. Active email/phone uniqueness
  permits reuse after deletion. Recovery/Google/email lookups and uniqueness
  conflict responses are aligned with that policy.
- The legacy token-validation route now uses authoritative current-session
  verification, preserving the success payload and invalid/200 response while
  reporting unavailable verification as 503. Guests, inactive/deleted users,
  revoked devices and changed token versions are denied. Hosted production/
  staging no longer expose the public OTP test harness; protected admin and
  readiness routes retain their separate guards.
- Console refresh clears saved tokens only on definitive 401 invalidation.
  Network, 503 and 403 failures retain the saved session and show a generic
  retry screen. Synthetic retry and successful-session tests pass. This does
  not implement the later cookie/BFF browser-session transition.
- Structured request logs use route templates, omit query values and exclude
  arbitrary exception contents. Auth console debug/provider/token/error logs
  were sanitized across service, middleware and route code. Durable security
  audit contents remain intentional and need their own access/retention policy.
  Correlation IDs accept only bounded ASCII identifier strings; invalid or
  oversized input gets a new UUID, preserving normal cross-service IDs.
  API route, database pool, import/provider, worker and admin console error
  sinks now use bounded error codes/classes. IMAP login failure responses use
  static messages while preserving the `{ok, reason}` contract.
- Both IMAP connectors share a public-destination guard with pinned DNS results
  and TLS hostname/trust verification. Control characters are rejected before
  IMAP commands, login responses have a 64 KiB limit and polling counts UTF-8
  bytes within 8 MiB. Failure/timeout closes sockets. The verified source
  snapshot had no saved IMAP connections; private/special destination settings
  are retained but refused when connecting, rather than deleted.
- API/auth proxy trust is explicit: local zero hops, documented production/
  staging Nginx one hop, with malformed resolved IPs rejected. Nginx overwrites
  X-Forwarded-For from the peer. Legacy boolean true maps to bounded one-hop
  trust for compatibility; additional proxies need an explicit topology review.
- Deployment builds target images and runs read-only history/conflict checks
  before downtime, then stops API/auth, rewards, optional Gemini and SMS
  learner writers before the final paired encrypted backup and migrations.
  Running service labels are checked. The reviewed stateless legacy maps
  scraper has no database configuration and remains running; other unreviewed
  services block downtime. Reviewed baseline mounts use the protected host
  directory even while source is built from a temporary commit archive.
  The stopped-service work has a bounded maintenance window. Pre-source
  backup failures resume captured original containers; failures after source
  replacement stop writers and require forward repair. This avoids old OTP
  writers/verifiers and phone backfill races during the rollout. The
  new configuration fails before that point if recovery destinations/recipients
  are absent. CI includes a disposable two-instance recovery rehearsal.
- The workflow verifies a successful build for the exact master commit before
  deploying, including manual dispatch. Production smoke checks readiness and
  anonymous denial without minting a fake user token or calling metered/live
  location providers. Authorized supported-client checks remain a release gate.
  Immediately before deployment, the workflow and host require the current
  master tip; the host also requires the deployed HEAD to be its ancestor.
  Delayed successful builds therefore cannot silently deploy older source.
- The newer SMS learner uses the same verified database TLS resolver and CA
  configuration. New SMS route/worker error logs and persisted worker failure
  reasons contain bounded classifications rather than exception contents.
- Auth now tracks its dependency lockfile and installs it with `npm ci` in
  the image and build gate. Its old dependency tree contained known advisories;
  the reviewed update uses Nodemailer 10.2.1 and patched transitive packages.
  Both auth and API dependency audits report zero known vulnerabilities at
  this check. Node 22 or later is required for auth, including standalone
  setup; development reload uses the built-in watcher. Production/staging SMTP
  requires STARTTLS for port 587, keeps implicit TLS on 465 and verifies the
  certificate/hostname. Timeouts and file/URL access restrictions are explicit.
  Synthetic SMTP acceptance, rejection and missing-STARTTLS checks pass; no
  live provider message was sent. Service build contexts include source and
  package metadata and exclude local environment and dependency folders.
- Reviewed the newly integrated portable account-export primitives. Fixed
  first-page PostgreSQL bind counts and settings cursor pagination, bounded
  backpressure/export duration and rate-map storage, and limited concurrent
  exports to one per API process. A response is capped at 64 MiB and one
  million records; limit failure cannot emit a successful completion footer.
  The schema-aware coverage registry now classifies 132 declared persistent
  product migration tables, including explicit referral/credit scope gaps.
  These account exports are incomplete and do not replace the full paired
  database backups or implement password-free device recovery.

## Verification

The local rehearsal uses synthetic records, temporary PostgreSQL clusters and
the official age binary with a checked SHA-256 digest. It covers empty install,
repeated migrations, legacy plaintext plus encrypted phone rows, original-key
backfill, rejection of a changed HMAC key, encrypted export, independent-instance
restore, whole-table/schema/ACL comparison and retained-key/identity verification.
The test stops and removes its own clusters and never connects to an existing
database. Integrated full API tests passed (786 pass, two skipped), auth tests passed (154), and the
synthetic independent PostgreSQL recovery rehearsal passed. Storage/failure
coverage includes quota and disk-floor refusal, retention of recent/proven
sets, concurrent-job rejection, partial ciphertext cleanup, local mode restore
and libpq TLS option rejection. All 45 focused backup/recovery/setup tests passed,
including runtime timeout cleanup, catalog ACL replay and explicit extension
bootstrap gating and idempotent setup preserving installed tools/keys. All 21 deployment ordering/restart tests passed with stubs.
Console tests passed (19) with no issues from the focused analyzer.
The final integrated app suite passed (1,466 reported cases, seed 6544), including local
database, financial store and sync-queue tests. App analysis reported no errors
and 51 informational lint notices. A pre-existing PDF-import widget test could
return before asynchronous parsing began; it now waits for the expected
completed UI and restores its file-picker mock. The focused file passed three
consecutive randomized runs, followed by the successful full seeded suite.
These are synthetic source checks, not
signed-device upgrade or key-loss recovery evidence. Flutter package versions
were preserved using the existing package cache; auth dependencies were
updated separately to remove known advisories.
The real PostgreSQL fixture upgrades the old OTP schema, preserves unknown
legacy purpose and tests purpose separation and concurrent single-use. Local
backups use a matching PostgreSQL 17 dump client via the reviewed Docker image;
manifest v5 enforces target compatibility with both source and dump client,
uses privilege-independent catalog ACLs and fixed catalog deparse paths,
includes `pgbouncer`, and records extension/member ownership. Provider initial
schema grants omitted by ordinary dumps are replayed from the manifest before
strict equality verification. Cluster parameter grants are separately replayed
and checked on an explicitly fresh isolated target. The actual-data restore passed all these gates;
no permissions or schemas were excluded to make it pass.

## Required before deployment and later phases

1. Actual export, independent restore and retained-key checks are complete and the
   local schedule is active. Configure/verify actual independent off-host mounts,
   public backup recipient,
   separately recoverable private identities and the recovery operator/host.
   Repeat recovery on that separately controlled off-host recovery environment.
   The actual-data proof used a local independent cluster on the same Mac;
   it does not prove survival of loss of that Mac or a managed target's
   role/extension capabilities.
2. Hosted PostgreSQL 17.6 and CA trust are confirmed; keep dump clients at least
   that major. Applied source provenance and the live read-only legacy preflight
   and actual-copy product adoption/replay are verified. Review the final source,
   configure the reviewed baseline for the controlled rollout, and inventory
   current free-host quotas, scheduler behavior and provider roles.
3. Finish and verify P2–P7: contact uniqueness and remaining
   auth controls and API log review, complete permissions/integration/lifecycle jobs,
   console session transition, staged local database/receipt encryption and
   supported-device/old-client/release checks.
   Active duplicate phone identities remain a live P2 rollout gate. Their exact
   resolution is owner-approved and actual-copy tested; apply it only through
   the coordinated fence/backup/migrate/verify sequence in the runbook.
   The owner rejected an extra user password for device recovery; choose and
   test password-free recovery before enabling device/receipt encryption.
4. Rehearse the actual provider-to-provider cutover and post-write failback
   procedure. No live database migration, key rotation or deploy
   has been performed by this batch.

Three Luna agents produced the migration, TLS and backup starting changes and
reviewed integration risks. After temporary usage/connection limits cleared,
the agents resumed OTP purpose binding, backup storage/recovery fixes and
independent review. The coordinator handles shared integration and verification.
