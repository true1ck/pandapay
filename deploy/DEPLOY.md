# Deploying api/ and auth/

Docker-based, works on any Linux VM with Docker installed — Oracle Cloud,
Lightsail, a bare-metal box, whatever ends up hosting this. Nothing below is
vendor-specific; the only Oracle Cloud step is provisioning the VM itself
(step 1).

This supersedes nothing that already exists: `auth/QUICK_DEPLOY.md` documents
a different, older path (PM2 + a bare Node process, no Docker) for `auth/`
alone. This guide is the one to follow for a fresh deploy of both services
together.

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

Live-verified end to end (full migration chain, `app_user` creation, a real
`api/` request, a real `auth/` OTP write) against a real Supabase free
project — see `.env.prod.example`'s Database section for the exact gotchas
(session pooler required for IPv4, `<role>.<project-ref>` username format,
free tier's 2-active-project cap — solved here by putting both databases in
ONE project via `CREATE DATABASE pandapay_auth;` rather than two projects).
Free tier has no automated backups, so `docker-compose.prod.yml`'s `backup`
service isn't optional in this setup — it's the only backup that exists.

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
generate each value (JWT secrets, `APP_USER_PASSWORD`, webhook secrets,
`IMAP_ENCRYPTION_KEY`, `ENCRYPTION_KEY`). Don't confuse the last two:
`IMAP_ENCRYPTION_KEY` is `api/`'s key for stored IMAP app passwords;
`ENCRYPTION_KEY` is `auth/`'s separate key for field-level PII encryption —
both are required, and leaving `ENCRYPTION_KEY` unset doesn't fail the
deploy, it just makes auth/ silently store that PII unencrypted (a stderr
warning, nothing else), which is why `docker-compose.prod.yml` requires it
with `:?` rather than defaulting it. `JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET`
**must** be
the same values `api/` and `auth/` both read — the compose file already wires
one value to both services, just don't hand-edit them differently later.

`ADMIN_DATABASE_URL` is the superuser connection to your Postgres instance;
`API_DATABASE_URL`/`AUTH_DATABASE_URL` are filled in with the `app_user`
role and `pandapay`/`pandapay_auth` database names that the migration step
below creates.

## 4. Run migrations

```bash
docker compose -f docker-compose.prod.yml --env-file .env run --rm db-migrate
```

This creates the `app_user` role (with the password from `.env`, not the dev
literal — `db/scripts/migrate.sh` refuses to run without
`APP_USER_PASSWORD` set), applies every migration in order, and skips
`0013_cron_jobs.sql` (pg_cron isn't available unless your managed Postgres
offers it — apply that one by hand if it does). Re-run this any time you pull
a commit with new migrations; it's ledgered and only applies what's new.

## 5. Bring up the stack

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d --build
docker compose -f docker-compose.prod.yml ps
```

`api`/`auth` bind to `127.0.0.1` only — nginx is the only way in from
outside the VM. `backup` starts running the nightly/weekly schedule
immediately (`db/backup/crontab`); check it landed a row after the first
night:

```bash
docker compose -f docker-compose.prod.yml exec backup crontab -l
```

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

```bash
git pull
docker compose -f docker-compose.prod.yml --env-file .env run --rm db-migrate
docker compose -f docker-compose.prod.yml --env-file .env up -d --build
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
