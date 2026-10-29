# Luna coordinator handoff: private local admin console

Use the [implementation plan](admin-console-implementation-plan-2026-10-30.md) as the authoritative implementation and deployment contract. The [original design](admin-console-local-only-design-2026-10-30.md) contains the initial findings. This handoff does not authorize production changes.

Master has been synchronized through `32ed071` into the current branch. Start every worker from the resulting merged tree and read the implementation plan's **Master synchronization review**. In particular, preserve the new customer AutoPay correction route, recovery masking, merchant locks, subscription review behavior and combined parser version 23. The earlier admin security gaps remain open; none of the master commits supplies the planned private admin controls.

## Copyable coordinator task

> Implement the PandaPay local-only admin console described in docs/admin-console-implementation-plan-2026-10-30.md. Start by reading that complete document, repository instructions, current Git status and the referenced source. Keep all final work on the current branch, codex/ios-shortcuts-prototype, unless the human explicitly changes the target. Preserve unrelated work and do not merge or push other branches.
>
> Reuse the existing Flutter console. The browser UI must stay on the operator PC; the backend admin path must be private and independently authenticated/authorized. Ordinary customer tokens, static QA OTPs, spoofed role/assurance fields, a localhost page and private-network membership must never grant administration.
>
> Execute Wave 0 first: inventory every real admin route and database privilege path, freeze versioned HTTP/storage/config/permission contracts and synthetic fixtures, resolve safe stale-ID/audit reconciliation, and pin reviewed dependencies compatible with the actual runtime. Record unresolved live-host facts as deployment gates; never invent infrastructure or credentials.
>
> Then dispatch work packages A–F from the plan in the specified waves. Run three implementers concurrently when capacity permits. Use the currently available Luna model only if the tool actually provides it; do not silently claim a different model is Luna. Assign exclusive files, interface versions and isolated test databases. Keep shared entrypoints/manifests/lockfiles/Compose/release-check files under coordinator ownership.
>
> Require each worker to return changes, commands/results and remaining blockers. Integrate the existing mobile/customer routes unchanged in behavior, including auth, recovery, catalogue, sync and SMS. Private admin services must not start public-service background workers or consume unbudgeted connections. No security dependency may fall back to customer authentication or stale authorization.
>
> Complete component and independent cross-boundary verification, including real PostgreSQL runtime roles, two-replica challenge/revocation races, customer regressions and actual built-image route separation. Do not substitute mocked/static checks for deployment evidence.
>
> Deliver code/migrations/tests, a PC installer/start-stop launcher, private backend manifests, safe provisioning CLI, deployment/recovery/rollback runbook and a secret-free evidence report. Commit/push only to the agreed current branch when the integrated work is ready.
>
> Do not deploy, change live grants/accounts, open firewall rules, send real test mail, expose static assets publicly or register a real authenticator without the separately authorized operator step. Do not bypass the existing production workflow's master/exact-tested-commit controls. If live target, trusted SSH/TLS setup or human authenticator interaction is missing, finish all independent work and identify the exact remaining gate.
>
> Final status must distinguish source completion from production acceptance. Do not claim zero vulnerabilities, production readiness or successful live activation without corresponding evidence.

## Worker dispatch briefs

Each brief inherits the master plan. Paste only the applicable brief plus the frozen contracts and exclusive file list.

### A — PostgreSQL and provisioning

Implement the plan's storage, least-privilege roles/policies, read-only preview and idempotent provisioning/reconciliation/revoke operations. Preserve audit attribution across stale auth UUIDs and unique-email conflicts. Enforce pending-before-enabled behavior across the two stores. Restrict the old static QA bootstrap to explicitly disposable test targets. Do not create a real user, mark email verified, seed codes or mint a login token. Deliver clean-install, upgrade, actual-role, failure/retry and conflict tests.

### B — Admin authentication and durable sessions

Implement the private gateway factory, verified-email plus UV-required WebAuthn flow, controlled first/backup-factor enrollment, purpose-bound challenges, opaque admin tokens, private introspection, server-held credentials, CSRF, revocation, quotas and session timeouts. Use A's interfaces with injected contract fakes until migrations are ready. Do not mount anything on public auth or accept mobile tokens as admin proof. Deliver replay, outage, rotation, concurrent-consumption and restart tests.

### C — Admin API and permissions

Inventory/extract all admin handlers into private-only factories while preserving business behavior. Map actual side effects to explicit permissions and step-up requirements. Require current dedicated admin context and product membership, never a client role or an injected requireAuth fallback. Deliver the route manifest, bounded handlers, DB actor-context wiring and deny-by-default tests, including public route absence and customer-token confusion. Request shared entrypoint patches from the coordinator.

### D — Existing console UI

Implement the frozen browser flow using locally bundled WebAuthn support, target/setup status, correct preauth/MFA/expiry/cancel states, permission-based actions and working server logout. No password/code/token embedded in a bundle, no CDN, no direct DB or public-admin fallback. Keep actual authorization server-side. Deliver widget, client-contract and browser-factor integration checks. Hardware verification remains an operator acceptance step.

### E — PC packaging and private deployment

Deliver reviewed local release build/HTTPS proxy/SSH launcher templates and private backend deployment manifests. Enforce loopback on both PC and server published ports, fixed upstreams, exact local origin/RP, restricted forwarding identity, pinned trust, no shell/agent/remote-forward access, private container networks and bounded resources. Preserve existing deployment guards. Document actual-host preflight, install/start/stop/upgrade/rotation/recovery/rollback and independent exposure checks. Do not execute live changes.

### F — Independent verification

Write cross-boundary tests against integrated factories and built images, not merely the component mocks. Exercise API/DB permissions, public/provider/direct-origin absence, malformed paths/headers, CSRF/credential confusion, one-use challenges, revocation across replicas/restarts, uncertain mutation outcomes and customer compatibility. Review secrets, grants, connection/provider budgets and logs. Report failure or missing acceptance accurately; do not self-approve a live release.

## Required final report

- Source commit and exact changed paths.
- Completed work packages and unresolved contract decisions.
- Test commands, pass/fail/skipped results and limitations.
- Local PC assets versus backend/DB/SSH deployment assets.
- No secret values; only secret references and credential-free hashes.
- Outstanding target/hardware/live-data/external-network acceptance.
- Whether production is still disabled, ready for an authorized rollout, or actually deployed with independent evidence.
