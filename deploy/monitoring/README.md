# Monitoring and error reporting

How PandaPay finds out about crashes, failing requests, slow responses and a sick server before users tell us. The reasoning and tool choices are in [the admin plan, section 8](../../docs/admin-console-plan-2026-11-05.md).

```
 App VM (production)                                   Monitoring VM (separate, private)
 ┌───────────────────────────────┐   Tailscale (private)  ┌────────────────────────────────────┐
 │ api ──:9464/metrics─┐         │  remote write :9090    │ Prometheus ──> Alertmanager ──> Telegram
 │ auth ─:9465/metrics─┤ metrics-agent ────────────────────▶            │                       │
 │ node-exporter ──────┘         │                        │ Grafana (dashboards)               │
 │                               │                        │ Uptime Kuma (is it up?)            │
 │ api/auth error reports ───────┼── HTTPS ──────────────▶│ Caddy ─(ingest only)─> GlitchTip   │
 └───────────────────────────────┘   errors.pandapath.live └────────────────────────────────────┘
 Phones (later) send crash reports to the same public ingest address.
```

## What stays private, and why it is safe

- **No personal data leaves the services.** Error reports carry only the error type, an allow-listed code, code locations and the route template (`/transactions/:id`), never the message, body, query string, headers, user id or IP. See `api/src/telemetry.js` and its tests.
- **Metrics ports are never published.** API (9464) and auth (9465) metrics listen inside the Docker network only; the public app has no `/metrics` route.
- **Every UI is private.** GlitchTip, Grafana, Uptime Kuma and Prometheus bind to the monitoring VM's Tailscale address. The only public port is Caddy, which forwards `POST /api/<project>/envelope/` (event ingestion) and answers 404 to everything else, including the GlitchTip login page.
- **No self-sign-up.** GlitchTip registration and organisation creation are off; Grafana sign-up and anonymous access are off.
- **Monitoring is off until configured.** Without the settings below, the services behave exactly as before.

## 1. Monitoring VM (one time)

1. Create a small Linux VM (2 vCPU, 4 GB RAM is enough; Oracle's free ARM tier may cover it). Open only ports 80 and 443 to the internet, and 22 to your IP.
2. Install Docker and [Tailscale](https://tailscale.com/download) on it and on the app VM, and join both to the same tailnet. Note the monitoring VM's address with `tailscale ip -4`.
3. Point `errors.pandapath.live` (A record) at the monitoring VM's public IP.
4. Copy this `deploy/monitoring` folder to `/opt/pandapay-monitoring` on the VM. In that folder:
   ```sh
   cp monitoring.env.example .env && chmod 600 .env     # fill in every value
   cp alertmanager/alertmanager.example.yml alertmanager/alertmanager.yml
   mkdir -p alertmanager/secrets && chmod 700 alertmanager/secrets
   printf '%s' 'YOUR_TELEGRAM_BOT_TOKEN' > alertmanager/secrets/telegram_bot_token
   chmod 600 alertmanager/secrets/telegram_bot_token     # then set chat_id in alertmanager.yml
   docker compose -f compose.monitoring.yml up -d
   ```
   Telegram: create a bot with @BotFather, add it to a private group, and read the group's chat id from `https://api.telegram.org/bot<TOKEN>/getUpdates` after posting a message.
5. Create the GlitchTip owner account (registration is off, so this is the only way in):
   ```sh
   docker compose -f compose.monitoring.yml exec glitchtip ./manage.py createsuperuser
   ```
6. Open `http://<tailscale-ip>:8000`, sign in, enable two-factor authentication, create an organisation and three projects: `pandapay-api`, `pandapay-auth`, `pandapay-app`. In the organisation and each project, turn on **Scrub IP addresses** (phones' IPs must not be stored), set a rate limit (for example 100 events per minute), and copy the project's DSN.
7. Open Grafana at `http://<tailscale-ip>:3000` (user `admin`). The **PandaPay overview** dashboard is preinstalled. Change the admin password if you used a temporary one.
8. Open Uptime Kuma at `http://<tailscale-ip>:3001`, create the owner account, and add these monitors, with Telegram as the notification channel:

   | Monitor | Type | Target |
   | --- | --- | --- |
   | Customer API | HTTP(s) | `https://api.pandapath.live/ready` |
   | Auth | HTTP(s) | `https://auth.pandapath.live/ready` |
   | Error ingestion | TCP port | `errors.pandapath.live:443` |
   | Grafana | HTTP(s) | `http://grafana:3000/api/health` |

## 2. App VM

1. Add to the production `.env` (each DSN from step 6; the ports stay inside Docker):
   ```sh
   API_METRICS_PORT=9464
   AUTH_METRICS_PORT=9465
   API_ERROR_REPORTING_DSN=https://<key>@errors.pandapath.live/<api-project-id>
   AUTH_ERROR_REPORTING_DSN=https://<key>@errors.pandapath.live/<auth-project-id>
   ```
   The next deploy picks them up (or restart `api` and `auth`). Deploys also tag every report and metric with the commit (`PANDAPAY_GIT_SHA`).
2. Start the agent, as its own Compose project so deploy.sh's service check is unaffected:
   ```sh
   sudo mkdir -p /etc/pandapay/monitoring
   sudo cp deploy/monitoring/prometheus/agent.example.yml /etc/pandapay/monitoring/agent.yml
   sudo sed -i "s/MONITORING_TAILSCALE_IP/<monitoring-vm-tailscale-ip>/" /etc/pandapay/monitoring/agent.yml
   MONITORING_AGENT_CONFIG=/etc/pandapay/monitoring/agent.yml \
     docker compose -f deploy/monitoring/compose.app-agent.yml up -d
   ```
   Keep `agent.yml` outside the repo: deploy.sh runs `git clean`, which deletes untracked files there.

## 3. Mobile app builds

Add the `pandapay-app` project's DSN to staging and production builds (Codemagic environment variable, never committed):

```sh
flutter build appbundle --release ... \
  --dart-define=PANDAPAY_ERROR_REPORTING_DSN=https://<key>@errors.pandapath.live/<app-project-id>
```

Builds without it send nothing. A report holds the error's class name, code locations (`data/import_models.dart:142`), app version, platform and which handler caught it; never the message, screen content, user or device ids. Reports wait on the phone when offline (at most 20, for 7 days), each problem is sent once per app session, and at most 10 a minute. See `app/lib/app/crash_reporter.dart`.

## 4. Check it works

- Grafana's **Services reporting** shows 3, and request graphs move when you use the app.
- In Prometheus (`http://<tailscale-ip>:9090/alerts`), every rule is loaded and only `Watchdog` fires.
- Stop the auth container for four minutes: Telegram receives **ServiceDown**, then a resolved message.
- GlitchTip: **Send test event** in a project proves ingestion. For the real path, trigger a handled 500 on the staging API (it shows the route template and no message text) and a handled error in a staging app build (it appears in `pandapay-app` within a minute).

## Day to day

- **Alerts** arrive in Telegram with a plain-language summary. Critical: act now. Warning: look the same day.
- **Errors**: GlitchTip groups them by cause and release. Resolve an issue when fixed; it reopens if it returns in a later release.
- **Updates**: bump the pinned image versions here monthly, after reading their release notes.
- **Backups**: GlitchTip's database is not business data and keeps 30 days; losing it loses error history only. Grafana dashboards are in this folder.
- **If the monitoring VM dies**, alerts stop silently. Route the `Watchdog` alert to an external dead-man check (instructions in `alertmanager.example.yml`).

## Not covered yet

- Native (Kotlin/Swift) crashes in the mobile app; Dart errors, which are almost all of them, are covered.
- Metrics from the background workers (SMS AI, SMS learning, rewards). Their job freshness is visible on the admin console's System Status page.
- Central log search (Loki), only after a review that the logs contain no personal data.
