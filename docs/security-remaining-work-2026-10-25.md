# Remaining security work — 25 October 2026

## Production launch priorities — do these first

**Target confirmed by the owner: 100,000 completed signups across the first day. Unrestricted launch is not accepted.** This priority order overlays the existing packages and gates below; it adds no vulnerability/completion counts. The current review includes read-only Supabase catalogues/advisors, not a load test or deployment acceptance.

| Rank | Requirement | Exit evidence and owner |
| --- | --- | --- |
| 1 / LP01 | **Prove deployed identity and database isolation** | Security/backend owner: anonymous, guest, wrong account/device, revoked/deleted and narrow-admin tests pass on the actual target; no privileged backend credentials reach clients. |
| 2 / LP02 | **Independent recovery and acceptable data loss** | Operations/data owner: a timed loss-of-primary drill meets the agreed recovery point/time and preserves accounts, deletions, financial state and keys. Do not replace the existing bounded Mac schedule without a measured storage plan. |
| 3 / LP03 | **Fund and measure hosting, connections and storage** | Infrastructure/database owner: a signed resource budget covers app/auth/workers, provider reserves, database/TOAST/WAL/temp/logs/backup/object growth and burst load; actual measured capacity supports the admitted launch. |
| 4 / LP04 | **Quota-approved OTP delivery and abuse/spend limits** | Auth/delivery owner: target valid signups complete within the OTP lifetime under the approved burst; rejects, bounces, resend costs and blocked legitimate users are measured, with no public test-code bypass. |
| 5 / LP05 | **Financial correctness, sync and complete-data migrations** | Backend/data owner: balances/projections/history reconcile before and after migration, replay, retries, crashes and concurrency; rejected work remains recoverable. Same-major synthetic tests alone do not close this gate. |
| 6 / LP06 | **Bound onboarding fan-out and durable background work** | Backend/worker owner: interruptions, replay and overload neither lose accepted work nor duplicate financial effects; backlog drain time is measured and sign-in stays usable. |
| 7 / LP07 | **Signed mobile/client and supply-chain acceptance** | Mobile/security owner: the actual supported signed releases pass their data-protection and crash/upgrade matrix, with accurate privacy/recovery claims and no new customer password. |
| 8 / LP08 | **Measured load, progressive admission and incident response** | Operations/performance owner: the agreed arrival/burst envelope meets recorded targets, including failure mode; offered/admitted/rejected/completed counts are visible and the operator receives test alerts. |
| 9 / LP09 | **Privacy, platform and business-policy readiness** | Privacy/product/store owner: launch-date legal/platform applicability and notices are accepted, required permissions are approved and users have a tested manual/permission-denied path. |
| 10 / LP10 | **Exact release, migration and edge rollback rehearsal** | Release owner: the exact source/config/schema/lock/artifact hashes and signed acceptance record pass the release gate, with a rehearsed operator recovery procedure. |

The live read-only review found a 60-connection cluster, nine retained restore-drill databases totaling 211.06 MiB and database advisories requiring classification. Source recovery has a 50 MiB global ciphertext quota and V2 typed sync remains unaccepted for activation. Resolve these with capacity/recovery budgets and actual-target tests before marketing; do not blindly delete data or lift quotas. [Full analysis, traffic/storage arithmetic, platform requirements and test plan](security-and-backend-audit-2026-10-20.html#production-launch-priorities).


**14 implementation work packages remain, followed by 6 validation/rollout gates.** These are grouped work packages, not a count of files or individual bugs. Some packages build on substantial existing source. Several findings share a package, and some require only acceptance of code that already exists.

Across the complete report: **76 tracked findings = 26 implemented in source + 43 partial + 7 open**. That is the original 68 findings plus eight additional system-design findings. **50 findings are not fully closed.** “Implemented in source” does not mean deployed or accepted in production; this is not a security-completion percentage.

The earlier six-row “what remains” table grouped broad themes. It was not a count of six code changes. This numbered register is the current remaining-work count and supersedes that interpretation. Completed six-digit contact replacement, bounded receipt reconciliation and the optional operator webhook adapter are recorded in the [25 October implementation record](security-next-implementation-2026-10-25.md) and [local evidence](../artifacts/security-followup-2026-10-25/batch-verification.json).

**Latest implementation:** the [LP03 connection-budget safeguard](security-connection-budget-implementation-2026-10-25.md) now calculates per-cluster pools, replica ceilings, rollout overlap and reserves, and blocks the strict release check without fresh bound acceptance. 209 local tool tests passed, including 42 focused checks; scopes overlap. Actual hosting/performance/custody acceptance remains open, application runtime/live data are unchanged, and no package or finding is newly closed. [Verification](../artifacts/security-connection-budget-2026-10-25/verification.json).

**Next batch implemented locally:** the [OTP work/provider admission batch](security-otp-admission-implementation-2026-10-25.md) adds bounded concurrency, shared dummy-hash initialization and safe retry/cleanup behavior across legacy/V2 flows. 340 auth, 211 tool and 22 deployment tests passed, plus synthetic PostgreSQL OTP/abuse regressions. [Next-batch plan](security-next-launch-batches-2026-10-25.md) · [Scoped evidence](../artifacts/security-otp-admission-2026-10-25/verification.json). Production role/isolation, independent custody and provider/load acceptance remain open; no package/finding count changes.

**Latest database slice:** [sync isolation and protected review](security-sync-isolation-implementation-2026-10-25.md) guard seven legacy routines and recover a missing applied migration without changing its original bytes. Local API/auth/tool/Python and synthetic migration/restore checks passed. The saved database's strict role reports and historical baseline still need resolution before actual-data upgrade/rollout; B02 is partial and B03 remains unaccepted. No finding count or live change. [Evidence](../artifacts/security-sync-isolation-2026-10-25/verification.json).

## Remaining implementation packages — 14

| Package | Remaining implementation | Completion criterion | Related findings |
| --- | --- | --- | --- |
| I01 — Versioned server encryption | Finish the encryption/keyring bridge for approved phone/email/profile/raw-payload copies and IMAP secrets: parallel storage, transactional writes, bounded backfill, verified reads and retained original keys. | Complete the P2 format transition and a different-host restore without plaintext downgrade, changed IDs or lost old-key readability. | M6, M10, W02 |
| I02 — Encrypted device database and receipts | Finish native key custody, resumable SQLite/receipt conversion, the complete writer inventory and remaining crash/power-loss repair. Existing account recovery and receipt reconciliation are foundations; live encryption remains off. | Fresh/upgrade/offline/account-switch/key-loss/interruption/low-disk behavior preserves pending data and receipts, without a new password. | M9, M10, M6 |
| I03 — Remaining database privilege repair | Extend reviewed repairs for remaining PUBLIC/default/inherited grants, ownership/RLS and unsafe definer paths; audit the actual restored role matrix. The narrow exact-grant tool already exists. | Strict actual-role reports pass while ordinary application and worker requests retain required access. | S17, A03 |
| I04 — Business-aware data reconciliation | Reconcile historical cap/benefit IDs and state, then rehearse the new additive normalized uniqueness on the current clone; review every collision before activation. | Before/after IDs, counts, amounts, cap usage, benefit usage and foreign keys reconcile; non-equivalent rows are retained. | D01, D02, D05 |
| I05 — Index reconciliation | Compare the overlapping indexes and query plans, then apply only reviewed remove/retain decisions. Keep backing uniqueness constraints. | Constraint coverage and representative query performance are preserved on the reviewed target. | D03, D04 |
| I06 — Cross-store retention and lifecycle privacy | Finish the approved OTP/refresh/audit/raw-import/cursor/attachment retention categories and missing bounded jobs. Existing deletion ledgers and selected retention jobs stay intact. | Replay detection, long-offline recovery, financial history and restore tombstones survive bounded cleanup. | A01, A08, C03, M6, S08, S16 |
| I07 — Durable customer notification delivery | Add a transactional pending-delivery outbox for important inbox/business notifications, with bounded claims, retries and terminal failure handling. Existing reward/referral outboxes and the new operator adapter do not close this gap. | A crash after commit or an uncertain provider response cannot silently lose a required delivery or duplicate its financial effect. | SD01 |
| I08 — Clock-independent offline conflicts | Replace authoritative phone-wall-clock ordering with reviewed server revisions or logical ordering while preserving losing values and conflict visibility. | Wrong device dates, concurrent edits, edit/delete races and long-offline re-entry reconcile without lost mutations. | SD02 |
| I09 — Remaining shared abuse controls | Complete durable multi-instance admission for general/user/admin route classes; hosted OTP/enumeration/replacement quotas already use PostgreSQL. | Two instances, restart, exhaustion and store outage cannot accidentally permit unlimited sensitive requests. | SD03, M3 |
| I10 — Operation-specific administrator permissions | Define and enforce narrower reviewer/publisher/support/export powers, recent-factor requirements and separation for high-impact actions. | Unprivileged or narrower operators cannot self-approve, escalate or invoke unrelated high-impact actions. | SD08, M3 |
| I11 — Reliability metrics and independent monitoring | Add privacy-preserving trends, service objectives, backlog/cleanup/backup-age thresholds and missing-run detection. The optional notice webhook adapter already exists. | Injected outages, stale backups and stopped jobs produce useful signals accepted by an accountable operator. | SD04, A08, W07 |
| I12 — Large-import continuation and provider backpressure | Finish durable large-work continuation, per-account/provider concurrency and quota handling, with fair admission across pools. Existing selected IMAP/SMTP/export bounds remain. | Slow or throttled integrations and burst backlogs do not starve sign-in or small financial writes. | SD07 |
| I13 — Historical financial reproducibility | Complete ruleset/parser/calculation versioning and auditable reconciliation for historical estimates and recalculations; shared Dart/Node parity fixtures already exist. | Edits, refunds, period changes and replay explain the original result and any revised result without silently rewriting history. | SD06, A07 |
| I14 — Compatibility, configuration and reviewed cleanup | Complete API/feature/version configuration consolidation, route-preserving domain extraction, reviewed legacy consumer/package/repository retirement and matching documentation. Six-digit clients and retirement switches already exist. | Supported clients retain contracts; legacy storage/code is retired only after consumer and recovery evidence, or retained with an explicit reviewed decision. | C01, C02, C04, C05, C06, C07, W01, W02, W05, SD05 |

## Validation and rollout gates — 6

These require actual data, devices, providers, hosting or operator evidence. They are tracked separately from new implementation. Work may proceed in parallel where dependencies allow; applicable gates must pass before the affected feature is enabled.

| Gate | Remaining validation / rollout work | Related findings |
| --- | --- | --- |
| G01 — Signed mobile and native acceptance | Validate the actual Android/iOS release packages, signing/upgrade compatibility, hardware-backed key behavior, TLS, permissions, shrinking/Room paths and full device-loss/crash matrix. Three isolated Android component checks have passed. | A09, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10 |
| G02 — Providers, browser and supported clients | Verify real email/SMS/Google and optional integrations, browser cookies/CSRF/CSP/proxy/operator flows, current/oldest supported clients, and the monitored legacy-route retirement window. | S09, S13, S15, S18, C01, C04, N04, W03, W06, W07, SD03, SD05, SD08 |
| G03 — Actual-data PostgreSQL migration and failback | Run this exact candidate on a complete current restored copy and intended PostgreSQL provider. Apply reviewed contact/role/data changes, preserve all original keys and IDs, then prove cutover and post-write failback/replay. | S17, S18, A03, A04, D01, D02, D03, D04, D05, W02, SD05, SD06 |
| G04 — Independent backup and journal custody | Provision and verify two off-host encrypted recovery copies in separate failure domains, an independently retained latest lifecycle checkpoint and separate recovery-key custody. One Mac and its shortcut count as one location. | A01, A02, M6, M10 |
| G05 — Release security, contract and load evidence | Finish full history/native artifact secret review, Dart/native dependency checks, broader payload/relationship tests, historical financial parity, actual deployed-tree verification and representative failure/load runs. | A07, N02, N04, M1, M2, M3, M4, M5, M7, SD05, SD06, SD07 |
| G06 — Monitored operations and controlled rollout | Approve retention policies and measured free-host quotas, replace old cron in a fenced activation, configure scheduler/independent monitor/receiver and accepted alert routing, then freeze evidence and perform the separately approved rollout/failback procedure. | S08, S16, A01, A02, A08, C03, M6, M8, W01, W03, W07, SD04, SD07 |

Latest completed local work and outstanding acceptance are recorded in the [updated progress tracker](security-implementation-progress-2026-10-22.md) and [completion checklist](security-completion-checklist-2026-10-23.md). Recovery remains opt-in source only and disabled for release.

## Latest typed-sync/recovery implementation

The [current implementation](security-sync-financial-recovery-implementation-2026-10-25.md) prepares typed sync and financial-state reconciliation behind a default-off flag, rejects raw status/delete writes and adds recovery coverage manifests. All 22 scoped findings remain unfinished. Protected current-data, concurrent/client/provider and fresh-phone recovery acceptance are the next gates.

## Previous local implementation

The [sync/recovery/provenance batch](security-sync-recovery-implementation-2026-10-25.md) adds request validation, safe sync errors and recovery scope checks. All 22 scoped findings remain unfinished. [Updated remaining slices](security-data-dependency-mobile-documentation-plan-2026-10-25.md#15-remaining-work-after-the-syncrecovery-slice) cover recovery manifests, additional route families, historical classification and data/index review. No activation or deployment.

## Focused execution plan

[Data, dependency, mobile and documentation plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md) covers 22 unfinished D/N/M/W findings through six phases, with dependency, preservation, recovery and acceptance criteria. It does not add new packages or change the 14 implementation / six gate counts. Status: implementation in progress. The [current implementation record](security-storage-implementation-2026-10-25.md) and [recovery flow](security-recovery-flow-2026-10-25.md) record the new source/local checks and remaining acceptance. The remaining 22 findings stay unfinished; new source slices do not close whole packages.

## Count and scope notes

- The 14-package grouping covers all unfinished source/data themes already recorded in P2–P7, the 68-item audit and the eight system-design items. It adds no new vulnerability claim.
- Every one of the 50 partial/open finding IDs maps to at least one implementation package or release gate in the [machine-readable register](../artifacts/security-review-2026-10-20/remaining-work-2026-10-25.json). Mappings overlap; do not add per-row ID counts together.
- I04, I05 and parts of I14 require evidence-based retain/remove decisions. Historical data, useful indexes and supported code must not be deleted merely to close a checklist. Lower-priority cleanup can have a separately approved release scope; it remains in the full-plan backlog.
- No new application tests or live checks were run for this documentation count. The latest implementation test evidence remains the separately dated 25 October record.
- Defaults stay off where previously off. No live data/key/contact changes, extra user password, silent upload, feature activation, push or deployment is included.

[Open the complete audit HTML](security-and-backend-audit-2026-10-20.html) · [Open this summary as HTML](security-remaining-work-2026-10-25.html).
