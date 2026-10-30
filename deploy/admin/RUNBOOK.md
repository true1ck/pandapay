# PC-only administrator deployment

Status: local source candidate. No live backend, account, tunnel trust or OS certificate trust has been installed by this change. The private profile is opt-in and the existing customer production workflow is unchanged.

## Source and tests

Read [the implementation plan](../../docs/admin-console-implementation-plan-2026-10-30.md) and [source verification](../../docs/admin-console-source-verification-2026-10-30.md). Run `bash scripts/test_private_admin.sh` from the repository root with PostgreSQL binaries installed. It creates a separate socket-only cluster and destroys it; never point its tests at a real account database.

Run the auth/API Node suites, console Flutter tests and release build, dependency/secret checks and deployment tests. The dedicated CI step runs private boundary and signed WebAuthn integration tests. A successful localhost test is not target deployment acceptance.

## Target prerequisites

Inventory the actual hosting/provider, all direct origins, network/firewall paths, TLS roots, database identities and migration history. Confirm supported Node/PostgreSQL/Docker/OpenSSH versions, a fresh paired backup/restore proof, maximum pool budgets and separate approved admin SMTP quotas. Rehearse migrations and runtime grants on an actual-data restored copy before promotion.

Every route still needs acceptance against the populated target schema and least-privilege runtime. The clean checked-in schemas, read routes and representative catalogue/support writes pass locally. Provider-backed/expensive operations and legacy routines still need transaction, permission, audit and uncertain-outcome checks. Broadcasts are unavailable until a private durable/idempotent provider adapter is implemented; autonomous learning dispatch is also explicitly unavailable. Keep the admin profile off until the remaining cases pass.

## Database preparation

Use the canonical auth/product migration runners. New files are auth migration `0012_private_admin_access.sql` and product migration `20261030100000_private_admin_authority.sql`.

For explicit maintenance bootstrap only, provide independent generated credentials through protected environment configuration: `ADMIN_GATEWAY_DB_PASSWORD` and `ADMIN_API_DB_PASSWORD`. Existing credentials are checked, not silently rotated. The gateway authenticates as `admin_gateway_runtime`, the API as `admin_api_runtime`; neither owns the schema nor has superuser/BYPASSRLS. Runtime URLs must use those exact identities with verified PostgreSQL TLS. Migration/provisioning credentials stay outside service containers.

The product migration replaces broad email uniqueness with active-email uniqueness and restricts private administrative RLS by permission. Preserve all old membership IDs and audit records. Rehearse this against real constraints, default/inherited grants, existing views and functions. Public customer roles must still read published data and perform their own account-scoped operations.

## Private backend deployment

After an explicitly approved promotion through the existing tested-commit workflow, deploy the new public services with public `/admin`, `/browser` and private introspection paths blocked. Verify provider-generated URLs and direct ports as well as friendly domains.

Review the merged Compose model locally without printing secret values. From the repository root the private overlay is:

```sh
docker compose -f docker-compose.prod.yml -f deploy/admin/compose.private.yml --profile admin config --quiet
```

Starting that profile is a separate authorized deployment step. Gateway uses server loopback publication `127.0.0.1:4321`; admin API has no host port. Both use the separate admin container network; do not attach customer or worker containers. The host firewall must restrict actual DB/mail egress. Same-host private HTTP is permitted only on that reviewed network; cross-host calls require authenticated TLS. Verify IPv4, IPv6, Docker direct routing and external/LAN denial.

Configure independent backend-only values: `ADMIN_AUTH_DATABASE_URL`, `ADMIN_API_DATABASE_URL`, `ADMIN_ENVIRONMENT`, `ADMIN_TOKEN_LOOKUP_KEY`, `CONSOLE_SESSION_ENCRYPTION_KEY`, `ADMIN_INTROSPECTION_SERVICE_SECRET`, `ADMIN_SESSION_EPOCH` and the `ADMIN_SMTP_*` settings listed by the overlay. Encryption key is canonical base64 for 32 random bytes; token lookup/service credentials are independent random values at least 32 bytes. Never use example credentials. Missing configuration causes a private-service startup failure without affecting customer services.

`ADMIN_SESSION_EPOCH` is an externally retained random value, at least 32 characters. Rotate it and reconcile revoked factors/memberships before enabling a restored database so restored sessions cannot regain access. This epoch does not replace complete operator revocation records or factor recovery checks.

## Administrator enrollment

For the current local-owner request, completed/remaining work and exact initial reconciliation procedure, use [implementation plan §5.1](../../docs/admin-console-implementation-plan-2026-10-30.md#51-creating-the-first-local-owner-and-adding-later-admins). The requested local email has an orphan membership but no local auth identity; it is not provisioned or enabled.

First verify the intended email in the target's ordinary auth service; the CLI never creates a user or marks an email verified. Set the two explicit `ADMIN_PROVISION_*_DATABASE_URL` values in protected maintenance configuration and the exact `ADMIN_PROVISION_ENV` (`local`, `staging` or `production`). Hosted operations also require the reviewed credential-free target fingerprint emitted by the CLI as `ADMIN_PROVISION_APPROVED_TARGET_SHA256`; do not approve it without independently checking the target.

Use `node db/scripts/admin_access.js plan --email EMAIL --user-id UUID --role owner --reason REASON --operation grant`. The preview produces a plan hash. Use `apply` with the same arguments and `--plan-hash HASH` only after review. If a stale UUID already holds the email, use an explicit `reconcile` plan; old audit IDs remain in place.

The principal stays pending. Issue separate `enrollment-grant --user-id UUID --slot primary|backup --file ABSOLUTE_PROTECTED_FILE` grants, then use the PC console's verified-email enrollment screen. Each grant expires after ten minutes and is single use; neither grant creates an admin session. Enroll and test independent primary/backup authenticators, then use the explicit `enable --user-id UUID --reason REASON` command. Verify actual product membership, role and hardware factors before approving live use.

Revocation uses `revoke --email EMAIL --user-id UUID --reason REASON` and must remain available when the account is disabled. Keep operator credentials out of logs, source, shell history and browser bundles. The old `create_test_admin.js` command always refuses OTP/session minting.

## PC install and operation

Build/install the reviewed local bundle using `bash scripts/admin_console/install.sh ABSOLUTE_PRIVATE_NEW_DIRECTORY`. Nothing uploads the bundle. Install a locally trusted `localhost` certificate/key using the operator's approved trust process. The scripts never install a CA, invoke sudo or modify the firewall automatically.

Configure a distinct forwarding-only SSH account/key with pinned host trust. Validate `deploy/admin/sshd-forwarding.conf.example` against the actual SSH version before reload, retaining a recovery shell. Permit only forwarding to `127.0.0.1:4321`; no shell, PTY, agent forwarding or remote-forward access.

Copy `scripts/admin_console/config.example.json` to a protected mode-0600 operator file, replace every value and select the intended target. Run:

```sh
bash scripts/admin_console/start.sh --target staging --config /absolute/protected/config.json
bash scripts/admin_console/status.sh
bash scripts/admin_console/stop.sh
```

The launcher checks protected files, target agreement, pinned SSH trust, occupied ports, Nginx syntax and gateway readiness, then opens `https://localhost:8443`. It binds only loopback and has no public fallback. It supervises only its own child processes; stop uses the private control socket instead of killing arbitrary PIDs. The browser performs verified-email and user-verified WebAuthn login. Sensitive actions can request fresh verification through **Verify security key**.

## Incident, rollback and recovery

Disable the private profile/admission and revoke affected device keys and sessions first. Customer services stay independent. Do not restore a public admin site, static code, broad privilege or previous session authority as a rollback shortcut. Keep additive security/audit data; a database restore requires rotated external session epoch, reconciled grants/factor revocations and fresh enrollment/permission acceptance before reopening access.

Current source still requires independent target-specific review and live acceptance. The Luna agents reached their usage limit; their partial work was reviewed and integrated by the coordinator. This report is not an independent security audit or a production approval.
