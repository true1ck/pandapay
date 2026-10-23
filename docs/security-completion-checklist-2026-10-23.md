# Security completion check — 23 October 2026

The recovery and identity foundation is implemented and locally verified.
**The entire P0–P7 plan and production rollout are not complete.** This file
distinguishes completed evidence from the work that remains.

## Completed evidence

- Original deployed encryption and lookup keys retained in protected local
  storage; [secrets locations](security-secrets-inventory-2026-10-23.md) and a
  private `SECRETS-INDEX.md` are documented without secret values.
- Bounded daily encrypted product/auth exports configured on the owner's Mac:
  07:45 local time, seven days/seven sets, 1 GiB ciphertext cap, 5 GiB free
  floor, 95% disk ceiling and 30-minute runtime limit.
  Actual launchd execution and recovery of its fresh export both passed;
  the physical folder uses Application Support with a Documents shortcut.
- Actual v5 backup restored into a separate, disposable PostgreSQL cluster.
  Original tables, row digests, schema, owners, ACLs, cluster parameter grants
  and retained application keys passed verification.
- Product legacy adoption/upgrade and replay passed on that full-data copy.
  All 97 deployed historical migration files matched the released source.
- Approved test-contact resolution and auth upgrade/replay passed on the copy:
  all eight account IDs preserved, two original phone claims archived, no
  account merges. Live contacts remain unchanged.
- Verified database TLS, bounded IMAP destination checks, OTP purposes,
  PostgreSQL-backed OTP/enumeration/replacement quotas, readiness guards,
  log sanitization and deployment fencing implemented in source.
- Dependency locks, service build isolation and SMTP TLS settings reviewed;
  local synthetic provider fixtures used without live messages.

Exact test results and scope are in the
[progress record](security-implementation-progress-2026-10-22.md).
Final local results include 786 API passes (two skipped), 154 auth passes,
48 database checks, 45 backup/failure/setup checks, 21 deployment checks and 1,466
Flutter app passes. Actual v5 full-data restore and product/auth upgrade/replay
also passed. These do not replace signed-device or managed-provider acceptance.

## Plan reconciliation

| Phase | Status | Work still required |
| --- | --- | --- |
| P0: baseline | Partial | Final supported-client/device inventory, provider quotas, external writers and scheduled-job inventory. |
| P1: recovery/migration foundation | Local implementation and actual-copy proof complete | Two independently hosted copies, separate identity custody and recovery on the intended managed target. The owner's temporary PC setup is one location. |
| P2: encryption/identity | Partial | Controlled live contact/index rollout; remaining versioned encryption/keyring work for email/profile/raw payloads and IMAP, with compatibility backfills. |
| P3: authentication/browser | Partial | Remaining authentication policy audit, broader abuse controls and console cookie/BFF/CSRF/CSP transition. OTP purposes and selected durable quotas are implemented. |
| P4: permissions/jobs/lifecycle | Partial | Whole-schema runtime/worker roles, definer/RLS cross-user verification, remaining integration leases/deduplication, portable jobs, durable deletion/retention and recovery tombstones. |
| P5: device/app | Activation deferred | Password-free recovery design and implementation, resumable local database/receipt encryption, signed Android/iOS upgrade and key-loss checks. No new end-user password is authorized. |
| P6: provider cutover/release | Not complete | Full managed-provider rehearsal, post-write failback/replay, current/oldest-client acceptance, capacity/timing evidence and controlled live rollout. |
| P7: retire compatibility | Not started | Requires monitored successful rollout and the agreed compatibility window; keep existing readers, keys and recoverable history meanwhile. |

The separate portable-export feature newly present on the main branch is not
the password-free device-recovery implementation. Its passphrase archive
primitives do not change the existing login flow or enable device encryption.
Its own implementation status and unfinished integration/device checks remain
in `portable-backup-implementation-status.md`.

## Next release sequence

1. Review the exact integrated source and finish the applicable P0/P2–P4
   source controls and supported-client checks.
2. Configure independent recovery locations and identity custody; rehearse on
   the intended provider with retained keys and the reviewed baseline.
3. Follow the [controlled rollout runbook](security-rollout-runbook-2026-10-23.md):
   fence every writer, take the final paired backup, apply the approved contact
   resolution and migrations, verify identities and application behavior, then
   reopen writes with compatible images.
4. Implement and verify password-free device-data recovery before enabling
   local encryption. Retire compatibility only after monitored acceptance.

No live DDL, contact reassignment, key rotation, deployment or service restart
was performed by this implementation batch. The owner subsequently requested
source publication on the `dev` branch; publishing source does not complete
the production release gates above.
