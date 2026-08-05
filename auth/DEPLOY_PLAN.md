# PandaPal Auth Service — Deployment Plan

## Current state (confirmed by code review)

- **Backend**: Express 5 app (`src/index.js`), listens on `PORT` (default 3000).
- **Endpoints match the Flutter app exactly** — `/auth/request-email-otp` and `/auth/verify-email-otp`
  request/response shapes line up with what `lib/services/auth_service.dart` sends and expects.
  No backend code changes are needed for compatibility.
- **Database**: real Postgres, `DATABASE_URL` already set in `.env` to a live connection string.
  This is a *separate* Postgres DB, not the Supabase project the Flutter app uses for calendar data.
- **Secrets already filled in `.env`**: `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`, Twilio SID/token/from-number,
  Gmail SMTP creds. These look real, not placeholders.
- **Never deployed**: no Dockerfile/Procfile/fly.toml/railway.json — only `ecosystem.config.js` (PM2) and
  `setup-server.sh`, matching the project's own `DEPLOYMENT_GUIDE.md` / `QUICK_DEPLOY.md`, which target a
  manual **AWS Lightsail Ubuntu VPS** with Nginx + Certbot + PM2, at the intended domain `auth.livingai.app`.
- **Blocker for the Flutter app**: `AuthService._baseUrl` is hardcoded to `localhost:3000` / `10.0.2.2:3000` /
  `127.0.0.1:3000` — loopback-only. No real device can ever reach it. This is the only client-side change needed
  once the backend has a public URL.

## Two things to clean up before deploying

1. **`CORS_ALLOWED_ORIGINS`** is unset in `.env` (present as a key in `.env.example` but missing from the real
   `.env`). Right now `NODE_ENV=development` silently allows all origins — fine for local dev, **not safe for
   production**. Set it explicitly before going live.
2. **`.env Working`** is a second, older env file sitting next to `.env` with a different `JWT_ACCESS_SECRET`
   and `DATABASE_URL`. It's dead weight that risks getting swapped in by accident — delete it or rename it
   clearly as an archived backup once you've confirmed `.env` is the one you want.

## Deployment plan (per the project's own docs — you run these steps)

1. **Provision the VPS**: AWS Lightsail Ubuntu instance (the docs already assume this — `DEPLOYMENT_GUIDE.md`
   has the exact instance-size recommendation and setup commands).
2. **Point DNS**: `auth.livingai.app` (or whatever domain you choose) → the Lightsail instance's static IP.
3. **Run `setup-server.sh`** on the instance to install Node, PM2, Nginx, and dependencies.
4. **Copy `.env` to the server** (not `.env Working`) — double check `CORS_ALLOWED_ORIGINS` is set to your
   real app's origin(s) before starting the process.
5. **Start with PM2** using `ecosystem.config.js` (`pm2 start ecosystem.config.js`).
6. **Nginx reverse proxy** port 3000 → 443, then **Certbot** for a real Let's Encrypt cert (`DEPLOYMENT_GUIDE.md`
   has the exact Nginx server block and certbot command).
7. **Verify** `https://auth.livingai.app/auth/request-email-otp` responds (a `POST` with a test email should
   return `{ok:true}` or a clear validation error, not a connection failure).

## Client-side change needed after deployment (I can do this once you give the go-ahead)

In `AI_Calendar/lib/services/auth_service.dart`, replace the hardcoded loopback `_baseUrl` values with the
real deployed URL (e.g. `https://auth.livingai.app`) for release builds — likely via `--dart-define` or a
build-flavor split so debug builds can still hit `localhost` for local development. Then rebuild the AAB.

## What I did *not* do

I did not start, deploy, or modify this backend. This file is read-only investigation output for you to act on.
