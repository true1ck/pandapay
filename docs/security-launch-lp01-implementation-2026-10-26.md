# LP01 first source batch — 26 October 2026

The [implementation plan](security-launch-implementation-plan-2026-10-26.md) covers LP01–LP10 in order. Three Luna agents prepared that plan and the auth/database reviews; the parent reviewed their diffs, added the migration-history safeguard, and integrated verification. This first LP01 batch is locally verified. **LP01 remains Partial**, and the ten launch priorities remain **9 partial, 1 open, 0 accepted**. No finding, package or launch gate is newly closed.

## Changes and evidence

| Change | Before | Implemented behavior and verification |
| --- | --- | --- |
| Public-access role attributes | The privilege evaluator skipped roles classified as `exposure`, including configured `anon`/`authenticated`. An otherwise clean synthetic inventory with BYPASSRLS could report `strict_pass: true`. | Configured exposure roles now receive the same dangerous-role checks as other monitored roles: SUPERUSER, BYPASSRLS, CREATEDB, CREATEROLE and REPLICATION block strict acceptance. Unit checks and a real restricted-login PostgreSQL fixture reject the synthetic unsafe role. No database role or grant is changed by the auditor. |
| Checksum-less historical product migrations | The protected-restore review could return strict success when source filenames were known but their saved migration checksums were missing. | `history_known` remains a filename/drift observation. New `history_checksums_verified` also requires every recorded product migration checksum to match; the strict summary requires it and reports `history_missing_checksum`. A regression holds both role audits clean, varies only the saved checksum, and proves that missing checksums fail. No checksum is filled in or baseline automatically approved. This does not verify that pending migrations have run. |
| Session-cache retention under clock adjustment | At capacity, the old loop could evict a still-live oldest entry before encountering a later expired entry after a wall-clock adjustment. | Expired entries are removed first; only then are oldest entries evicted as needed. A synthetic-fetch, controlled-clock comparison against `75ab2c4` shows the old live entry requires a refetch and the corrected version preserves it. The 1,000-entry cap, configured five-second wall-clock TTL, key rotation, session verification and public/member route behavior are retained. This verifies a narrow retention fix; production throughput and revocation latency remain unmeasured. |

Touched runtime source is limited to `api/src/auth.js`. The other changes affect read-only audit/review tooling, synthetic tests and documentation. Existing migrations, application routes, database rows, grants, keys and feature settings are unchanged.

## Verification

- API: **1,122 passed, 2 existing skips, 0 failed**.
- Auth: **340 passed, 0 failed**.
- Database-tool unit suite: **219 passed, 0 failed**.
- Owned disposable PostgreSQL **18.4**: the runtime privilege fixture passes under a genuine independent login. It verifies dangerous exposure-role rejection, PUBLIC/column/default grants, RLS, role/owner reachability, CLI strict/advisory behavior, truncation refusal and unchanged synthetic rows/grants. The owned cluster was stopped and removed.
- Baseline comparison compiles the old and new modules in memory without modifying the shared checkout. Synthetic exposure-role acceptance changes from true to false; the clock-adjusted cache keeps its live entry. No network request is sent by that comparison.
- Changed JavaScript syntax, report consistency/links and whitespace checks are recorded. Test groups overlap focused cases; do not sum them. Tests run from empty working directories with allowlisted synthetic environment values; no customer backup or live credential is read.

[Verification and exact source hashes](../artifacts/security-launch-lp01-2026-10-26/verification.json) · [Before/after comparisons](../artifacts/security-launch-lp01-2026-10-26/before-after-regressions.json) · [PostgreSQL scope](../artifacts/security-launch-lp01-2026-10-26/postgres-results.json).

## Remaining LP01 acceptance and next source batch

The [protected historical review](security-sync-isolation-implementation-2026-10-25.md) still reports checksum-less product history and role-policy findings. This batch does not rerun that customer-data restore or approve its historical baseline. Review original DDL/schema/consumer provenance independently before adopting checksums, then test the complete candidate and supported clients on the exact current protected copy and intended PostgreSQL provider. Inventory actual deployed images, roles and memberships; exercise anonymous/guest/wrong-account/device/revoked/deleted/narrow-admin behavior. PostgreSQL 18 synthetic proof cannot establish hosted PostgreSQL 17 or live deployment acceptance.

After these source prerequisites pass, the next source work is **LP02: recovery inventory, measured recovery targets and independent-custody preflight**. The current bounded Mac backup schedule remains in place. Actual independent storage and key custody require real operator-supplied destinations and acceptance; a second folder on the same Mac cannot supply that evidence.

No production deployment, live ACL/data mutation, provider send, purchase, migration adoption, backup schedule change, key rotation or feature activation occurred.
