# Deploying api/ and auth/

## Security foundation deployment requirements — 22 October 2026

The current security batch requires paired encrypted product/auth backups
before deployment. Follow [backup/recovery setup](../db/backup/README.md) and
[reviewed legacy migration baselines](migration-baselines/README.md) before
deploying it to an existing database. Configure public age recipients, two
independent off-host mounted destinations, separately held recovery identities,
the hosted PostgreSQL client major and verified database CA trust. Existing
encryption, HMAC and session keys must be retained exactly across rehosting.

Restore the deployed data and retained keys on an independent PostgreSQL host
and review its schema/history baseline before adopting legacy checksums. The
local synthetic rehearsal does not replace that release gate. All services
still use PostgreSQL; the destination hosting provider may change.

Database TLS now verifies certificates/hostnames. Use system trust or supply an
additional public PEM CA with `DB_SSL_CA` (native tools also accept
`DB_SSL_CA_FILE`). Production/staging cannot use `DB_SSL=false`. Required field
encryption cannot silently disable itself when the key is missing or invalid.

`deploy/deploy.sh` builds the target service and migration images from the
reviewed commit in a temporary directory before downtime. It then stops API,
auth, the rewards worker, and the optional Gemini and SMS-learning workers to
fence database writes, and verifies the paired encrypted copies before replacing working
source or starting migrations. The default bounded maintenance window is 30 minutes;
set `DEPLOY_MAINTENANCE_WINDOW_SECONDS` to 300–7200 seconds when a reviewed
backup or migration needs a different limit. If backup fails before source
replacement, the script attempts to resume the original stopped containers by
ID, even though target image tags have already been built. If source
replacement or migration fails, writer services remain stopped so old auth
cannot run against the new schema; resolve the failure and deploy forward.
The scheduled production container holds public recipients only. Restore
drills run on the separate recovery host with explicit `RESTORE_*` URLs and a
private identity.

The release gate requires the tested commit to equal the current `master` tip
at dispatch and again on the host immediately before any image build. The host
also requires that target to descend from its existing Git `HEAD`; stale
workflow runs, rollbacks, divergent history, and a copied checkout without a
verifiable `HEAD` are blocked before downtime. Reconcile the source history to
a reviewed commit before using the automated upgrade path.

The deployment preflight inventories containers carrying the exact
`pandapay-prod` Compose project label and requires a known service label before
fencing. The retired `maps-scraper` container is allowed only under that exact
project/service identity because its reviewed source is a stateless scraper
with no database configuration; this rollout leaves it running. Unknown or
unlabeled project containers stop the release before downtime. The optional
`sms-learning-worker` remains a database writer: deployments fence it even
when its opt-in configuration is blank, and restart it only when its dedicated
database URL, HMAC key, and bootstrap password are all configured.

Docker-based, works on any Linux VM with Docker installed — Oracle Cloud,
Lightsail, a bare-metal box, whatever ends up hosting this. Nothing below is
vendor-specific; the only Oracle Cloud step is provisioning the VM itself
(step 1).

Use this combined guide and the reviewed security rollout runbook for this
release. `auth/QUICK_DEPLOY.md` and `auth/DEPLOYMENT_GUIDE.md` describe the
historical standalone PM2 service; they do not perform the required paired
backup, writer fence or coordinated migrations.

## 0. What you need before starting

- A Postgres instance reachable from the VM — either managed (has automated
  backups/PITR built in, which is the stronger guarantee) or self-hosted on
  the same VM. Either way you need a **superuser-equivalent connection
  string** to it. `docker-compose.yml` (local dev) is not this — that's a
  disposable container, not a target for real data.
- A domain (or subdomain pair) you control, e.g. `api.yourapp.com` and
  `auth.yourapp.com`, with DNS you can edit.
- This repo cloned onto the VM.

### Using Supabase's free tier for Postgres

The existing deployment uses both databases in one Supabase project and the
session pooler for IPv4. See `.env.prod.example` for connection details and
`<role>.<project-ref>` usernames. Historical live API/auth verification is not
acceptance evidence for this security branch. Its current read-only live
checks and disposable full-data restore/upgrade results are recorded in the
[progress report](../docs/security-implementation-progress-2026-10-22.md).
Confirm current provider quotas and backup entitlements before release.
Keep the reviewed encrypted backup service configured; the owner's temporary
PC recovery copy does not satisfy the independent off-host deployment gate.

## 1. Provision the VM

Any Docker-capable Linux VM works. On Oracle Cloud: create a Compute
instance (Ubuntu 22.04+), attach a public IP, open ports 80/443/22 in the
instance's security list/NSG (Oracle Cloud's firewall is enforced at the
cloud level, in addition to any `ufw`/`iptables` on the box itself — both
need the ports open or nothing gets through).

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # log out/in after this
sudo apt install -y nginx certbot python3-certbot-nginx
```

## 2. DNS

Point both `api.yourapp.com` and `auth.yourapp.com` A records at the VM's
public IP.

## 3. Clone and configure secrets

```bash
git clone <this-repo-url> pandapay && cd pandapay
cp .env.prod.example .env
```

Fill in every `CHANGE_ME` in `.env` — the file itself documents how to
generate each value (JWT secrets, the stable `PHONE_LOOKUP_HMAC_KEY`,
`APP_USER_PASSWORD`, the separate
`REWARD_WORKER_DB_PASSWORD`, webhook secrets,
`IMAP_ENCRYPTION_KEY`, `ENCRYPTION_KEY`). Don't confuse the last two:
`IMAP_ENCRYPTION_KEY` is `api/`'s key for stored IMAP app passwords;
`ENCRYPTION_KEY` is `auth/`'s separate key for field-level PII encryption —
both are required. Auth startup rejects missing, malformed or disabled
encryption in production/staging; Compose also requires the key with `:?`.
`JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET`
**must** be
the same values `api/` and `auth/` both read — the compose file already wires
one value to both services, just don't hand-edit them differently later.

`ADMIN_DATABASE_URL` is the privileged connection to your Postgres instance;
`API_DATABASE_URL` uses `app_user`, while `REWARD_WORKER_DATABASE_URL` uses
the separate `rewards_worker_login`. Both target `pandapay`; only the latter
can assume the narrow worker role. `AUTH_DATABASE_URL` targets the separate
`pandapay_auth` database.

Autonomous SMS learning is opt-in. Leave `SMS_LEARNING_WORKER_DB_PASSWORD`,
`SMS_LEARNING_DATABASE_URL`, and `SMS_LEARNING_HMAC_KEY` blank (all three —
the deploy script enforces the pairing) and no `sms_learning_worker` login is
bootstrapped at all. When enabling the worker, set
`SMS_LEARNING_DATABASE_URL` to the `sms_learning_worker` login that
`SMS_LEARNING_WORKER_DB_PASSWORD` bootstraps with a distinct generated
password; never reuse `API_DATABASE_URL`. The worker startup check rejects
`app_user`, superuser names, and incomplete grants before it attempts a cycle.

For JWT rotation, set `JWT_KEYS_JSON` and `JWT_ACTIVE_KEY_ID` together. The
same key set, active key id, `JWT_ISSUER`, and `JWT_AUDIENCE` must be supplied
to both services. The containers now fail at startup if the JSON is malformed
or the active key id is absent, which prevents a partial deployment from
minting tokens that the API cannot verify. Keep the previous key in the set
until all existing access tokens have expired, then remove it in a later
deployment.

Keep `PHONE_LOOKUP_HMAC_KEY` in the production host `.env` and keep it stable.
The deploy workflow validates that it is present and sufficiently long, but
does not read, replace, or transmit it through GitHub Actions. Changing this
key changes phone-search hashes and requires an explicit reindex.

### Optional Gemini SMS classification worker

Gemini remains disabled until an operator configures both `AI_WORKER_TOKEN`
(a random secret of at least 32 characters) and `GEMINI_API_KEY` in the
host-only `.env`. Keep the Gemini key server-side; it is consumed only by the
isolated worker container. Set both entries blank to disable the integration.
The deploy script rejects a one-sided configuration, does not print either
value, and stops an already-running worker when the integration is disabled.

The worker credentials are only a transport/call gate. Message acceptance is
also fail-closed on the API feature flag `sms_ai_queue_enabled`; an absent row
means **disabled**. First deploy migrations and the API/worker with credentials
present, verify the AI Operations dashboard, quotas, queue age, retries, and
provider-capacity wait counters, then start with a small deterministic rollout
through an audited privileged database session:

```sql
insert into public.feature_flags (key, is_enabled, rollout_percent, description)
values ('sms_ai_queue_enabled', true, 1, 'Gemini SMS classification pilot')
on conflict (key) do update set
  is_enabled = excluded.is_enabled,
  rollout_percent = excluded.rollout_percent,
  description = excluded.description,
  updated_at = now();
```

Increase to 5%, then 25%, then 100% only after observing stable queue age,
valid result rates, 429/retry counts, cost/quota use, and no regressions in
Needs Review or existing transaction/bill/balance/card flows. Roll back
immediately by setting `is_enabled = false, rollout_percent = 0`; accepted
jobs remain durable and can be drained or failed deliberately. Keep user
contribution learning independently governed by `profiles.contributions_opt_in`
(off by default). This change does not make AI analysis mandatory for SMS
ingestion: local detection and review continue when the queue flag is off.

## 4. Run migrations

Applying auth migrations while an old auth process is serving requests is
unsafe: it can create OTP rows without purpose binding or phone lookup hashes.
Fence both API and auth writes first, then take the final paired backup, run
migrations, and start only the new service images. The `deploy/deploy.sh`
workflow performs this order automatically and preserves the backup-before-
source-replacement gate. Use the manual sequence below only for a first
install with no old service processes to resume. For upgrades to an existing
deployment, use `deploy/deploy.sh`; it preserves stopped container IDs and
handles failure before/after source replacement differently. Build all target
images before the manual window, then run the remaining sequence under one
bounded 30-minute window:

```bash
docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml --env-file .env build api auth rewards-worker backup db-migrate gemini-worker sms-learning-worker
timeout --foreground 1800s bash -euo pipefail -c '
  docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml --env-file .env stop --timeout 30 auth api rewards-worker gemini-worker sms-learning-worker
  docker compose -f docker-compose.prod.yml --env-file .env run --rm --no-deps backup /backup/backup.sh
  docker compose -f docker-compose.prod.yml --env-file .env run --rm db-migrate
  DEPLOY_IMAGES_PREBUILT=1 bash deploy/restart-services.sh
'
```

Continue past the backup only after it confirms both copies. A timeout or
migration error ends the sequence without starting services. Do not start old
images after a migration failure; fix the migration/configuration issue and
rerun the forward migration path from the same or a later reviewed commit.

This applies the product and separate auth database migration ledgers. The
auth migration connection must have DDL privileges on `pandapay_auth`; the
example uses the project's `postgres` role. It also creates the `app_user`
and isolated rewards-worker and SMS-learning login roles using the distinct
passwords from `.env` (`db/scripts/migrate.sh` refuses to run without all
three runtime-role passwords), and
skips
`0013_cron_jobs.sql` (pg_cron isn't available unless your managed Postgres
offers it — apply that one by hand if it does). Re-run this any time you pull
a commit with new migrations; it's ledgered and only applies what's new.

By default, `AUTH_DATABASE_URL` is also the migration principal, and no new
auth-table grants are issued. If the auth service uses a different restricted
database role, set `AUTH_RUNTIME_ROLE` to that exact existing PostgreSQL role
name (not its URL-encoded username). The migration grants only `SELECT`,
`INSERT`, `UPDATE`, and `DELETE` on `public.auth_abuse_buckets`; it does not
grant schema-wide access. Migration and auth readiness both verify that role's
required permissions. If unset, pre-existing grants must already permit the
runtime role to use the bucket table.

## 5. Bring up the stack

On the 1 GB production VM, build and restart services sequentially. The helper
builds each image before replacing any containers, then waits for auth, API,
rewards worker, and backup readiness in that order. A failed readiness check
stops the rollout before the next service is replaced.

```bash
docker compose -f docker-compose.prod.yml --env-file .env ps
```

`api`/`auth` bind to `127.0.0.1` only — nginx is the only way in from
outside the VM. Both services trust exactly one proxy hop, and the supplied
Nginx configs replace `X-Forwarded-For` with the peer address they observed.
If a CDN or load balancer is added in front of Nginx, configure and review that
full proxy chain explicitly before changing the trust depth. `backup` runs the daily paired backup at 02:15 UTC
(`db/backup/crontab`); check its completion marker after the first
night:

```bash
docker compose -f docker-compose.prod.yml exec backup crontab -l
```

The automated production smoke checks verify API/auth readiness and that
protected API and auth routes reject anonymous requests. They do not create a
synthetic account, mint a fake protected token, or call nearby-discovery
providers. An authorized supported-client smoke remains a release gate: verify
sign-in, refresh/session continuity, and the currently supported authenticated
read/write/sync flows with an authorized account before declaring the release
accepted. This is the compatibility check for real client behavior and older
supported app versions.

The `rewards-worker` service runs separately from the API. It claims outbox
events with bounded leases, records attempt history and heartbeats, retries
transient failures, and expires unqualified reservations only after the signed
receipt grace period. It does not pay cash or redeem subscription benefits.
Check liveness and backlog with an administrator/read-only operations
connection (not the app or worker login):

```sql
select worker_id, heartbeat_at, now() - heartbeat_at as heartbeat_age,
       polls, claimed_events, completed_events, last_error_code
  from promotions.reward_worker_heartbeats
 order by heartbeat_at desc;

select state, count(*) as events,
       min(available_at) filter (where state = 'pending') as oldest_pending
  from promotions.reward_outbox
 group by state order by state;
```

Set alert thresholds from staging observations for missing heartbeats, aged
pending work, and dead/expired events. Those operational tables are not
readable by either the API app login or the worker login.

The authenticated admin console's **Referral Operations** page reads the
privacy-safe status RPC and offers four reason-required emergency holds:
admission, enrollment, fulfillment, and credit redemption. Each action is
admin-gated by the API and appended to the referral operator audit log. A
release restores the exact switch value captured when the hold was applied;
it does not delete an earned entitlement or modify a spin/credit ledger.
There is deliberately no console control here for changing prize odds,
budgets, or subscription benefits. Keep redemption paused until a reviewed
platform benefit is actually configured and sandbox-verified.

## 6. nginx + TLS

```bash
# Shared by both site configs below — defines $req_id (the client's
# X-Request-Id when sent, a fresh one otherwise). Must be installed first:
# both site configs reference $req_id and nginx -t fails on an undefined
# variable.
sudo cp deploy/nginx/request-id-map.conf.example /etc/nginx/conf.d/request-id-map.conf
sudo cp deploy/nginx/api.conf.example /etc/nginx/sites-available/api.yourapp.com
sudo cp deploy/nginx/auth.conf.example /etc/nginx/sites-available/auth.yourapp.com
# edit both: replace api.your-domain.example / auth.your-domain.example
# with your real domains
sudo ln -s /etc/nginx/sites-available/api.yourapp.com /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/auth.yourapp.com /etc/nginx/sites-enabled/
sudo nginx -t   # will complain about missing certs — expected before certbot
sudo certbot --nginx -d api.yourapp.com -d auth.yourapp.com
sudo systemctl reload nginx

# Privacy policy / terms — served as static files, not through api/'s
# container, so they're up even if the app is down. Needed for Play
# Console's Privacy Policy URL field.
sudo mkdir -p /var/www/pandapay-legal
sudo cp deploy/legal/*.html /var/www/pandapay-legal/
```

## 7. Firewall

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

## 8. Verify

```bash
curl https://api.yourapp.com/health
# Liveness is process-only; readiness must be green before serving traffic.
curl https://api.yourapp.com/ready
curl -i https://auth.yourapp.com/   # any response, not a connection failure
```

## 9. Point the app at it

Build the Flutter app with the real hosts (see `app/lib/app/env.dart` —
release builds refuse to start pointed at localhost) using
`scripts/build_app.sh`, not a raw `flutter build` command — the script ties
`--flavor` and the three `--dart-define`s to one argument so they can't
independently drift (a code review flagged that four separately-typed flags
made it possible to build a `dev`-flavored release pointed at the real prod
API with no warning at build or runtime):

```bash
PANDAPAY_API_BASE_URL=https://api.yourapp.com \
PANDAPAY_AUTH_BASE_URL=https://auth.yourapp.com \
scripts/build_app.sh prod --release
```

(needs the Android product flavors — see
`app/android/app/build.gradle.kts`. On iOS there's no equivalent flavor/scheme
set up yet; that's a manual Xcode step — Product → Scheme → New Scheme, or
duplicate the existing `Runner` scheme per environment — deliberately not
done via blind edits to `project.pbxproj` here, same treatment this plan
gives the App Store Connect listing itself: an owner action, not a code
change.)

## Updating a running deploy

Do not `git pull`, run `db-migrate`, then start Compose manually: that leaves
old writers running across the schema update and breaks the backup-before-
source-replacement gate. Upgrade with the reviewed commit SHA through the
deployment script, which builds the target images before downtime, fences all
writers, takes the final paired backup, migrates, and starts only the target
images:

```bash
bash deploy/deploy.sh <reviewed-commit-sha>
```

## What this does NOT cover

- **Staging.** See `docker-compose.staging.yml` / `.env.staging.example` —
  same steps, different compose file, before touching this prod flow.
- **CI-built images.** `.github/workflows/build-and-test.yml`'s `images` job
  pushes to `ghcr.io/<org>/pandapay-api` and `ghcr.io/<org>/pandapay-auth` on
  every push to `master`. Once the VM is up you can switch step 5 to `docker
  compose pull && docker compose up -d` against those instead of building
  on-box, which is faster and means the image running in prod is exactly the
  one CI tested — that swap isn't wired up yet since it needs the actual
  image names decided.
- **Zero-downtime deploys / rolling restarts.** `docker compose up -d
  --build` briefly drops connections during a deploy. Fine for now; a
  blue-green or rolling setup is future work once traffic justifies it.
- **Monitoring dashboards / alerting.** `api/` and `auth/` both emit
  structured JSON logs (`api/src/observability.js`,
  `auth/src/observability.js`) to stdout/stderr, which `docker compose logs`
  reads and which any hosted log platform ingests without extra config —
  shipping them somewhere and alerting on them is still an owner decision,
  deliberately not a vendor SDK baked into the code (see
  `api/src/observability.js`'s header for why, particularly the DPDP
  PII-review angle for a payments app).
