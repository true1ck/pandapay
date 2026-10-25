# Data, dependency, mobile and documentation implementation plan

**Production launch ordering — 25 October 2026:** the owner confirmed 100,000 completed signups across the first day. Use the [ranked launch priorities](security-and-backend-audit-2026-10-20.html#production-launch-priorities) before selecting the next source batch. Actual deployed isolation, independent recovery, aggregate hosting/pool/storage and OTP budgets lead; staged typed/mobile features stay off until their acceptance gates pass. The LP01–LP10 rows overlay this plan and add no vulnerability counts.

Updated: 25 October 2026 (IST), execution revision 2. Status: **remaining implementation planned against current source; release acceptance pending**. The planning revision itself added no runtime change; the later [execution checkpoint](#12-current-execution-checkpoint) records newly implemented and verified slices.

This plan covers **22 unfinished findings** in the requested four sections: **D01–D05; N02 and N04; M1–M10; W02–W03 and W05–W07**. Nineteen are partial and three are open. W01 documentation source is complete; its architecture links remain part of release maintenance. D03/D04/D05 progressed to partial after reviewed tooling, additive normalized uniqueness and local preservation fixtures; target workload/activation work remains. N01, N03, W01 and W04 now have source remedies; retain their regression and release checks.

These sections contain 26 findings altogether. This is a focused execution plan within the existing [14-package backlog](security-remaining-work-2026-10-25.md), not 22 additional projects or a change to that count. Six phases organize the work; data, dependency and documentation preparation can run in parallel after the baseline is captured.

## 1. Existing foundation and constraints

Build on the existing compatible OTP clients, password-free recovery, writer leases, tracked drain, encrypted-copy/receipt/key/journal components and PostgreSQL recovery/review tools. The [catalogue batch](security-catalogue-implementation-2026-10-25.md) records 981 API passes, two DB-dependent skips, 155 database-tool passes and separate PostgreSQL preservation/restore checks. The [storage batch](security-storage-implementation-2026-10-25.md) records 1,625 full-app passes and five isolated Android checks with exact source boundaries. These are dated results, not checks performed by this plan. Normal AppDatabase startup still uses plaintext SQLite, current app locks remain unchanged and recovery activation stays off.

Working rules:

- Preserve the whole PostgreSQL dataset, account UUIDs, financial/history rows, pending mutations, guest/account namespaces, receipts and original encryption/HMAC keys. Keep PostgreSQL when changing provider.
- Use a protected full restored copy before data/role/index changes. Reports in Git contain counts, definitions and digests; customer IDs, private ID maps, records and keys stay in encrypted/private storage outside Git.
- Use existing email/phone OTP and masked-contact recovery. Introduce no new user password or recovery-key-file requirement. Do not silently upload phone-only data or gallery files.
- Preserve existing API field meanings, released-client behavior and the twelve unrelated notification edits. Additive formats and compatible readers precede new writes or constraints.
- Fit measured free-host disk, connections, memory and provider quotas. Do not add a paid service or increase limits on assumption. Keep the existing local backup policy: daily 07:45 IST, seven days/seven sets, 1 GiB cap, 5 GiB free-space floor, 95% usage guard and 30-minute run limit. The Mac and its folder/shortcut count as one failure domain.
- Preserve deleted-contact reuse and the approved intentional-test-account phone ownership decisions. Separate code completion, local verification, actual-data/device acceptance and production activation. Planning does not close a finding or enable a flag.

The executable queue is in [section 10](#10-execution-backlog-and-ownership): **12 small batches**, inside the existing 14-package backlog. Each has a dependency, owning files, deliverable, test scope and exit rule. The [gap review](security-focused-gap-review-2026-10-25.md) remains the per-finding source of missing work.

## 2. Sequence and dependencies

| Phase | Work | Depends on | Completion checkpoint |
| --- | --- | --- | --- |
| 1 | Capture baseline, inventories and proof contracts | Existing source/evidence | Exact candidate and scoped findings mapped; private clone/device boundaries recorded |
| 2 | Data equivalence, reversible reconciliation and index decisions | Phase 1; current full restored copy | Reviewed mapping and preservation proofs pass on the clone; live changes still gated |
| 3 | Dependency and release-artifact hardening | Phase 1; supports phases 4–5 | Reviewed locks/native artifacts and compatible candidate builds, with unresolved advisories explicit |
| 4 | Mobile boundaries, recovery, key custody and encrypted storage | Phase 1; phase 3 native-engine selection; approved recovery policy | Staged code and synthetic native failure matrix pass; activation remains off |
| 5 | Signed-device, provider and actual-data acceptance | Relevant phases 2–4 plus external prerequisites | Exact release passes applicable G01/G02/G03/G05 checks without data loss |
| 6 | Reconcile documentation and close accepted findings | Documentation starts in phase 1; final closure follows phase 5 | MD/HTML/runbooks match actual evidence; unresolved dependencies and rollout gates stay visible |

Do not gate independent work on an unavailable production host or phone: continue clone-safe tooling, dependency review, synthetic fixtures and documentation. Do not replace missing acceptance with a passing mock or simulator result.

## 3. Phase 1 — baseline and inventories

### Deliverables

1. Freeze the candidate source/configuration/lockfile hashes and existing-edit hashes. Inventory changed API/auth/app/console/migration/native files; keep the unrelated notification work intact.
2. Restore a current completed encrypted product/auth pair into an isolated PostgreSQL cluster with retained keys. Record backup identity, database major versions, schemas/extensions/owners/ACLs, migration checksums and count/financial digests. A historical export is insufficient evidence of the current production dataset.
3. Produce a dependency inventory for API/auth locks, app/console and shared Dart packages, vendored telephony, Android Gradle/native libraries, iOS Pods and Swift packages. Record resolved transitive versions, provenance, license/support considerations and affected runtime paths.
4. Inventory mobile writers/readers: foreground DB connections, SMS/background isolates, sync/outboxes, attachment add/view/delete, OCR temporary files, guest migration, logout/account switch and upgrade/startup recovery. Inventory persisted sensitive data and every copy, including deferred SMS, WAL/SHM and temporary files.
5. Create a documentation claim register: claim, authoritative source/configuration, implementation evidence, deployment evidence, date and status. Mark historical measurements explicitly.

### Controls

Use synthetic test accounts by default. Restore actual data only into the protected clone; never copy live credentials into a sanitized test checkout. Confirm test package IDs before installing on devices. Reuse the original signing identity only through the approved local signing process; no secrets are printed.

## 4. Phase 2 — data reconciliation (D01–D05)

D05 source progress: [versioned catalogue identity batch](security-catalogue-implementation-2026-10-25.md) preserves stored labels/IDs and refuses collisions transactionally. Local preservation/race/dump-restore tests pass. It does not rewrite the historical dedupe migration or establish actual-data/provider acceptance. [Per-finding gaps](security-focused-gap-review-2026-10-25.md).

### Batch D-A: read-only report and semantic proposal

Use the existing `db/scripts/review_data_cleanup.js` on the restored copy. Its report is counts/catalog/digests only and does not choose survivors or return private ID maps. Historical 20-extra-cap/four-extra-benefit counts must be remeasured; they are not assumed current.

- Compare product, issuer, reward/currency/unit, cap/benefit period, category, threshold, conditions, validity dates, version and provenance. Equal display names alone never establish equivalence.
- Inventory every reference and consumer: cap state, benefit usage, transactions, entitlements, catalogue versions, parser/rule evidence, exports, sync cursors and offline queued requests. Inspect declared foreign keys and code/JSON references.
- Put an explicit old-ID-to-canonical-ID proposal and original row state in private encrypted review storage. Choose survivors through business review, not automatic oldest/newest/name matching. Keep non-equivalent rows and their explanation.

Checkpoint: complete visibility under the review identity, no unknown reference owners, and an explicit retain/canonicalize decision for each candidate group.

### Batch D-B: reversible mappings and constraints

- Add alias/mapping support before changing consumers so historical and supported-client IDs remain resolvable. Preserve account UUIDs and original financial/history evidence.
- Implement a source/catalog/target-bound dry-run and apply receipt. Rehearsal rolls back. Use bounded keyset batches, durable checkpoints, idempotent continuation and a pause on unexpected counts or concurrent changes.
- Rewire only reviewed references transactionally. Retain the original row/provenance or a lossless archive required to reproduce prior calculations. Do not rewrite historical reward or cap decisions to match today's catalogue.
- Add normalized uniqueness only after data reconciliation and a concurrent-writer plan. Preserve deleted-contact reuse and existing lifecycle policy where identity tables are involved.
- Recheck before application: counts, row/ID digests, amounts, cap consumption, benefit usage, valid references, historical rules/parser fixtures and old-ID behavior. A data rollback after new writes requires a tested reverse/forward mapping; replaying an old dump is not a routine rollback.

Checkpoint: repeat/interrupted runs preserve all business invariants, and supported API/app/worker flows pass under actual runtime roles on the clone.

### Batch D-C: reviewed index remove/retain decisions

For D03/D04, inspect index definitions, predicates, included columns, operator classes, ordering, constraints and consumer query plans. Protect the partner-click uniqueness constraint and every constraint-backed index. Compare representative read/write plans and latency on realistic data, including provider/major-version differences.

Apply only the reviewed decision. Choose a lock/concurrency approach compatible with the migration runner; do not place `CREATE/DROP INDEX CONCURRENTLY` inside an automatically wrapped transaction. Preserve a recreation definition and verify application behavior afterward. Keeping an index is valid when removal lacks a measured benefit; document the decision rather than dropping it to clear a checklist.

## 5. Phase 3 — dependencies and release artifacts (N02, N04, M1, M2)

### Batch N-A: inventory and fresh advisory review

- Review the complete resolved dependency trees and native artifacts, not only direct package manifests or backend `npm audit` results.
- At implementation time, consult maintainer advisories and official package/platform records. Record applicability/reachability and the reviewed safe replacement; this plan does not prescribe an unverified “latest” version.
- Audit Git history, generated/mobile release artifacts, source maps, logs and build configuration for embedded credentials. Use redacted findings and location-only secret documentation. Any historical exposure requires a separately coordinated incident/rotation decision that preserves decryptability of existing data.

### Batch N-B: small compatible remediation

Upgrade one affected chain at a time with lockfile/provenance review and a rollbackable source change. Keep N01/N03 remedies in place. Cover parser/compressed-body boundaries and malformed/oversized requests for N02; cover provider URL/redirect/timeout/failure behavior and credential handling for N04. Real provider delivery remains a later acceptance check.

Build app/console Android/iOS and backend images against the reviewed locks. Retire a package only after consumer/native registration review. Do not apply bulk dependency or lint rewrites. Review shrinking/Room/plugin behavior before enabling minification; a smaller APK is not evidence of a working app.

Checkpoint: affected focused and whole suites pass, dependency/native build evidence is current, and any remaining advisory or unsupported platform is an explicit blocking/deferred finding with an owner.

## 6. Phase 4 — mobile implementation (M1–M10)

### Batch M-A: account, input and network boundaries (M3, M4, M5, M8)

Complete the route-class/consumer matrix for normal, guest, disabled/deleted, wrong-account/device, expired/revoked and oldest-supported clients. Cover sync/import IDs, ownership relationships, idempotency, malformed/oversized data and error handling. A temporary auth/provider outage must preserve offline data and pending queues.

Validate actual app endpoints, trust configuration, proxy/cleartext behavior and plugin/native networking in signed builds. Retain verified backend TLS and the existing mobile networking policy. Introduce certificate pinning only with an accepted rotation/outage recovery design. Fix a discovered backend contract defect in its owning batch; never weaken authorization to make a mobile test pass.

### Batch M-B: prove recoverability and privacy before storage conversion (M6, M9, M10)

Extend the existing password-free account recovery and native/tracked operation fences rather than replacing them. Verify complete schema/receipt/outbox coverage and the consent boundary, including snapshot size, account/global quotas and failure behavior.

**Existing OTP restores account access; it cannot recreate a receipt or unsent mutation that never left a lost phone.** Manual snapshots recover the snapshot point, not every later offline write. The user approved automatic updates after explicit recovery opt-in, with no extra password. The new source attempts updates while the app is active and online, at 15-minute intervals with backoff; copies remain bounded and new changes are protected only after successful verification. See the [recovery flow and scenarios](security-recovery-flow-2026-10-25.md). Before activation, accept that recovery point and verify the cadence against measured free-host quotas. Do not claim continuous recovery from a one-time snapshot or silently begin automatic uploads. If the approved recovery guarantee cannot be met, keep the affected storage transition off and report that gate.

Cover privacy for logs, caches, analytics, temporary data and deferred SMS. Cross-store retention/restore policy depends on I06; signed-off retention must preserve replay evidence and long-offline recovery.

### Batch M-C: native key custody and encrypted-engine prototype (M9, M10)

Evaluate a maintained encrypted SQLite implementation against the actual raw-sqlite3 schema, FFI/native builds, WAL/locking behavior, SQL features and supported Android/iOS versions. Prove encryption through engine capability checks, ordinary SQLite/wrong-key refusal and tested cryptographic behavior; a filename or `PRAGMA key` call alone is insufficient.

Use random local keys with explicit key/format versions and platform-backed custody appropriate to background operation. Separate local database/receipt keys from retained server phone/IMAP keys; do not derive encryption keys from email, phone number or JWTs. Existing secure-token storage does not itself prove hardware-backed database-key custody.

Handle key provisioning failure, temporary key unavailability, lock/unlock/reboot and permanent loss explicitly. The SMS/background path must remain safe while the phone is locked: no silent drop and no undocumented plaintext fallback. Before switching, failure leaves the existing database readable; afterward, failure preserves ciphertext and offers the tested account-bound recovery path rather than creating an empty database. No extra user password is introduced.

Checkpoint: prototype passes on isolated synthetic Android/iOS targets, packaging/provenance is reviewed, and recovery/key availability semantics are accepted before integrating it with normal startup.

### Batch M-D: resumable database conversion

Use explicit durable states such as preflight, copy, verify, switch and confirmed; names are a design to implement, not existing guarantees.

1. Check free disk space, key availability and recoverability; quiesce every inventoried writer, listener, response/file operation and background isolate. Refuse safely if work cannot drain.
2. Checkpoint WAL through SQLite APIs. Copy the complete database to a separate encrypted target with bounded batches and resumable state. Preserve all namespaces, IDs, pending queues, tombstones, cursors and projections.
3. Compare schema, every table's counts/digests, constraints and representative application queries. Flush data/state and switch atomically under the supported native filesystem semantics.
4. Reopen using the normal startup path and verify read/write/queued sync. Preserve the old readable state before the switch; after new writes, use a forward repair or export/replay path that also preserves those new writes.
5. Bound and reconcile rollback/temp/WAL copies only after confirmed successful launches and recovery. Never erase the sole good copy or treat a decrypt error as first install. Do not promise physical flash erasure.

### Batch M-E: receipts and interrupted file work

Encrypt receipts by copy, integrity verification and atomic metadata/path transition. Support add/view/delete/OCR/export/recovery without modifying source gallery files. Keep decrypted working files in bounded app-owned temporary storage with startup/expiry cleanup.

Extend the dedicated receipt intent journal and DB-aware reconciliation to the encrypted format. Address authenticated intent state, directory durability and native no-follow/path-safe file operations where required by the threat model. Preserve bytes on an uncertain commit, unknown reference, key failure or malformed journal. Never sweep ordinary attachments or unowned files. Test account changes and process termination at each file/DB boundary.

### Batch M-F: native packaging and complete acceptance (M7, M8 plus all mobile IDs)

Keep `android:allowBackup=false` and existing permission/account/guest behavior. Test actual release signing and upgrade compatibility, shrinking/resource/Room/plugin behavior, debug assets/configuration and documented tamper limits. Use an isolated test package first; do not overwrite an installed account-bearing app to establish the baseline.

A debug emulator harness is supplementary. Before activation, test supported real Android/iOS devices and the oldest supported client/platforms with production-equivalent signing/configuration. Include offline recovery, logout/account switch, foreground/background SMS, low disk, corruption, interrupted migration and missing/wrong/permanently lost keys. Release mobile storage separately from a PostgreSQL host move.

## 7. Phase 5 — required evidence and promotion rules

| Area | Required evidence before closure / activation |
| --- | --- |
| Data | Current protected clone, reviewed private ID maps, before/after financial/reference invariants, concurrent/interrupted/repeated migration, old-ID readers and target-role behavior |
| Indexes | Constraint dependencies, realistic before/after plans, approved remove/retain decision and recreation/failback procedure |
| Dependencies | Resolved inventories/locks/provenance, dated applicability decisions, artifact/history secret review and affected whole-suite/platform build results |
| Mobile boundaries | Current/oldest clients; cross-user/guest/device/revocation; broad input/relationship cases; real signed endpoint/TLS/permission behavior |
| Recovery and encryption | Complete DB/receipt/queue coverage; key loss/unavailability; background/locked-device behavior; interruption at every durable state; measured disk/time/quota; no extra password or silent upload |
| Deployment / hosting | Intended PostgreSQL actual-data upgrade and post-write failback, original keys, measured free-tier budgets, independent backup/journal/key custody and monitored operator acceptance |

Run focused regressions first, then the affected full API/auth/database/backup/deployment/app/console/domain suites and signed-device matrix. Record exact commands, source/configuration/lock hashes, package IDs, data scope, failures and skips. Use existing test runners and extend fixtures for missing behaviors; an earlier passing total is not proof for a changed candidate.

Stop promotion on unexplained data differences, missed pending work, incompatible clients, uncertain key recovery, unsafe grants, unsupported dependencies or absent acceptance. A reviewed decision to retain a row/index/legacy consumer is preferable to unproved deletion. Production application and provider sends remain separate actions after a concrete candidate and necessary authorization exist.

## 8. Phase 6 — documentation implementation (W01–W03, W05–W07)

Documentation work starts during inventory and is updated with every batch; it is finalized after the relevant evidence exists.

| Finding | Planned change | Closure evidence |
| --- | --- | --- |
| W01 | Maintain one current split-service/data/recovery overview and an index that marks older consolidated plans and schema explorers as historical. | Current readers can identify the authoritative architecture, source revision and remaining gates without interpreting old designs as deployed state. |
| W02 | Describe actual phone/IMAP/envelope formats, blind indexes, key versions, retained-key requirements, backfill/reader/rollback order and PostgreSQL provider portability. | Documentation matches implemented formats and verified migration evidence; no unimplemented encryption or rotated-key claims. Broader I01 work remains a dependency. |
| W03 | Reconcile catalogue publication/RLS statements and stale incident comments against actual projections and intended-role behavior. | Target-role/publication acceptance and accurate current explanations; documentation alone cannot certify database policy. |
| W05 | Inventory obsolete farm/domain/signup labels and their consumers; correct active explanations and archive historical context without unexplained deletion. | Consumer review, compatible active wording and linked history. Broader I14 cleanup is retained where source retirement is required. |
| W06 | Align configured sender identity, templates and operator instructions; verify the real sender domain/provider and email display through an authorized acceptance run. | Actual sender/provider evidence. Existing PandaPay OTP template fixes remain; no new sender credential is generated by planning. |
| W07 | Publish source/local-test/device/provider/deployed evidence separately, including the five-second revocation bound, logging/retention limits and feature defaults. | Claims have a source/evidence/date; MD and generated HTML agree and no historical count is presented as a fresh result. |

Update the audit MD/HTML, remaining-work MD/HTML, completion checklist, deployment/rehosting/recovery guides, location-only secrets index, app/console/auth READMEs and portable-backup status where their current statements overlap. Preserve dated test records; add a current-status note rather than silently rewriting history. The passphrase portable archive is separate from the approved password-free recovery flow.

## 9. Finding coverage and external dependencies

| Findings | Primary phase(s) | Dependency that remains explicit |
| --- | --- | --- |
| D01, D02, D05 | 2 | Current clone, approved mappings, I04; actual-data G03 |
| D03, D04 | 2 | Query/constraint evidence, I05; target G03 |
| N02, N04 | 3, 5 | Current maintainer review, affected regressions; provider/deployed-tree G02/G05 |
| M1, M2 | 1, 3, 5 | Full native/history/artifact inventory and signing/dependency acceptance G01/G05 |
| M3, M4, M5 | 4, 5 | Broad backend role/abuse/admin/input contracts; I03/I09/I10 where needed; G01/G02/G05 |
| M6 | 4, 5 | Cross-store retention I06 and approved ongoing recovery/consent; G04/G06 |
| M7, M8 | 3, 4, 5 | Actual release packaging/signing/native/device/runtime-role acceptance G01/G05/G06 |
| M9, M10 | 4, 5 | I02; retained/server key-format work I01 where applicable; complete recovery and G01/G04 |
| W01, W02, W03, W05, W06, W07 | 6 | Actual source/provider/role/operational evidence; I01/I14 and G02/G03/G06 as applicable |

A scoped finding is not marked closed while one of its required broader dependencies remains unproved. This plan does not independently implement all other packages in the 14-package backlog.

## 10. Execution backlog and ownership

These are subdivisions of the existing packages, not 12 new projects or finding closures. `Planned` means the next execution slice has not been performed by this documentation update.

| Batch | Deliverable | Findings | Depends on | Owner |
| --- | --- | --- | --- | --- |
| P00 | Freeze candidate and route/writer/support inventories | M1, M2, W07 | Existing dated evidence | Coordinator |
| P01 | Historical reconciliation and exact-clone D05 rehearsal | D01, D02, D05, W02, W03 | P00 | Data |
| P02 | Measured index retain/remove decisions | D03, D04 | P00; same protected clone as P01 | Data |
| P03 | Full secret/native dependency review and engine selection | N02, M1, M2, M7 | P00 | Dependencies/build |
| P04 | Route, capability, payload and relationship boundaries | N02, M3, M4 | P00 | Backend |
| P05 | Retained server keyring/readers and bounded backfill | M10, W02 | P00 | Backend/key owner |
| P06 | Complete recovery, consent and privacy/retention contract | M6, M10, W07 | P04, P05 | Recovery |
| P07 | Authenticated startup and encrypted database switch | M9, M10 | P03, P06 | Mobile storage |
| P08 | Integrated encrypted receipt lifecycle | M6, M9, M10 | P06, P07 | Mobile receipts |
| P09 | Signed mobile upgrade/TLS/native failure acceptance | M1–M10 | P03–P08 | Build/device and independent reviewer |
| P10 | Provider, PostgreSQL, runtime-role and custody acceptance | D01–D05, N04, M5, M6, M8, M10, W03, W06, W07 | P01–P06 for candidate acceptance; preparation can start earlier | Coordinator/operations |
| P11 | Active documentation and per-finding closure | W02, W03, W05, W06, W07 | Continuous; final review follows relevant P09/P10 evidence | Coordinator |

Use at most three disjoint implementers alongside the coordinator: data; dependency/build; mobile/recovery. Queue backend/key changes when their files are free. The coordinator owns shared entrypoints, integration, evidence and documentation. Assign file ownership first; never concurrently edit API/auth entrypoints, providers, app startup or AppDatabase. Independently review P07/P08 before normal startup integration. Dependent mutations remain sequential even when inventories run in parallel.

### P00 — baseline and acceptance matrix

**Files/tools:** existing release inventory/check scripts, current evidence/claim register, app/console release configuration. Capture source/configuration/lock hashes, migration checksums, original edit hashes and current flags. Inventory all DB/file writers/readers and route/entity families. Establish the actual supported Android/iOS versions and current/oldest released clients from release evidence; unknown inputs remain explicit rather than guessed.

**Deliverable/exit:** immutable candidate manifest, support matrix, route/writer ownership inventory and all 22 findings mapped to code, local, actual-data, signed-device and provider evidence. Record external prerequisites and owners. Preserve unrelated notification edits; no activation.

### P01 — history and exact-clone data rehearsal

**Files/tools:** `db/scripts/rehearse_local_backup.py`, `review_data_cleanup.js`, `product_migrate.js`, catalogue identity migration/fixture. Restore a complete fresh encrypted product/auth pair with original keys into protected local storage. Inspect schema, owners/ACLs, extensions and the complete pending history **before invoking the migration runner**: a pending historical dedupe can still mutate data, despite the new additive D05 migration.

Run broad and new v1 identity checks separately. Reconstruct old cap/benefit IDs, state and usage from available pre-dedupe backups, import artifacts and transaction/history evidence; include JSON/offline consumers. Zero current duplicates does not prove that the earlier merge preserved consumption. If historical evidence is unavailable, preserve current data, keep reconciliation unresolved and continue independent work. Never fabricate a mapping or blindly sum state.

Where repair is needed, add compatible old-ID readers first, then a private reviewed mapping/lossless original archive, schema-bound dry run, bounded transactional apply receipt, repeat/interruption behavior and post-write repair/replay. If no current repair is needed, record that separately from historical uncertainty.

**Tests/exit:** complete exact-candidate clone rehearsal; IDs, amounts, cap consumption, entitlements, lounge usage and FK/non-FK references reconcile; imports/admin conflicts/old-client IDs work; concurrent/interrupted/repeated runs and full dump/restore preserve data and key decryptability. No live merge or schema application.

### P02 — index decisions

**Files/tools:** `reviewed_index_reconciliation.js` and its PostgreSQL fixture. Inspect exact change_log/partner-click definitions, dependencies and backing uniqueness. Measure realistic sync/callback/read/write plans and timings on the clone. Mutating measurements use disposable or rolled-back work.

**Tests/exit:** explicit retain/remove decision, unchanged uniqueness/RLS/callback behavior, comparable plans and an exact recreation/rollback receipt. Retain an index when removal has no demonstrated benefit. Rehearse lock/time bounds and repeats; concurrent DDL, if needed, uses a separate reviewed nontransactional job. Target acceptance follows P10.

### P03 — dependency, history and artifact completion

**Files/tools:** release inventory/secret/license reviewers, lockfiles, platform build files and dependency applicability record. Expand the 40-commit sample to retained history/refs; inspect generated assets/source maps and exact APK/AAB/IPA native/Dex contents. Classify flags privately and emit no secret values. Confirmed exposure needs coordinated containment/rotation that preserves decryptability, never replacement of the sole retained key.

Compare dev/staging/production Android graphs, Pods/Swift, Dart/vendor/FFI and backend trees with actual shipped artifacts. Resolve missing license/provenance and support/applicability decisions. Verify official maintainer advisories during execution; upgrade one affected chain at a time. Choose the encrypted engine only after actual Flutter/Dart/native compatibility and license checks; prototype versions are not automatically release choices.

**Tests/exit:** reviewed full-scope inventory/decisions, deterministic candidate builds and affected parser/provider/Room/OCR/native regressions. Reproduce shrinking failure before changing policy; retaining compatible disabled shrinking is an explicit decision. Exact signed artifacts are accepted in P09.

### P04 — access and payload contracts

**Files/tools:** API/auth request boundaries, owning routes, session/capability modules and sync/import clients. Map each route/entity to allowed identities, capabilities, field types, sizes and relationship owners. Cover anonymous/guest/normal/narrow admin, wrong account/device, expired/revoked, disabled/deleted and oldest-client behavior.

Finish allowlists, numeric/batch bounds, idempotency, compressed/oversized JSON and mixed-validity transaction semantics. Any required durable multi-instance admission or narrower admin implementation belongs to I09/I10; M3 remains partial until required controls exist.

**Tests/exit:** machine-readable route/entity matrix plus cross-account/guest/admin/replay/outage cases. Invalid batches cannot partially commit financial changes; safe errors expose no sensitive input; auth/provider outage preserves offline queues. Run affected API/auth/database and client regressions.

Implement one route/entity family per reviewable change, keeping its existing successful request/response contract. Shared authorization or parser changes receive the complete affected matrix before the next family starts.

### P05 — retained server keys and format evolution

**Files/tools:** auth phone/lookup encryption, API IMAP/recovery wrapping readers/writers, owning key modules, bounded migration tooling and private key inventory. Prove original keys decrypt existing data before introducing version/key IDs. Deploy compatible legacy/new readers before changing writes. Keep local install/receipt keys independent and random; never derive them from email/phone/JWT.

Add resumable bounded backfill with compare-and-swap protection, checkpoints and aggregate verification. Rehearse mixed formats, write-key selection, interrupted rotation, concurrent updates and old-backup restore. Retain old decrypt/lookup keys for the data/backup recovery lifetime. Preserve deleted-contact reuse and approved phone ownership with mixed-generation lookup uniqueness.

**Tests/exit:** legacy/current, malformed/tampered/wrong/missing/unknown-key cases and backfill/repair pass without blank replacements. W02 documents actual formats and limits. Intended-provider key custody/portability follows P10.

Split this into retained-reader support, disabled new-write selection, then separately rehearsed backfill/rotation. Do not enable new formats before every required deployed reader can handle them.

### P06 — complete recovery and privacy

**Files/tools:** account recovery coordinator/repository/scheduler, API consent/snapshot routes, lifecycle tombstones and retention modules. Inventory every required table, unsent queue, deferred SMS item and receipt byte; prove a fresh-install restore after existing OTP. No new password or required recovery-key-file step.

Test opt-in/out, account/device switch, consent-disable/upload races, revoked devices, retries, offline creation and last-verified-copy reporting. Preserve current quotas/cadence until measured. If a complete snapshot exceeds the current 5 MiB/two-copy policy, implement/test a compatible bounded chunk/manifest design within measured free-host budgets, or keep the affected transition off. Never omit receipts/queues to make a copy fit.

Complete I06 retention across device/server/logs/analytics/caches/temp/backups while preserving replay evidence and long-offline work. Restore applies the latest retained deletion/tombstone state. Define guest/opt-out conversion eligibility explicitly; do not force recovery consent or silently upload data.

**Tests/exit:** fresh-phone DB/receipt/queue parity, key-unavailable/loss and consent/deletion races, quota/backoff/outage and sensitive-marker cleanup/log checks. Measure snapshot size/runtime and accept the recovery point before P07 eligibility.

### P07 — normal encrypted startup and switch

**Files/tools:** AppDatabase, startup/providers, native writer admission, encrypted-copy/key/journal modules. Add an authenticated versioned source/target manifest and one admission path shared by foreground/background isolates. Check trusted private paths, disk, key and recovery eligibility; drain/close all writers and hold cross-isolate exclusion through conversion and switch.

Copy/verify every schema/table/value/ID/namespace/outbox/tombstone/cursor, checkpoint WAL via SQLite, flush durable state and switch using verified platform semantics. Reopen through normal startup and prove reads/writes/sync before confirmation/cleanup. Before switch, failure preserves the readable original. After new encrypted writes, use forward repair/export/replay; never reopen a stale plaintext copy. Wrong/missing keys or journal corruption preserve evidence and enter recovery rather than creating a blank DB.

**Tests/exit:** termination at every durable state, competing startup/writers, SMS/background/reboot/locked-store, low disk, cancellation, corruption, later launches and post-switch writes. Prove native directory durability/path safety; Dart path checks alone are insufficient. Activation stays off through P08/P09 and relevant gates.

Deliver four independently reviewed slices: manifest/startup admission; complete writer drain/exclusion; normal-path copy/switch/reopen; confirmation/cleanup/forward repair. Keep the transition disabled between slices. A partial slice must not become the normal app startup path.

### P08 — receipts through every consumer

**Files/tools:** attachment repository, receipt codec/custody, OCR/private workspaces, export/recovery/restore and receipt journals. Add dual legacy/encrypted readers before new encrypted writes. Wire add/view/delete/OCR/import/gallery/export/recovery together; keep the existing passphrase portable archive separate from password-free recovery.

Use verified copy and authenticated account/attachment/key binding, journaled file/DB metadata transitions and bounded private plaintext workspaces. Preserve gallery originals and IDs. Unknown references, uncertain commits, malformed state and unavailable keys preserve bytes. Never sweep ordinary or unowned attachments.

**Tests/exit:** all consumer paths, guest/account/logout transitions, corrupted/oversized/truncated files, key failure and termination at every file/DB boundary. Export/restore yields identical receipt bytes; DB and receipt flows pass together before P09.

Deliver compatible dual readers first, journaled writers second, then all OCR/export/recovery consumers and reconciliation. New encrypted writes remain disabled until the complete consumer set passes.

### P09 — signed-device and native acceptance

**Files/tools:** actual Android/iOS release configuration, manifests/entitlements, signed packages and integration/native tests. Begin with an isolated package; use dedicated installations for signed account-bearing upgrade tests. Inspect permissions, exported components, backup settings, origins, TLS/cleartext/invalid certificates and native networking. Pinning requires an accepted rotation/outage design.

Reproduce Room/R8/OCR/import behavior and fix or explicitly retain compatible build policy. Exercise supported devices/OS/current and oldest clients, foreground/background SMS, guest/account switching, offline work, key loss, reboot, low disk, corruption and termination. Check exact shipped secrets/dependencies/debug configuration.

**Tests/exit:** hashes/signing/configuration, supported release matrix, static analysis, full affected app/console/domain suites and integrated native failures. Debug fixture results supplement this evidence. Mobile encryption and PostgreSQL rehosting use separate release windows.

After a format switch, an old binary must not mistake encrypted data for a fresh install. Test the supported upgrade path and define safe refusal/export/recovery for unsupported downgrades; do not promise binary rollback after new-format writes without compatible readers.

### P10 — external target and operational acceptance

**Files/tools:** PostgreSQL backup/restore/migration/role tooling, provider transports, deployment/proxy config and operational runbooks. Rehearse complete product/auth data, sequences, constraints/functions/extensions, ledger and original keys on the intended PostgreSQL provider/major. Review provider-owned objects and role/owner/ACL mappings rather than copying privileged roles blindly. Verify views/RLS/capabilities under actual non-owner runtime roles.

Rehearse post-cutover writes and failback/replay that preserves them. Verify configured email/SMS/Google and applicable providers through authorized test recipients/accounts, including safe transport failures, quotas and exact deployed dependency trees. Accept W06 sender/domain authentication, rendering, links/replies; branding alone is insufficient.

Verify two off-host encrypted copies in separate failure domains, separate private recovery-key custody and retained lifecycle checkpoints; one Mac is one location. Missing destinations remain external gates, not invented infrastructure or a paid service. Measure free-host connections/disk/memory/growth and accept cleanup/schedulers/independent alerts before activation.

**Tests/exit:** actual-data/provider preservation and client/load acceptance; effective runtime roles; independent restore/tombstone reconciliation; measured budgets and monitored staged rollout/failback evidence. Follow existing action authorization; planning performs no provider sends, live DDL, push or deployment.

### P11 — documentation and individual closure

Update the claim register, MD/HTML, progress/checklist, recovery/rehosting/deployment docs, relevant READMEs and location-only secrets index during every batch. W02 follows real formats/backfill/uniqueness; W03 follows target policy; W05 corrects active obsolete labels after consumer review and preserves/version-controls external contracts; W06 follows provider evidence; W07 states observed logging/retention/revocation/operating limits. Maintain W01 without reopening it as an unfinished finding.

**Tests/exit:** each of the 22 findings has its own source/config hashes, commands/results/skips and applicable actual-data/device/provider receipt, or an explicit remaining gate. JSON/MD/generated HTML agree. Preserve dated results; wording changes cannot close missing behavior.

## 11. First execution slice and promotion rules

1. Complete P00 and start P01/P02 on the protected current clone, inspecting pending history before migration. Produce private data/index decisions first.
2. In parallel, complete P03 inventories and P04 synthetic boundary matrix. Queue P05 in a separate file-owned backend batch.
3. Accept P06 recovery/retention before P07 normal startup; integrate P08 receipts before P09 signed full-app acceptance. Keep flags off during source preparation.
4. Complete relevant P10 actual-data/provider/custody evidence and P11 per-finding closure; publish remaining gates after every accepted batch.

For each code batch, run meaningful focused checks and then the affected full suites. Record candidate/config/lock hashes, exact commands/results, skips and scope. Do not repeat unaffected application suites for this documentation-only plan edit. Do not promise a completion date before clone size, native compatibility and external prerequisites are measured.

Stop promotion on unexplained financial/row/reference differences, unsafe privileges, incompatible clients, uncertain key recovery or absent required evidence. Preserve a verified original before a mutation; after new writes preserve/replay them instead of reverting to stale files/dumps. Continue independent source work while an external gate is pending. G01–G06 remain the release gates: signed mobile; providers/clients; actual-data PostgreSQL; independent custody; release security/contracts; monitored activation.

Planning does not change the **22 unfinished / 19 partial / three open** counts or enable any feature. [Machine-readable batches](../artifacts/security-review-2026-10-20/data-dependency-mobile-documentation-plan-2026-10-25.json) · [Gap review](security-focused-gap-review-2026-10-25.md) · [Current architecture](security-current-architecture-2026-10-25.md) · [Recovery scenarios](security-recovery-flow-2026-10-25.md).

## 12. Current execution checkpoint

The [first execution record](security-execution-implementation-2026-10-25.md) starts P00/P01/P03/P04/P11 in bounded slices. Transaction split/tag validation and retained-text-history traversal progressed, and the protected current restore now completes both v1 catalogue checks with zero collisions. Historical data reconciliation, the full actual-data upgrade, measured index decisions, broad route/role contracts, flagged-secret/native review and mobile integration/acceptance remain. No entire batch or finding is newly closed; all 22 findings remain unfinished.

The [mobile inventory](../artifacts/security-execution-2026-10-25/mobile-writer-support-inventory.json) highlights plaintext deferred SMS and the existing signed-out/user/session namespaces. P07/P08 must preserve those namespaces and implement a tested mapping to custody's draft account/guest model before normal integration. Checked-in OS minimums do not establish the oldest released client or installed support matrix.

## 13. Retained-reader checkpoint

The [P05 reader-first batch](security-key-readers-implementation-2026-10-25.md) adds optional versioned phone readers, retained recovery unwrap keys and registered nonsecret release metadata. Existing legacy writes, original keys, lookup/IMAP formats and feature defaults remain unchanged. Mixed-generation recovery snapshots pass a synthetic PostgreSQL dump/restore, and the protected original-key restore still verifies. P05 remains partial pending complete format/reader coverage, bounded backfill/rotation, actual retained custody and target acceptance. No additional finding is closed.

## 14. Next slice — sync, recovery and review evidence

After the retained-reader batch, three independent slices were implemented and locally checked; their whole packages remain in progress. See [implementation and exact evidence](security-sync-recovery-implementation-2026-10-25.md).

| Slice | Owning files | Intended change | Required proof |
| --- | --- | --- | --- |
| P04 sync transport | New API validation helper/tests; coordinator wires existing routes | Validate device/cursor/ack inputs before SQL while keeping registration fallback, response contracts and per-item push savepoints | Current Dart caller compatibility, malformed/no-SQL cases, numeric bounds and real sync SQL fixtures |
| P06 snapshot scope validation | Recovery local snapshot and focused Dart tests only | Audit account/receipt/queue metadata and fix demonstrated malformed/incomplete snapshot handling; preserve existing valid v1 archives and never silently omit required data | Synthetic round-trip, account isolation, missing/inconsistent metadata, failure preservation and relevant app suite |
| P03 history provenance | Secret-audit tool/tests only | Add bounded opt-in commit/blob references for historical flags so private classification can distinguish file versions without emitting values | Default compatibility, branches/renames/deletions, same-path different versions, output limits and secret redaction |

Keep original keys, current encryption writers, UUID/history, existing OTP/no-password recovery, guest/account data and disabled feature defaults. Do not change sync conflict ordering, add a new cipher writer, perform a data merge or activate storage in these slices. The coordinator owns API entrypoints, integration and generated docs; Luna agents work in disjoint files. Full format/backfill work, actual-data/index reconciliation, native dependencies and device/provider/custody gates remain separate.

## 15. Remaining work after the sync/recovery slice

**Later checkpoint:** the source preparation for typed sync and coverage manifests below progressed in section 16. Its default-off/local results do not close the required actual-data, concurrency, client, provider or fresh-phone acceptance. Section 16 records the current next steps.

The count remains **22 unfinished findings (19 partial, three open)**. P03/P04/P06/P11 progressed; no package or finding is promoted to complete by these source/local tests.

| Next bounded slice | Deliverable before integration | Proof and preservation condition |
| --- | --- | --- |
| P06 recovery coverage manifest | Inventory producer tables/queues/receipt bytes and define a versioned authenticated coverage manifest with compatible v1 readers | Restore valid old copies into newer schemas; reject missing required producer data before writes; complete receipt/queue parity and interruption/race checks. No extra password or silent upload. |
| P04 typed-field/financial contract | Reproduce the confirmed `42804` numeric update rejection; design typed-column assignments and shared financial-state/split/reward handling in a new migration and owning route | Test numeric/UUID/boolean/date/enum fields, exact before/after financial state, duplicate/retry/clocks and per-item rollback under the real role. Do not enable previously rejected financial writes with a cast-only fix. Preserve historical migration checksums. |
| P04 next route family | Record caller formats, owning identities, field/size bounds and existing partial/atomic semantics before changing validation | Current client, cross-account, malformed, replay and outage cases. Preserve successful responses and financial transaction boundaries. |
| P03 historical classification | Use bounded observed commit/blob references to classify flags privately; compare excluded/native artifacts and release dependency inventories | No raw values in public evidence; report incomplete coverage explicitly. Coordinate any confirmed exposure response while retaining old-key decryptability. |
| P01/P02 protected data/index review | Reconstruct historical IDs/state; compare exact index definitions and representative plans on the restored clone | Explicit retain/remove or reconciliation decision, full references and rollback/replay evidence. Never infer safe deletion from empty tables or current zero duplicates. |

These can be prepared in disjoint files. The coordinator integrates one bounded change at a time. P07/P08 normal encrypted startup/receipt integration depends on demonstrated recovery coverage and full writer admission; signed-device and external target/custody gates still precede activation.

## 16. Typed sync and recovery coverage checkpoint

The [typed-sync/recovery implementation](security-sync-financial-recovery-implementation-2026-10-25.md) advances P04/P06/P11. V2 now has typed, locked and profile/device-bound writes; the API reconciles accepted transaction edits through the existing financial core inside the item savepoint. Generic transaction status/delete writes are refused. The source flag stays false, and enabling requires an exact-candidate acceptance proof. The existing numeric failure remains on the default legacy path until controlled activation.

New recovery snapshots include a compatible authenticated coverage manifest with independent schema/row-count checks and pre-write receipt validation. Old v1 archives remain readable; this is not yet fresh-phone acceptance or normal encrypted startup.

**Next:** protected actual-data and PostgreSQL17/provider rehearsal; same/different-transaction concurrency, cap/period/retry/rule-change and client parity; then recovery consent/deletion races, complete new-phone receipts/queues and measured copy limits. Finish encrypted normal startup/writer/receipt integration afterward. Historical data/index decisions, exact release artifacts and independent custody remain. All 22 scoped findings remain unfinished; no activation or deployment.
