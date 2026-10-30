# Local admin console: implementation and deployment plan

Date: 30 October 2026. Updated after source commit `a4d0c02` on `codex/ios-shortcuts-prototype`. Status: private-admin foundation implemented and tested locally; implementation gaps and deployment acceptance remain. The feature is not live.

Source candidate update: the [implementation verification report](admin-console-source-verification-2026-10-30.md) records the private protocol, UI, runtime, migrations and packaging now added, executed local checks and remaining acceptance. Use the [operator runbook](../deploy/admin/RUNBOOK.md) for concrete installation/deployment steps. Production remains unactivated; this specification's completion checklist is not automatically satisfied by the source candidate.

This is the implementation companion to the [reviewed design](admin-console-local-only-design-2026-10-30.md). Use the [Luna coordinator handoff](admin-console-luna-handoff-2026-10-30.md) to assign the work. The original review used commit `78651cf`; implementation preparation subsequently merged master through `32ed071` into `codex/ios-shortcuts-prototype`. Re-read the current merged branch before implementation; never implement against the pre-merge snapshot.

### Implemented, remaining and first-owner status

This table records source implementation, not activation. The [verification report](admin-console-source-verification-2026-10-30.md) contains the executed evidence; the [runbook](../deploy/admin/RUNBOOK.md) contains operator commands.

| Area | Already implemented | Still to implement or verify |
| --- | --- | --- |
| Public/private boundary | Separate auth/API factories and entrypoints; public `/admin`, `/browser` and introspection denial; legacy QA OTP/session minting retired | Built-image, edge/direct-origin, LAN/IPv6 denial and complete customer regressions on the intended target |
| Authentication | Six-digit email proof plus user-verified WebAuthn; purpose/cookie/origin/RP binding; atomic enrollment-grant consumption; primary/backup enrollment checks | Physical-key/browser acceptance, later-factor management and offline recovery; real provider delivery/shared quotas |
| Sessions | HttpOnly browser cookie, CSRF, server-encrypted opaque upstream tokens, idle/absolute expiry, step-up, logout, principal/factor revocation and external restore epoch | Multi-replica renewal/revocation races, key rotation/custody, restored-state reconciliation and bounded retention |
| Authorization and data | 92 classified method/path policies; current membership rechecked; dedicated NOINHERIT runtimes; forward auth/product migrations; DB rejects customer-asserted admin context | Every populated-table/role/mutation combination, definer-function owners/grants and full restored-target upgrade acceptance |
| Provisioning | Explicit target inspection/plan/apply/reconcile/revoke; pending admission; single-use enrollment grants; final enable requires two credentials | Durable cross-database operation/resume state, all crash/concurrency cases, real owner enrollment and access review |
| Existing console | Private email/passkey/enrollment flow; target/role display; fresh-factor action; server logout; local WebAuthn assets; release build | Complete readonly/permission-aware UI, expired-session/error flows and physical-device end-to-end checks |
| PC/private deployment | Local-only TLS/Nginx/SSH launcher; protected config; start/status/stop; opt-in isolated Compose profile and SSH template | Exact host/network/trust setup, patched image/version pinning, image/network tests, installation and approved activation |
| Verification | Auth 362, API 1,326 (3 existing skips), DB/script 232 and console 57 tests passed; clean/repeated full-schema migration rehearsal, all admin GET routes and representative audited writes passed | Every mutation, real-data performance, external exposure, independent review and encrypted recovery rehearsal (`age` unavailable on this Mac) |

**Requested first owner:** `chandresh.kerkar1@gmail.com`, **local development only**, as explicitly selected by the user. This is an operator enrollment request, not an email allowlist embedded in the app, an automatic seed, or an active grant. A second administrator can be added later with a separate verified UUID and separate credentials.

Local inspection on 30 October 2026 found the paired databases `pandapay` and `pandapay_auth` on loopback port 5432. The product database contains an older active owner membership for this email; the local auth database contains no matching user. Neither local database has the new private-admin schema yet. The API `.env` points at an unavailable local port while auth `.env` points at a hosted database; these files must not be combined for enrollment. **No administrator was created, enabled or reconciled during this documentation update.** Prepare the matching local stack, complete normal email verification there, and then use the explicit reconciliation flow in §5.1. Do not reuse the orphan membership UUID to manufacture an auth identity.

### Remaining implementation work, in execution order

These are source gaps, separate from operator deployment gates. Successful unit tests do not close them.

| Priority / area | Concrete remaining deliverable | Completion evidence |
| --- | --- | --- |
| P1 — provisioning | Durable operation state and retry/reconciliation across auth/product commits; enrollment/enable/revoke race handling | Crash after each commit, duplicate invocation, stale preview and concurrent revoke cannot enable unintended admission; audit history preserved |
| P1 — mutations/providers | Finish every private mutation's grants, bounded business effects and transactional audit/idempotency; implement reviewed durable broadcast and learning-worker dispatch | Role-by-route real-DB tests, lost-response/replay reconciliation and bounded worker/provider execution. Broadcast currently returns 503; direct learning cycle returns 409 |
| P1 — database authority | Review every table/view/definer routine and owner under actual least-privilege migration/runtime identities | Full populated upgrade plus positive/negative permission matrix; customer/worker identities cannot reach admin authority |
| P1 — session/recovery | Multi-replica refresh/CSRF/revocation races, supported factor replacement/recovery, encryption/lookup-key rotation and retained revocations after restore | Restart/rotation/outage and formerly-valid session/factor/grant restore tests; no OTP-only bypass |
| P1 — scale/budgets | Paginate legacy unbounded reads, bound expensive job concurrency and request/response work, share actual mail/provider quotas and whole-cluster connection budgets | Representative populated-data load with bounded public latency, DB locks/connections and provider calls |
| P1 — operations/release | Auth-state retention, monitoring/alerts, exact-candidate release evidence and pinned private runtime/image inventory | Monitored cleanup/failure tests; release checker refuses activation when required admin evidence is absent |
| P2 — console/contracts | Complete permission-aware UI, safe expiry/retry UX, remaining versioned HTTP/config/repository schemas and documentation; supply native local-dev service/proxy configuration alongside the SSH deployment mode | Readonly UI and denied/expired/unknown-outcome flows tested; generated contract copies agree |
| Final — target acceptance | Real local owner enrollment now requested; hosted migration/deployment remains separately scoped | Verified target, independent primary/backup authenticators, installed local trust, external-denial proof and accountable activation |

### Master synchronization review

Master added 11 commits after the previous shared base, covering guarded AutoPay correction, subscription projection/review, locked merchant corrections, historical SMS repair, card scanning, recovery phone masking and customer auth/support UI. None implements the private admin identity, MFA, route isolation or safe provisioning required here, so the selected admin architecture remains applicable.

- Preserve the customer `POST /transactions/autopay-bill-correction` endpoint's existing session, ownership, amount, source and locked-merchant checks. It is a customer correction route, not an admin endpoint to move to the private listener.
- Preserve reconciliation version 3, user merchant locks and the distinction between observed subscription review candidates and confirmed recurring services. Private admin route extraction must not alter those shared business helpers or start their background workers.
- Preserve `maskPhonePrefix` behavior for recovery-scoped responses. An admin login cannot use recovery-only proof as full account verification or privileged MFA; do not broaden the user/recovery response to expose full phone data.
- Keep raw message diagnostics out of ordinary customer support/feedback views and out of administrative audit/report output. Prototype-only device diagnostics do not authorize logging that data on the backend.
- The merge retains both branches' parser improvements. Its local parser version is 23 so devices already processed with either branch's version 22 can replay the combined grammar; preserve receive-time/explicit-zone behavior and Unicode-masked recipient matching.
- All package dispatches must start from this merged tree. Coordinator ownership still covers the newly changed `api/src/index.js`; workers must extract its current admin handlers without replacing it with a pre-merge copy.

Regression coverage must include recovery prefix masking and capacity checks, customer correction authorization/merchant locks, SMS parser timestamp/recipient behavior, subscription review/annual totals, card matching and customer login/support behavior. Targeted merge checks do not establish production acceptance or replace the full implementation verification matrix below.

## 1. Required outcome and boundaries

The existing Flutter dashboard runs only on the operator's PC. Its administrative operations use a private backend path with a real verified administrator, strong authentication, per-operation permissions, durable revocation and an audit trail. A customer login, a guessed endpoint, a static QA code, or access to the private network alone must never grant administration.

All implementation results stay on the current branch. No agent may merge to master, deploy a service, open a public port, change live database grants, create a live administrator, or send real test mail without the separately authorized release/account step. Preparing code, tests and deployment templates is the implementation scope. The existing production workflow accepts tested master commits; do not remove that guard to deploy this branch.

The live customer application still needs its public APIs. Administrative UI assets must not be uploaded to a public website, CDN, hosting bucket or app distribution. Backend administrative services necessarily run beside the data they manage, with private access. Scope includes API routing, auth, database policies, local packaging, deployment, recovery and verification; a localhost UI alone is insufficient.

## 2. Pre-implementation baseline and remaining target unknowns

The following table describes the original baseline, before `a4d0c02`. Use the status table above for current implementation; these baseline rows do not mean the old login/routing is still the selected design.

| Item | Original finding / target consideration |
| --- | --- |
| Dashboard | Reuse `console/lib/main.dart` and its existing features. |
| Login | `console/lib/features/auth/login_screen.dart` and `console/lib/data/admin_api.dart` implement phone/email OTP. No password field. |
| Browser transport | Existing relative `/browser` gateway, encrypted server-held credentials, HttpOnly/CSRF controls and server logout can be reused after changing admission. |
| Local launcher | `console/run_web.sh` starts Flutter development on port 5173; it does not provision a private production-quality gateway. |
| Product membership | Local `admin_users` has two active owner rows. Neither ID exists in the local auth database. These are incomplete memberships, not working logins. Do not assume live data is the same. |
| Static QA access | `db/scripts/create_test_admin.js` seeds a fixed OTP with default 30-day expiry and can mint a session; it has no adequate environment/target restriction. Retire it from real enrollment. |
| Role scope | `api/src/index.js` uses a boolean active-membership guard. `pandapay.is_admin()` does not distinguish readonly/reviewer/operator/owner. |
| Public/private routing | API admin and customer handlers share an entrypoint. Auth currently can mount `/browser` and its optional security dashboard on the ordinary auth listener. Separate these paths. |
| Deployment | `docker-compose.prod.yml` binds customer API/auth ports to server loopback. `deploy/nginx/console.conf.example` is a public-host example, unsuitable for this requirement. |
| Build/runtime | API/auth Dockerfiles currently use Node 22. Select supported, patched exact images and lockfile versions during the contract phase. |
| Existing public endpoints | README identifies `https://api.pandapath.site` and `https://auth.pandapath.site`. This does not identify the actual compute host, provider, firewall, DB projects or live configuration. |

Before a real deployment, collect a credential-free target record: environment, compute/provider identifier, region, public and provider-generated origins, SSH support, approved operator devices, Docker/OpenSSH versions, actual database/schema mapping, runtime roles, connection budget, backup/restore status and responsible operator. Record secret *references*, never values. If current hosting cannot enforce the private topology, document a supported private-network alternative for review; do not publish an admin endpoint as a shortcut.

## 3. Selected v1 architecture and deployment map

The reference implementation targets the Docker/SSH compute layout already described by the repository. Actual host availability is a release gate.

~~~mermaid
flowchart LR
  subgraph PC[Operator PC]
    UI[Local Flutter release bundle]
    LP[HTTPS loopback proxy :8443]
    LF[SSH local forward :7431]
    UI --> LP --> LF
  end
  LF -->|Encrypted SSH connection| HG[Server loopback :4321]
  subgraph Server[Existing backend compute]
    HG --> AG[Private admin gateway]
    AG --> AA[Private admin API :4001]
    AG --> MAIL[Existing mail provider with bounded sending]
    AA --> AG
    PUB[Public customer API and auth]
  end
  AA --> PDB[Existing product PostgreSQL]
  AG --> ADB[Existing auth PostgreSQL]
  MOBILE[Customer application] --> PUB
~~~

| Component | Location and entrypoint to implement | Exposure |
| --- | --- | --- |
| Console UI | Operator PC; reviewed `console/build/web` release output | Local filesystem and `https://localhost:8443` only |
| Local proxy | Operator PC; new `scripts/admin_console/` tooling and `deploy/nginx/console.localhost.conf.example` | Explicit `127.0.0.1:8443`; IPv6 loopback only if tested |
| SSH forward | Operator PC; managed launcher | `127.0.0.1:7431` to backend `127.0.0.1:4321` |
| Admin gateway | New `auth/src/admin/server.js` using the auth image with an explicit entrypoint | Docker `4321` published **only** as `127.0.0.1:4321:4321` |
| Private admin API | New `api/src/admin/server.js` using API image with explicit entrypoint | `4001` on the isolated admin container network; **no host publish** |
| Customer API/auth | Existing services and public domains | Existing customer routes only; admin/browser/security-dashboard routes absent |
| Databases | Existing reviewed product/auth deployments | Service connections only; no database credential in console/proxy/browser |
| Provisioning command | Explicit operator/maintenance context | No web route; temporary bounded provisioning credentials |
| Audit/monitoring | Backend, independent of PC uptime | Private operator destination and bounded, secret-free reports |

Gateway and private API share an isolated admin network, not the ordinary worker/customer container network. Services receive only their own runtime credentials. Across hosts, require authenticated TLS/private connectivity with certificate verification; plain HTTP is permitted only on the explicitly reviewed same-host isolated network. An unrelated container must not acquire access merely by running on the same host.

The gateway reuses existing identity/delivery source libraries through its bounded auth repositories and approved mail-provider connection. It does not relay sign-in to a public mobile-auth endpoint. It needs bounded egress to its auth DB/mail dependencies and the private API, not arbitrary Internet proxying or attachment to a broad customer/worker network. The API must reach the fixed private introspection endpoint and product DB. Do not create a second general-purpose customer auth backend or duplicate the business data.

### Local proxy and SSH contract

Freeze local origin `https://localhost:8443` and WebAuthn RP ID `localhost` for v1. Serve a local certificate trusted by the operator's browser; protect key material outside the repository. Listen only on loopback, validate Host and Origin, and reject unexpected forwarded headers. Proxy only the agreed `/browser/` paths to `127.0.0.1:7431`. Never proxy arbitrary caller-selected URLs.

Use a dedicated SSH identity and pinned host key. The launcher uses an explicit loopback `-L`, `-N`, `-T`, `ExitOnForwardFailure=yes`, strict host-key checking, no agent forwarding and keepalives. It must detect an occupied local port rather than silently trusting another process.

The server's restricted forwarding-only account permits just destination `127.0.0.1:4321`. Configure local forwarding only, no remote forwards, no shell/subsystems, no PTY, no agent/X11 forwarding and no user startup scripts. Validate the exact host's sshd configuration before reload and prove an existing recovery shell remains available. OpenSSH documents `PermitOpen` and `MaxSessions 0` for these controls: [sshd configuration](https://man.openbsd.org/sshd_config).

The local launcher owns its PIDs and temporary files; stop only those processes. A closed tunnel, missing certificate, unknown host key or unavailable backend produces an unavailable console, with no public fallback. PC malware or an administrator on that PC remains a threat; use a dedicated browser profile, OS lock, disk encryption and protected SSH keys.

Docker's loopback mapping is only one control. Verify a supported patched engine, IPv6, direct-routing configuration and host firewall. Docker documents a same-L2 localhost exposure issue in releases older than 28.0.0; those configurations need remediation and external verification before enablement. [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/).

## 4. Frozen security contracts

These choices are v1 defaults. Changes require an explicit contract revision by the coordinator, not a worker's silent fallback.

### 4.1 Identity, login and enrollment

- Identity is the existing auth user's stable UUID, with an active, verified email. Product membership, auth admin enrollment and current account state must all agree.
- Login requires a CSPRNG-generated, six-digit, purpose-bound email OTP **and** a registered WebAuthn credential with user verification. This is a separate privileged flow; do not reuse the public QA OTP path or make public mobile OTP issuance an admin session. The private runtime has no fixed-code environment switch.
- Use a maintained WebAuthn verification library, preferably `@simplewebauthn/server`, and a compatible browser adapter bundled locally. The current upstream server documentation describes Node 22+ support. The coordinator pins reviewed package versions, records them, and resolves CommonJS/ESM compatibility; do not use floating CDN scripts or implement signature verification manually.
- Server checks challenge, principal, credential ownership, purpose, expected origin, RP ID, expiry and user verification. Origin/RP ID are configuration, never client authority. Follow library handling for counters and backed-up credentials rather than assuming every authenticator increments a counter.
- A first credential requires both verified email proof and an explicit, one-use enrollment grant from the provisioning CLI. Grant TTL is 10 minutes and is bound to user, environment, origin, RP ID and factor slot. A public signup cannot issue it. Initial setup issues separate primary and backup grants; consuming a grant enrolls one credential but does not enable the principal. The principal remains pending until two distinct credentials are enrolled, product membership is consistent and the operator explicitly enables admission. Pending principals can prove email and enroll only; they cannot obtain an admin session. Adding/removing later factors requires fresh existing-factor authentication or the reviewed offline recovery procedure.
- Prove the selected browser/hardware supports the localhost RP/origin. If it does not, stop and revise the contract; do not disable verification or expose a public site.
- Before live enablement, register a primary and independent backup factor and verify recovery. There is no OTP-only, SMS-only, fixed-code or shared-password fallback for administration.

[SimpleWebAuthn server verification and persistence](https://simplewebauthn.dev/docs/packages/server) and [OWASP MFA guidance](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html) support these verification requirements.

### 4.2 Privileged session and API identity

Reuse the cookie gateway pattern, replacing its current use of general mobile credentials for the private admin path.

- The browser receives an independent opaque `__Host-pandapay_console` cookie with Secure, HttpOnly, SameSite=Strict, Path=/ and no Domain. It receives a CSRF token and nonsecret actor/permission metadata, never an upstream bearer or refresh token.
- Before MFA, an expiring preauthentication cookie/challenge grants no access. Only a completed, atomically consumed MFA challenge can establish the privileged session.
- Gateway-to-admin-API authentication uses a dedicated random opaque admin access token (at least 256 bits). The admin API accepts only this token type. Public/customer JWTs, including those for an admin's UUID, are rejected on this path.
- Store token lookup digests server-side. Any raw upstream token retained by the gateway must be encrypted using the existing reviewed key-management pattern. Never reuse the browser cookie as the upstream token.
- Introspect the token against the fixed private gateway endpoint on every admin request; v1 has no positive authorization cache. The response derives from current server state and includes `active`, actor ID, session ID, assurance, MFA verification time and expiry. Permissions come from the product authority, not browser fields or token role strings.
- Introspection requires a separate rotated service credential, constant-time validation and a fixed audience/purpose. Its credential cannot mint sessions or grant membership. Use authenticated TLS across hosts; never send it through public ingress, query strings or logs.
- Prevent a verification loop: introspection reads auth/session state only and never calls the product API. Top-level gateway admission/session restoration checks current product membership through the private `/admin/me`, whose middleware calls auth-only introspection. Commit session state before downstream verification and revoke on denied admission. Do not hold database transactions/row locks across an HTTP call, mail delivery or WebAuthn cryptographic work; use short compare-and-consume transactions and verify versions before commit.
- Both active auth-account state and active product membership are rechecked. Any dependency failure returns a bounded 503/denial, never stale privileged access.
- Access-token TTL: 5 minutes. Cookie session idle limit: 15 minutes. Absolute session limit: 8 hours. Fresh WebAuthn verification within 5 minutes is required for high-impact actions. Browser activity cannot reset absolute age.
- Token renewal is internal to a current verified admin session; an ordinary refresh token cannot obtain it. Rotate safely for concurrent requests, with a documented overlap no longer than 30 seconds for in-flight access tokens; revocation invalidates the whole session immediately.
- Persist sessions, challenges, grant consumption and rate limits in shared PostgreSQL so restart/replica changes do not recreate trust. Use atomic compare-and-consume semantics for one-use challenges.
- Logout and revocation destroy server authorization, not just browser state. Removing a factor or recovering an account invalidates affected sessions. Do not derive trust from user-supplied assurance headers.

### 4.3 HTTP contracts for parallel implementation

All routes below are **proposed private contracts**, served through the local proxy. Public listeners do not mount them. Request/response bodies are bounded JSON, no-store. All state-changing authenticated routes require the session, exact Origin and CSRF token. Preauthentication routes require exact Origin, Fetch Metadata policy and the agreed console request header.

| Route | Input | Result / authority |
| --- | --- | --- |
| `POST /browser/login/start` | `{email}` | Generic 202 `{loginId, expiresIn:120}`; no account enumeration or full session |
| `POST /browser/login/verify-email` | `{loginId, code}` | `{next:"webauthn", options}` for enabled principals or `{next:"enrollment"}` for explicitly approved pending principals; neither creates a privileged session |
| `POST /browser/login/verify-passkey` | `{loginId, credential}` | Consume bound challenge and create full session; return authenticated metadata + CSRF |
| `POST /browser/enrollment/options` | `{loginId, grant}` after verified email | One-use enrollment scope only; returns WebAuthn registration options |
| `POST /browser/enrollment/verify` | `{loginId, credential}` | Consume grant/challenge and store credential atomically; require normal full login afterward |
| `GET /browser/session` | Cookie; console request header | 200 `{authenticated:true, admin:{email,role,permissions}, csrfToken, expiresAt}` or 401 |
| `POST /browser/step-up/options` | Session + CSRF | New bound assertion challenge |
| `POST /browser/step-up/verify` | `{credential}` + session/CSRF | Updates verified MFA time, without extending absolute session age |
| `POST /browser/logout` | Session + CSRF | Invalidate session/tokens; clear cookie; idempotent completion |
| `/browser/api/admin/...` | Manifest-approved method/path/body | Fixed private API upstream; never arbitrary relay |
| `POST /internal/admin/session/introspect` | `{token}` + dedicated service identity | Private API-only lookup; inactive result for revoked/invalid token; no refresh/mint ability |

Challenge identifiers and grants are not URL parameters. Prefer one pending challenge of each purpose per preauth session; a new challenge invalidates the previous one. Verification stores bounded attempts and consumes success atomically. WebAuthn assertions cannot be reused for login, enrollment or step-up interchangeably.

Unknown/invalid credentials use generic errors. Use 401 for unauthenticated, 403 for insufficient permission, 429 for exhausted limits with Retry-After, and 503 for dependency outage. A pre-handler 401 is safe to recover once; a timed-out mutation is an **unknown outcome**, not evidence of failure. Do not blindly retry mutations; use a handler's existing idempotency contract or reconcile its result. Required idempotency for high-impact changes must be transactional with the effect and audit record.

Version the protocol: every browser request sends `X-Admin-Protocol: 1`; successful flow responses include `version: 1`. Unsupported versions fail with a safe upgrade-required response, without trying a legacy login. The localhost build explicitly enables the new admin browser flow; unsupported/native console paths cannot fall back to customer-token administration. Existing cookie/session records lacking the new admin context/version are invalidated during cutover rather than upgraded by assumption.

The old browser OTP/refresh shapes must not provide an alternative MFA-free session. Retire them in the private gateway or implement a strict adapter that cannot issue access before the full flow. Preserve mobile auth routes and semantics separately.

### 4.4 Permission contract

Create a machine-readable route-to-permission manifest before extracting routes. Enumerate registrations in `api/src/index.js`, `admin_rule_families.js`, `admin_referral_operations.js`, `ai_queue_route.js`, `sms_facts_route.js`, `sms_learning.js`, `sms_rule_bundle.js`, `sms_learning_feedback_route.js` and all other registrars. Include dynamic paths and middleware order. A guessed grep list is insufficient: integration tests must enumerate the actual registered private routes and assert a complete one-to-one policy map.

| Permission family | readonly | reviewer | operator | owner |
| --- | --- | --- | --- | --- |
| Approved catalogue/reference and sanitized operations reads | yes | yes | yes | yes |
| Restricted support/financial evidence reads | no by default | explicitly assigned scope | explicitly assigned scope | yes, audited |
| Review annotations/recommendations without applying global changes | no | yes | yes | yes |
| Catalogue draft edits, approved scraper configuration/run, support resolution | no | no | yes | yes |
| Publishing catalogue/rules, accepting changes that affect global parsing/rewards | no | no | no | yes + fresh MFA |
| Referral controls, bulk sensitive export, broadcasts, expensive audit runs | no | no | no | yes + fresh MFA |
| Administrator grants, recovery and factor reset | no | no | no | Provisioning/recovery CLI only in v1 |
| Auth security-event dashboard | no | no | no | Separate expiring capability; disabled for this first rollout |

Turn these families into explicit permission strings in the manifest, e.g. `catalogue.read`, `catalogue.edit`, `catalogue.publish`, `learning.publish` and `referrals.control`. Names of existing endpoints such as "review" do not establish safety; classify actual effects. An approve/review action that changes global behavior is publication.

Each admin route must require a dedicated admin session, current product permission, appropriate fresh-factor policy, and an audit policy. No route or unknown permission has an allow default. Remove constructor defaults that silently substitute `requireAuth` for `requireAdmin`. A missing security dependency must fail application construction.

Use a new private reference route `GET /admin/reference/categories` rather than expanding the gateway to relay general public routes. Update the console's category lookup accordingly; keep the customer `/categories` API working.

### 4.5 Database authorization contract

Endpoint isolation is insufficient if a public mobile session for the same UUID can still gain elevated access through database policies.

- Inventory every policy/function using `pandapay.is_admin()` and every admin table grant. Introduce a distinct bounded private-admin runtime login/capability, separate from the public API login.
- Effective DB admin context must require the private runtime identity **and** trusted actor/permission context plus active membership. Arbitrary custom GUCs from the public runtime cannot be sufficient. A SECURITY DEFINER function must check the intended original/session role correctly, not accidentally trust its own definer identity.
- Public application/worker roles must be unable to inherit or SET ROLE to the admin capability. Admin runtime must not own tables, be superuser, BYPASSRLS, create roles or run migrations.
- Replace broad write policies with operation-appropriate permission checks. readonly actors must fail direct write attempts through the reviewed runtime, not just lose UI buttons.
- Administrator membership/role DML belongs only to the provisioning capability. API/gateway runtimes cannot grant themselves roles, alter enrollment, or execute arbitrary privileged SQL.
- Use schema-qualified names, restricted function EXECUTE grants and safe search paths. Audit owners/default grants/inherited memberships on real restored data.
- Auth gateway runtime must use bounded identity/enrollment/session routines rather than broad reads or DML over all users, ordinary refresh tokens or membership tables. Provisioning and runtime capabilities remain separate.
- Keep public catalogue exports and customer account isolation correct for an admin who also uses the customer app.

## 5. Storage, migrations and provisioning

Add new forward-only migrations through `db/scripts/product_migrate.js` and `auth/scripts/migrate.js`. Do not edit applied migration files. The DB package owns unique migration IDs/prefixes. Clean install and upgrade from a recent restored copy must both work.

| Storage | Required state |
| --- | --- |
| Auth admin principal registry | Verified user FK, pending/enabled/revoked state, version, enrolled/revoked timestamps |
| WebAuthn credential store | Unique credential ID, principal, public key bytes, library counter/device/backup data, transports, revocation; no credential private key |
| Challenges/preauth/enrollment grants | Purpose, principal, bound session/origin/RP, expiry, attempts, consumption/version; grants stored as digests |
| Private `admin_private.sessions` | Implemented separate privileged state with principal version, external epoch, MFA time, idle/absolute expiry, revocation and encrypted upstream token; legacy `console_private` sessions are not accepted or upgraded into admin authority |
| Access-token digests | Bound to current admin session with short expiry; no plaintext token lookup store |
| Product role/permission data | Explicit allowed role-permission mapping, no runtime role-management DML |
| Provisioning/audit records | Durable operation ID, actor/reason, before/after state and completion; bounded secret-free metadata |
| Rate-limit namespace | Shared durable admin buckets/challenge attempts using existing bounded store patterns |

Provisioning is not a distributed SQL transaction. Keep a durable operation state: validate verified identity first; prepare the auth enrollment in disabled/pending state; commit/reconcile product membership; enable auth admin admission last. Failure, crash or partial completion must leave admin use denied. Repeated operations resume idempotently.

For stale membership IDs, dry-run refuses a silent rewrite. The selected reconciliation model retains the old row inactive with its original ID/email and audit references, and inserts the new verified UUID as the active membership. A forward migration replaces the global email-uniqueness constraint with uniqueness over active normalized/citext email. Create/validate the replacement invariant before removing the old constraint; preserve all existing rows and review lock budgets. Update membership lookups to require active state and exact verified UUID, with no ambiguous email-only authorization. The coordinator inventories all foreign keys and consumers in Wave 0; an incompatible consumer blocks this strategy pending an explicit contract revision. A worker cannot delete history, move audit attribution to a new identity, or silently choose another conflict resolution.

Implemented CLI `db/scripts/admin_access.js` supports `inspect`, `plan --operation grant|reconcile`, matching-hash `apply`, `revoke`, `enrollment-grant`, and explicit `enable` after factor acceptance. Durable multi-store resume remains open, so a partial failure requires inspection/reconciliation before retry. It requires explicit environment/target and a reason, validates the verified user ID, prints a credential-free preview, and applies only a matching plan hash. No automatic loading of an arbitrary project `.env`, no connection passwords in command arguments, no OTP seeds, no auth-user creation/verification bypass and no refresh-token minting. Secret outputs go to a named protected 0600 file, with only its path printed. Grant/revoke must have reversible and audited outcomes. A grant remains pending until the explicit enable checks pass; backend deployment alone does not activate a user.

Use separate provisioning credentials for product/auth, temporary custody and minimal routines/grants. Preserve prior admin audit attribution and reconcile conflicting identities before enabling the intended owner.

### 5.1 Creating the first local owner and adding later admins

**Current request:** use the first-owner email in the status section, with role `owner`, on **local development only**. Inspection found an orphan product membership and no corresponding local auth account. The commands below describe the supported enrollment procedure; none has been applied to that account yet. All remaining implementation/release requirements still apply before treating this as an accepted deployment.

1. **Use the matching local pair.** Select loopback port 5432, product database `pandapay` and auth database `pandapay_auth`. Keep the maintenance URLs in protected operator configuration. Do not source `auth/.env` for this task: it selects a hosted auth target. Do not change public application configuration or use the private runtime logins as provisioning identities.
2. **Prepare the local schemas and services.** Back up the local pair, review migration history, and use the canonical auth/product migration runners with the explicit local maintenance connections. An unledgered auth baseline must pass the runner's reviewed baseline/adoption checks. Do not run ad hoc DDL just to make the enrollment command succeed. Configure the local ordinary-auth service and private gateway/API explicitly against this pair, with separate runtime credentials. This setup has not been performed; no matching local auth service/mail/private-console configuration was found. The delivered launcher assumes reviewed SSH transport; a purely native local development setup still needs its explicit service/proxy transport configuration, without enabling OS remote login implicitly.
3. **Establish the ordinary auth identity.** Register/sign in through that local auth application's supported flow and complete its real email verification. Record the exact local auth UUID. A product membership with the same email is not an auth identity. Never create an auth row under the orphan UUID, set `is_email_verified` manually, seed an OTP, or substitute a hosted user's UUID.
4. **Inspect and preview.** Configure `ADMIN_PROVISION_ENV=local`, `ADMIN_PROVISION_PRODUCT_DATABASE_URL`, `ADMIN_PROVISION_AUTH_DATABASE_URL`, `NODE_ENV=development` and `DB_SSL=false` for the loopback pair. Set `ADMIN_OWNER_EMAIL` to the requested email and `ADMIN_OWNER_USER_ID` to its verified local UUID. These names below are operator shell inputs, not an app-level email allowlist.

   ```sh
   node db/scripts/admin_access.js inspect --email "$ADMIN_OWNER_EMAIL" --user-id "$ADMIN_OWNER_USER_ID"
   node db/scripts/admin_access.js plan --operation reconcile \
     --email "$ADMIN_OWNER_EMAIL" --user-id "$ADMIN_OWNER_USER_ID" \
     --role owner --reason "Initial local owner enrollment; preserve prior audit IDs"
   ```

   For this local email, `reconcile` is required while the older membership is active under another UUID. Review the printed target, verified UUID, conflicting ID and membership snapshot. Keep the old row inactive with its original audit references. For a future email without a stale membership, use `--operation grant` instead.

5. **Apply the reviewed preview.** Set `ADMIN_OWNER_PLAN_HASH` to the hash from that reviewed preview, then use exactly the same operation/email/UUID/role/reason:

   ```sh
   node db/scripts/admin_access.js apply --operation reconcile \
     --email "$ADMIN_OWNER_EMAIL" --user-id "$ADMIN_OWNER_USER_ID" \
     --role owner --reason "Initial local owner enrollment; preserve prior audit IDs" \
     --plan-hash "$ADMIN_OWNER_PLAN_HASH"
   ```

   This prepares pending auth admission and disabled product membership. It does not sign in or enable the owner. If either store fails, inspect and reconcile the partial result before retry; durable automatic resume remains an implementation gap.

6. **Enroll independent primary and backup credentials.** Install/configure the local private services and the PC console using the runbook. Use a new protected directory outside source control for grant files; mode 0700 for the directory, 0600 for files. Issue each grant immediately before enrolling its corresponding factor:

   ```sh
   node db/scripts/admin_access.js enrollment-grant --user-id "$ADMIN_OWNER_USER_ID" \
     --slot primary --file /absolute/protected/primary-enrollment.txt
   # In the local console: prove email, supply this grant, register primary.
   node db/scripts/admin_access.js enrollment-grant --user-id "$ADMIN_OWNER_USER_ID" \
     --slot backup --file /absolute/protected/backup-enrollment.txt
   # Start a fresh email proof and enroll the independent backup credential.
   ```

   Each grant expires after ten minutes and can be consumed only once. Neither grant supplies a full session. Do not paste grants into GitHub, URLs, logs or this plan. Remove the protected grant files after use/expiry.

7. **Enable explicitly and test.** Verify the target, UUID, prepared role and two independent enrolled factors. Only then run:

   ```sh
   node db/scripts/admin_access.js enable --user-id "$ADMIN_OWNER_USER_ID" \
     --reason "Local owner primary and backup factors accepted"
   ```

   Log in with email proof plus passkey. Confirm target/role display, a permitted audited operation, denied customer/less-privileged paths, step-up and server logout. Record the credential-free result and update this plan's local-owner checklist.

8. **Add another admin later.** Repeat normal local email verification and `plan --operation grant` / matching `apply` for the second person's own UUID. Select the least role needed (`readonly`, `reviewer`, `operator`, or explicitly justified `owner`); enroll that person's primary and backup factors and enable separately. Do not share the first owner's factors or add an email to source as authorization. For another environment, perform a separate target review/enrollment; local authorization does not promote anyone to staging or production.

To revoke an administrator, use the exact email/UUID and a recorded reason:

```sh
node db/scripts/admin_access.js revoke --email "$ADMIN_OWNER_EMAIL" \
  --user-id "$ADMIN_OWNER_USER_ID" --reason "Local administrator access retired"
```

Revocation is available even when the auth account is inactive. Re-enabling a retired account must not restore a revoked admin principal/session automatically. There is **no shared admin password** in this flow.

## 6. Configuration and secrets to implement

The private entrypoints implement the settings below unless explicitly described as remaining work. Missing/invalid required private settings deny private startup; they must not prevent customer API/auth from starting. Deployment must still validate target-specific values, custody and budgets.

| Setting | Owner / default |
| --- | --- |
| `ADMIN_GATEWAY_ENABLED`, `ADMIN_API_ENABLED` (private setting) | Private services only; false unless explicitly enabled with complete configuration |
| `CONSOLE_BROWSER_ENABLED` | Must not mount any gateway on the public auth process after isolation |
| `ENABLE_ADMIN_DASHBOARD` | false on public auth; optional security dashboard remains disabled for v1 |
| `ADMIN_BROWSER_ORIGIN` (private setting) | Exact `https://localhost:8443` |
| `ADMIN_WEBAUTHN_RP_ID` (private setting) | `localhost`; fixed configuration |
| `ADMIN_API_BASE_URL`, `ADMIN_INTROSPECTION_BASE_URL` (private setting) | Fixed private service origins; no redirects/arbitrary path/embedded credentials |
| `ADMIN_API_DATABASE_URL` (private setting) | New least-privilege product runtime; private API only |
| `ADMIN_AUTH_DATABASE_URL` (private setting) | Bounded auth/session/challenge capability; gateway only |
| `ADMIN_INTROSPECTION_SERVICE_SECRET` (private setting) | Independent random service secret, at least 32 bytes, retained/rotatable, never frontend |
| `CONSOLE_SESSION_ENCRYPTION_KEY` | Implemented canonical base64 32-byte server key; versioned read-key rotation/custody acceptance remains open |
| `ADMIN_TOKEN_LOOKUP_KEY` (private setting) | Separate keyed digest secret; independent of encryption key |
| `ADMIN_PROVISION_PRODUCT_DATABASE_URL` / `ADMIN_PROVISION_AUTH_DATABASE_URL` (private setting) | CLI-only provisioning context |
| Local TLS/SSH paths | Operator protected files/Keychain references, never GitHub Actions artifacts or source |
| `ADMIN_SMTP_HOST/PORT/USER/PASSWORD/FROM` | Implemented independent backend mail configuration and bounded sends; actual shared customer/provider quota coordination remains open |
| `ADMIN_SESSION_EPOCH` | Implemented external 32–128 character restore/session invalidation value; rotate outside restored state |
| `ADMIN_GATEWAY_DB_PASSWORD` / `ADMIN_API_DB_PASSWORD` | Optional maintenance-only provisioning of distinct runtime logins; never supplied to the browser |
| `ADMIN_PROVISION_ENV` / `ADMIN_PROVISION_APPROVED_TARGET_SHA256` | Explicit local/staging/production CLI target; hosted targets require independent fingerprint review |
| `ALLOW_TEST_OTP` | Never enables the private admin flow; false in hosted production/staging |
| Retention/expiry values | Enforce 120s challenges, 600s enrollment grant, 300s access/step-up, 900s idle, 8h absolute as specified above |

The private gateway uses the new bounded auth runtime configuration explicitly; it must not silently fall back to public auth's database-owner URL or the legacy console session credential. Missing admin settings stop only the affected private service. Customer services never initialize these private pools as part of ordinary startup/readiness.

Use existing secret-reference facilities and 0600 protected configuration; do not print resolved Compose configuration containing secrets into CI logs. Keep secret values, raw mail, OTPs, passkey challenges/responses, session cookies and bearer tokens out of test reports.

For v1, proposed admin limits are 5 sends per principal per 15 minutes, 20 login starts per source per 10 minutes, 5 verification attempts per challenge, and an explicit small global send cap shared with provider quotas. API limits: 120 requests/minute per principal, 20 mutations/minute, one expensive job per principal and two globally. Defaults must be verified against actual workflows, with a bounded Retry-After; proxy IP trust must be explicitly configured so spoofed forwarding headers cannot reset buckets.

## 7. Scale, reliability and customer-impact requirements

A million customers does not imply a million administrators. Keep management capacity independently bounded; do not add privileged lookups to every customer request.

- Sessions/challenges/revocation/buckets are durable and shared; no sticky-session or single-process correctness assumption. Verify races across two replicas and restarts.
- Budget admin DB pools explicitly, initially no more than three auth/session and two product connections per instance, subject to the existing whole-cluster connection-budget gate. Include replicas, rolling overlap, migrations, backups, workers and provider reserves; product/auth may share one physical cluster.
- Private admin services do not launch IMAP, rewards, notification or SMS-learning background workers by importing the existing public entrypoints. Extract side-effect-free factories/shared handlers first.
- Bound request/response sizes, concurrency, query time, page sizes (maximum 200 for v1), job counts, export sizes and audit retention. Dashboard queries must not scan all customer records synchronously. Use reviewed summaries/jobs and cancellation for costly work.
- Avoid broad locks or uncontrolled retries during migrations. Set measured lock/statement budgets on restored-data rehearsals; a timeout blocks rollout.
- Admin outage, tunnel outage, revoked device, shared-store outage or MFA outage must not take down public customer login/API readiness. The admin surface denies requests during its own dependency outage.
- Expensive mutations need atomic effect/audit/idempotency or an explicit reconciliation flow. No automatic repeat of a timed-out broadcast, publish or referral-control action.
- Observability records counts, latency, 401/403/429/503 rates, grant/revocation actions, backlog, challenge replay and unusual admin sessions. Alerts use approved operator channels. A host with no live admin service is not falsely marked healthy/secured.

## 8. Parallel Luna work packages

One coordinator owns the shared contract and final integration. Workers may work in isolated worktrees/copies if authorized, or in disjoint paths in a shared checkout. Only the coordinator commits/pushes integration to the user's current branch. Do not push additional branches. Resource limits permitting, run three workers at a time; expand concurrency only if file and test-database isolation remain explicit.

### Ownership and deliverables

| Package | Exclusive working area | Deliverables / acceptance |
| --- | --- | --- |
| A: database and safe provisioning | New auth/product migrations; `db/scripts/admin_access.js`; QA bootstrap restriction; `auth/scripts/admin*`; DB package tests | Capabilities, schemas, orphan-identity dry-run/reconciliation, idempotent grant/revoke, enrollment-grant custody; clean/upgrade/real-role tests |
| B: private authentication and sessions | New `auth/src/admin/`; existing `consoleBrowser*` / `consoleSessionStore*` files as coordinated; auth package tests | MFA enrollment/login/step-up, opaque token/introspection, durable sessions/limits, revocation/recovery, side-effect-free private server factory |
| C: private API and authorization | New `api/src/admin/`; extracted admin handler modules and API package tests | Complete route/permission manifest, admin-only auth middleware, current membership/permission checks, route extraction preserving business behavior |
| D: local console and UX | `console/lib/`, `console/web/`, console tests, local browser adapter/build tooling | Real MFA states, setup/target indicator, readonly UI, permission errors, source-safe logout, local WebAuthn adapter with no CDN |
| E: deployment and local launcher | New `scripts/admin_console/`, new local/private deployment templates and deploy tests | PC launcher, TLS/tunnel custody, private Compose profile, SSH hardening, explicit deployment/run/recovery runbook |
| F: independent security verification | New `tests/admin_console_security/` and `docs/admin-console-verification-*.md` | Cross-boundary negative, restart/replica, real-role, public-regression and external-exposure evidence; reviewer reports gaps, not self-certification |

Coordinator-only shared files: `api/src/index.js`, `auth/src/index.js`, root Compose files, `.env*.example`, dependency manifests/lockfiles, GitHub workflows, canonical migration-runner/release-check/connection-budget code, deployment runbook and the contracts directory. Workers request patches/registrations against these files; the coordinator applies them. No two workers claim the same existing file. If B needs shared OTP/delivery utilities, declare the exact files before dispatch; E does not independently edit B's gateway.

### Contract and dependency order

1. **Wave 0, coordinator:** re-read branch, route/function/RLS inventory, actual-data unknowns, agree reconciliation strategy, pin dependency/runtime versions, and write reviewed machine-readable `docs/admin-console-contracts/v1/` schemas for HTTP, permissions, configuration and repository interfaces. Freeze actor/session, OTP result, WebAuthn adapter and permission DTOs plus synthetic fixtures. Map all current admin routes before implementing extraction.
2. **Wave 1, A/B/C in parallel:** A implements storage/provisioning contracts; B and C use injected repositories/verification clients and synthetic contract fakes until A lands. No live credentials are required.
3. **Wave 2, D/E/F in parallel:** D consumes frozen HTTP fixtures; E packages explicit entrypoints; F writes independent boundary tests. Earlier workers address component defects only in their owned paths.
4. **Wave 3, coordinator:** integrate shared entrypoints/manifests, remove public/legacy admin admission, regenerate lockfiles, run combined verification and reconcile docs. Changes to a frozen interface invalidate dependent fixtures/tests and require re-review.
5. **Wave 4, operator/reviewer:** perform real target discovery, factor enrollment, restored-data rehearsal and approved private deployment; no software agent infers this authorization from successful unit tests.

Every package returns: exact changed paths, public interface changes, executed test commands/results, unresolved blockers and remaining live acceptance. No secret values or real financial messages in reports. A worker cannot mark the overall feature production-ready.

### Interfaces workers must share

Wave 0 turns these agreed boundaries into schema files and fixtures. Repository implementations may have internal helpers, but cross-package changes to these names/shapes require a contract revision.

| Boundary | Interface / invariants |
| --- | --- |
| Private auth app | `createAdminGatewayApp(dependencies)` returns an Express application without listening, loading `.env`, starting jobs or opening unrelated pools. The private server entrypoint alone manages its bounded runtime and shutdown. |
| Auth data access | Identity lookup, challenge creation/consumption, credential registration, session create/load/revoke and rate admission use injected repository methods. A supplies schema/routine contracts; B implements the repository adapter. Account lookup returns active/verified and pending/enabled state, never a login token. |
| Admin introspection client | `introspectAdminSession(token)` returns `{active:false}` or `{active:true, userId, sessionId, assurance:"email+webauthn-uv", mfaVerifiedAt, expiresAt}` from authority, or throws a typed unavailable error. No user-supplied role/email overrides. |
| Private API app | `createAdminApiApp({introspectAdminSession, loadPermissions, withAdminClient, handlers, routeManifest})` returns an app without listening/jobs. Every required security dependency is validated at construction. |
| Product entitlement | `loadPermissions(actor)` returns active state, stable principal ID, role, explicit permission set and version; all come from product authority. Missing/disabled account is denied. |
| Product operation context | `withAdminClient(actor, permission, operation)` uses the dedicated runtime, starts a bounded transaction and sets only verified actor/permission context. It never accepts an actor ID directly from a request body. |
| Browser WebAuthn adapter | `register(options)` and `authenticate(options)` wrap the maintained locally bundled browser library and return its JSON credential response. User cancellation is an error state, not a successful factor. |
| Provisioning plan | Target/state fingerprint, verified UUID, old membership/audit reference counts, intended role, reason and operation ID; no secrets. Apply revalidates its state preconditions and hash, then follows pending-to-enabled sequencing. |

Create versioned HTTP JSON Schemas, an OpenAPI description for the private routes, permission/route manifest, configuration schema and repository DTO schemas under `docs/admin-console-contracts/v1/` in Wave 0. Their fixtures must be synthetic and usable independently by A–F. Freeze exact OTP error/result and WebAuthn library adapter shapes before B and D proceed. The contract directory is coordinator-owned.

## 9. Verification matrix and test commands

Component tests belong beside their modules. Cross-boundary tests must boot actual app factories and reviewed built images; mocks/source scans alone cannot prove route isolation. All DB tests use explicitly disposable named test DBs with independent per-worker namespaces and deny non-test targets.

| Boundary / scenario | Required evidence |
| --- | --- |
| Public paths | Administrative, browser, introspection and optional security routes absent on public API/auth, including direct backend/provider URLs |
| Route variants | Case, trailing slash, encoded path, repeated slash, dot segment, HEAD/OPTIONS/method override and rewrite-header attempts cannot evade separation |
| Identity confusion | Ordinary customer token, spoofed role/email/assurance header, provisional cookie or network location cannot create an admin actor |
| Permission coverage | Every registered admin method/path has a manifest policy; unknown/missing guard denies startup; readonly cannot write |
| DB privileges | Actual public/worker roles cannot SET ROLE/inherit admin capability or activate it with custom GUCs; private runtime is non-owner and enforces permissions |
| OTP / enrollment | Real purpose-bound single-use proofs; unknown identity not enrolled; expired/reused/wrong-user enrollment grant denied; QA fixtures never accepted |
| WebAuthn | Origin/RP/purpose/UV/credential ownership/signature/challenge mismatches denied; success verified with virtual and actual approved authenticators |
| Replica races | Parallel challenge/grant consumption succeeds once; revocation applies across replicas/restart; quotas remain shared |
| Sessions | Idle/absolute/token/step-up limits, rotation races, logout, disabled account/membership and recovered-factor revocation behave as specified |
| Gateway | CSRF, Host/Origin, fixed upstream, redirect refusal, payload limits, TLS verification and no secret in response/storage/log |
| Provisioning | Identity mismatch dry-run, unique email/audit preservation, duplicate invocation and crash after each store commit fail closed |
| Mutation correctness | Lost response/timeout/duplicate action cannot silently repeat a high-impact effect; audit and outcome remain attributable |
| Network | LAN and independent external machine cannot reach UI/admin paths; IPv4/IPv6/provider origin/direct container paths tested; tunnel key revocation works |
| Customer compatibility | Existing OTP, account recovery, catalogue, sync, SMS import and representative user writes continue to function; admin sessions cannot be used as customer sessions |
| Resource behavior | Public latency/error rates, DB connections/locks, admin query/page limits and shared provider budgets remain within reviewed limits under representative load |
| Recovery | Lost PC/key, backup factor, credential rotation, restored DB/session state, stale grant and deactivated test actor cannot re-enable unintended access |

Existing baseline commands, run in their respective directories after adding new tests:

~~~
(cd auth && npm test)
(cd api && npm test)
(cd console && flutter analyze --no-fatal-infos)
(cd console && flutter test)
node --test db/tests/release_security_check.test.js db/tests/release_secret_audit.test.js db/tests/release_dependency_inventory.test.js
python3 -m unittest discover -s deploy/tests
~~~

Add focused `node --test` files for each new auth/API module before broader checks. Integrate real PostgreSQL tests with canonical migration runners using disposable databases. Run the existing console-browser/current-session/provider tests as regressions. Extend the release checker/connection-budget input schema with exact-candidate admin acceptance; unknown/off flags preserve customer compatibility, while enabled admin services require all new proofs.

Final evidence records commit SHA, source/image hashes, nonsecret config digest, migration ledger, test results, target/provider identifiers, role/pool inventory and external network observations. Redact usernames/hosts where disclosure is unnecessary. Missing hardware/network/live-data acceptance remains a named blocking gate, not a successful placeholder.

## 10. Release, rollback and operational runbook

### What is deployed where, and in what order

1. **Development:** implement on the current branch; use synthetic accounts, isolated DBs and virtual authenticators. Build a local release bundle and private backend images. Keep all live admin flags off.
2. **Target rehearsal:** independently confirm compute, private transport, TLS, SSH host keys, supported runtime/engine, direct-origin closure, DB-role mapping, connection capacity, paired backup and tested restore. Use a restored/sanitized clone for migrations and identity reconciliation.
3. **Database preparation:** apply new additive auth/product migrations and bounded roles with canonical runners. Do not grant a live operator yet. Never put migration/DB-owner credentials into runtime containers.
4. **Routing/customer rollout:** release the reviewed public API/auth images with administrative handlers removed/denied, retaining customer routes and supported-client semantics. Enforce equivalent edge/direct-origin restrictions. This removes any legacy public admin path.
5. **Private backend rollout:** deploy gateway and private admin API images with exact entrypoints, separate credentials, admin-only network and loopback mapping. They may start unenabled/unprovisioned and deny access. No dashboard files are deployed here.
6. **PC install:** place the exact reviewed console bundle/proxy/launcher on the operator PC, install local trust explicitly, configure SSH device identity and start the loopback listener. No public static hosting or external frontend assets.
7. **Account enrollment:** verify the intended email in the actual target, preview/reconcile membership IDs with audit preservation, grant the minimal intended role, and enroll/test primary plus backup factor. Disable test memberships/challenges and revoke their existing sessions.
8. **Acceptance/activation:** run public-denial, real-user permission, hardware-factor, customer-regression and resource acceptance against the exact deployment. Activate only with an accountable operator's explicit approval and an independent review of the evidence.
9. **Operations:** document start/stop, target selection, admin deactivation, session/device revocation, factor loss, key/certificate rotation, upgrade, monitoring ownership and periodic access review.

The existing GitHub production workflow is pinned to reviewed/tested master commits. Current-branch pushes publish source only. Preparing this feature must not turn those pushes into a deployment trigger; a future approved promotion must use the existing safeguards.

### Required deployment artifacts and operator commands

These source artifacts and commands are now delivered. They require reviewed local dependencies and explicit target configuration; their presence is not proof of installed trust, running services or live acceptance:

| Artifact | Responsibility |
| --- | --- |
| `deploy/admin/compose.private.yml` | Opt-in `admin` profile defining `admin-gateway`, `admin-api`, private networks, secret references, bounds, health checks and explicit entrypoints. The coordinator integrates it with the existing production Compose file. |
| `deploy/nginx/console.localhost.conf.example` | PC-only TLS/static/proxy configuration; no public listener or remote frontend assets. |
| `deploy/admin/sshd-forwarding.conf.example` | Restricted forwarding-only account settings, with configuration validation and a safe host-access rollback procedure. |
| `scripts/admin_console/install.sh` | Build/verify/copy the reviewed bundle and local configuration with restricted permissions. Missing trusted dependencies stop with instructions; no silent sudo, firewall change or root-CA installation. |
| `scripts/admin_console/start.sh --target TARGET --config PATH` | Read protected operator configuration, verify target/origin/trust/bundle version, acquire its process lock, start tunnel/proxy, verify private readiness and open the loopback page. |
| `scripts/admin_console/status.sh` / `stop.sh` | Show credential-free target/readiness; stop only owned processes and remove temporary material. |
| `db/scripts/admin_access.js` | Inspect/plan, grant/reconcile/revoke, primary/backup enrollment grants and final enable with plan-hash/state checks. |
| `deploy/admin/RUNBOOK.md` | Delivered command/runbook template. Installed versions, actual topology, secret references and operational acceptance must be completed from verified target facts. |

The integration verification should build the auth/API images at the exact candidate, test explicit private entrypoints and validate the merged Compose topology before any deployment. The `admin` profile never publishes 4001, never publishes 4321 on all interfaces and never attaches admin services to a broad worker network. Public proxy configs cannot route to the private services. Test both IPv4 and IPv6.

Build the console using the supported Flutter release flags already documented by the repository (`--release --csp --no-web-resources-cdn`) and the new explicit admin-protocol setting. Keep its MFA adapter/assets local. Do not upload the bundle to a public release/artifact location as a substitute for installation on the PC. CI can build with synthetic settings for verification and discard the result.

### Rollback rules

- The first response to an admin incident is disable private admin admission, close its tunnel/ingress and revoke affected sessions/device keys. Public customer services should continue.
- Roll back the private components and local bundle to a compatible reviewed version, with the gateway remaining disabled if any contract is incompatible.
- Never restore a legacy public admin mount, fixed-code login or broad DB grants to make rollback appear functional.
- Retain additive tables/audit records until a separately reviewed cleanup. Do not undo revocation or identity reconciliation by blindly restoring old credentials/sessions.
- A paired database restore must reapply retained revocation/recovery state before reopening admin access. Restoring a snapshot is not permission to resurrect a retired test owner.
- Extend the restore procedure so private admin admission stays disabled by default after restore. Rotate the externally retained recovery/session epoch, invalidate restored sessions/grants, and reconcile memberships/factor revocations against retained operator records before re-enabling. A session-epoch value stored only inside the restored snapshot cannot establish freshness; the restore test must include an old formerly valid admin session/factor/grant.
- Roll forward fixes when possible; retain explicit code/schema/config compatibility and a tested previous customer release.

## 11. Implementation and activation checklists

### Implemented source foundation

- [x] Existing console reused with private email/WebAuthn login, enrollment, step-up and server logout; local browser assets bundled.
- [x] Private auth/API entrypoints and 92-route policy manifest delivered; public ingress denies administrative paths and customer tokens cannot establish admin authority.
- [x] Durable challenge/session/rate state, CSRF, opaque introspection, expiry, revocation and restore epoch implemented and covered by local protocol tests.
- [x] Forward migrations and explicit private runtime capabilities delivered; clean/repeat full-schema and representative permission/write checks pass.
- [x] Provisioning CLI delivers reviewed target preview/apply, pending enrollment, primary/backup grants, enable and revoke; legacy static QA minting retired.
- [x] PC-only launcher, TLS/SSH/Compose templates, operator commands and verification report delivered.
- [x] Component suites, Flutter analysis/release build and disposable PostgreSQL protocol/schema checks recorded in the verification report.

### Remaining source implementation

- [ ] Every mutation, DB routine/owner and role combination accepted; durable high-impact dispatch/audit/idempotency complete.
- [ ] Provisioning operation/resume state and session/factor/key-rotation/recovery races complete.
- [ ] Pagination, expensive-job concurrency, shared provider/connection budgets, retention and operational monitoring complete.
- [ ] Permission-aware UI, remaining machine-readable contracts and exact-candidate release evidence complete.

### Local owner and deployment acceptance

- [ ] Local auth account for the requested owner exists and its email has been normally verified.
- [ ] Local schemas/migration history accepted; old orphan membership reconciled without moving audit attribution.
- [ ] Separate primary/backup factors enrolled and tested; final enable performed for the verified local UUID.
- [ ] Target-specific owners/grants, installed local trust, private network, images and external/LAN denial accepted.
- [ ] Restored-data, replica/race, customer/resource regressions and independent security review pass.
- [ ] Test grants retired; revoke/rollback/recovery rehearsed and accountable operator approves activation.

Report the exact state: **source foundation implemented; remaining implementation and activation pending**. The local owner is requested but not yet provisioned. Neither a localhost dashboard nor a large user count establishes security by itself.
