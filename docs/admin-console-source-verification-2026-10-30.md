# Private admin source candidate — verification and remaining acceptance

Date: 30 October 2026. Branch: `codex/ios-shortcuts-prototype`, based on the merged master baseline `bbe58db`. This is source implementation evidence, not permission to deploy or a claim of production readiness.

## Implemented

- Existing Flutter console gains a private verified-email/WebAuthn flow, enrollment UI, server logout, CSRF and protocol headers, and a fresh-factor control. WebAuthn browser code is bundled locally with its license. The release web build succeeds without a third-party CDN.
- Private auth/API factories and explicit entrypoints are independent of public listeners and background workers. Customer auth explicitly rejects public admin/browser/introspection variants. Product ingress rejects the same paths. The private factory registers 92 explicitly classified administrative methods/paths.
- Session/challenge/grant state persists in PostgreSQL. Preauthentication cookies bind challenges, successful consumption is atomic, verified assertions require the exact origin/RP/user-verification settings, and ordinary customer JWTs cannot establish a private admin session. Opaque upstream tokens stay encrypted on the server.
- Session expiry, versioned revocation, CSRF, private introspection, step-up, credential counters and external session-epoch invalidation are implemented. The external epoch must be rotated and historical revocations reconciled after a restore.
- Forward auth/product migrations add private state and permission boundaries. Public customer database identities cannot assert admin status with a custom session setting. The auth runtime cannot enable principals or manufacture enrollment grants. Credential registration goes through a bounded routine that atomically consumes an approved grant/email proof/challenge.
- Provisioning supports explicit target preview/apply, pending enrollment, stale-ID reconciliation preserving audit IDs, primary/backup grants, enable and revoke. A subsequent implementation adds maintenance-only durable intent/product receipts, reviewed-hash status/resume, CLI serialization, changed-state refusal and revocation of unfinished admission. Regrant retires old sessions/factors/proofs. Hosted target fingerprint and verified TLS configuration require operator review. The static QA creator no longer seeds codes or mints refresh tokens.
- Local TLS/Nginx/SSH supervision, private Compose overlay, forwarding-only SSH configuration and an operator runbook are provided. They are not installed or deployed by this work.

## Executed verification

| Check | Observed outcome |
| --- | --- |
| Auth Node suite | 362 passed on the integrated source at the suite run; focused protocol tests rerun after subsequent integration fixes |
| API Node suite | 1,326 passed, 3 existing skips at the suite run |
| Flutter console suite | 57 passed, including four new private-auth tests |
| Flutter release web build | Passed with CSP/local resource flags |
| Flutter analysis | No issues found |
| Existing deployment tests | 24 passed |
| Local packaging tests | 3 passed |
| Disposable PostgreSQL private integration | Passed: real PostgreSQL 18, separate socket-only cluster, actual runtime roles, ownership/permission checks, concurrent single-use challenge consumption, enrollment/replay, session version invalidation, real signed P-256 WebAuthn login through both actual factories, step-up, CSRF, factor-revocation session invalidation and logout |
| Resumable provisioning PostgreSQL suite | 15 passed (suite plus 14 scenarios): crash at each commit, replay after revoke, factor change, stale preview/target, receipt drift, concurrent lock denial, protected enrollment files and stale-ID audit preservation |
| Full checked-in schema rehearsal | Passed: clean auth/product schemas through canonical runners, repeat runs, all GET route registrations, catalogue create/upsert/review/publish, readonly/operator denial, audited support resolution audited referral hold/release, and customer inability to assert administration |
| Focused gateway/API/public-boundary tests | 12 passed after integration fixes |
| Route-manifest copies | Synchronization check passed |
| Database/script regression suite | 233 passed, including dependency-license checks for pinned WebAuthn dependencies |
| Existing encrypted recovery rehearsal | Not executed to completion on this Mac: the required `age` binary is unavailable; existing CI retains this gate |
| Credential-pattern scan | No matches in pending changes; this is not a complete secret/security audit |

The protocol fixture is deliberately synthetic and minimal. A separate rehearsal now applies the complete checked-in auth/product schemas to clean disposable databases and exercises read routes and representative writes. These prove the tested authority/protocol/schema behavior, not compatibility of every populated application table, provider or actual hosted schema. Test authenticators sign a real WebAuthn assertion; physical key registration and operator recovery were not performed.

## Local-owner request after the source candidate

The user selected **local development only** for the first owner. Read-only inspection found an older product membership for the requested email on the loopback `pandapay` database, no matching identity in the paired local `pandapay_auth`, and no new private-admin schemas applied there. The inspected project configuration mixed a stale local product port with hosted auth; it was not used for provisioning. No account/grant/verification flag was created or changed. The updated [implementation plan](admin-console-implementation-plan-2026-10-30.md#51-creating-the-first-local-owner-and-adding-later-admins) records the requested owner, outstanding local setup and exact verification/reconciliation/enrollment sequence, plus the procedure for additional administrators.

## Still required before live activation

1. Rehearse upgrades against a recent actual-data restored copy. The clean checked-in schemas pass; target history/data, grants, owners, inheritance, all views/definer functions, every role/operation pair and audit preservation still require acceptance. Correct any compatibility gaps before enabling administration.
2. Complete code-level requirements still open: durable broadcast dispatch, reviewed learning-worker dispatch, expensive-operation concurrency/idempotency, pagination for legacy unbounded reads, auth-state retention and operational monitoring. Then exercise all 92 handlers and existing console workflows against the actual least-privilege runtime, including expensive/worker operations, transactional audit and uncertain-outcome/idempotency requirements. Representative catalogue/support writes pass locally; other mutations remain to be completed/accepted. The autonomous learning cycle is explicitly rejected until reviewed worker dispatch is available. Notification broadcasts return 503: no private provider adapter is wired, and the private API never loads the customer provider configuration. Implement durable audited/idempotent dispatch before enabling that operation.
3. Run independent security review and built-image/network tests on the intended deployment: IPv4/IPv6, provider/direct origins, customer regressions, concurrent replicas, restart/rotation/outage races, connection/provider budgets and representative resource behavior. The evidence here does not establish million-user capacity or zero vulnerabilities.
4. Verify the exact compute host/private topology, strict TLS/SSH trust and external/LAN denial. Install local trust only with the operator's explicit action. No public console hosting is approved.
5. Enroll the real owner with independent primary/backup authenticators and verify grant/revocation, restore-epoch rotation and recovery without a bypass. Retire any existing test grants/challenges/sessions in the actual environment.
6. Verify the new provisioning maintenance-role privileges and paired journal/receipt restore/reconciliation on the actual target; local tests use disposable PostgreSQL. No real local user has been provisioned by this follow-up.
7. Extend/complete the existing release-evidence workflow for the actual private deployment and obtain accountable operator approval. Keep the opt-in profile off until all applicable requirements pass.

Three Luna agents contributed separate source areas, then stopped at their usage limit. The coordinator completed local integration fixes and verification. That coordination is not an independent security review.

Use [the deployment runbook](../deploy/admin/RUNBOOK.md) and [the full implementation plan](admin-console-implementation-plan-2026-10-30.md) for release acceptance. Any unchecked requirement remains open; the source changes do not automatically complete the plan's production checklist.
