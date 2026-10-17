# Offline-first display and authentication contract

This document records the rules for the display-data path and the token
configuration. It is part of the release checklist because a build can be
correct while the app still shows an empty/error screen if the API and auth
service are deployed with different token settings.

## Display-data contract

The app uses the local SQLite response cache as the last-known display source.
The cache is scoped by the JWT `sub`, so rotating an access token does not
look like a different account and signing out clears that account's snapshot.

The normal read path is:

1. Render the account-scoped local snapshot when the device is known offline.
2. When online, request the latest server response and replace the snapshot
   only after the response parses successfully.
3. If the request fails because of a network error, a transient server error,
   or an expired access token, render the last valid snapshot.
4. Keep local writes in the outbox/sync queue and flush them after connectivity
   returns.
5. Refresh the display snapshot on sign-in, app resume, and a false-to-true
   connectivity transition. The refresh is watched from the app shell, not
   only from Home, so Wallet, Insights, and You receive the same treatment.

Read-only display data must never clear a valid local snapshot merely because
one request failed. A successful empty server response is valid and may
replace the snapshot; a failed request is not an empty response.

## Auth/token contract

`auth/` signs access tokens with `JWT_ACCESS_SECRET`. `api/` verifies them with
the same value. `JWT_REFRESH_SECRET` is separate and is used only for refresh
tokens. In the production compose deployment both services receive the shared
values from the same root `.env` file:

- `JWT_ACCESS_SECRET` must be identical in `api` and `auth`.
- `JWT_REFRESH_SECRET` must be present in `auth` and must be different from
  the access secret.
- `JWT_ISSUER` and `JWT_AUDIENCE` must be identical in both services. The
  production Compose files pass the defaults (`pandapay-auth` and
  `mobile-app`) explicitly.
- If `JWT_KEYS_JSON` is used, `JWT_ACTIVE_KEY_ID` and the complete key set must
  be identical in both services. Auth signs with the active key and API keeps
  previous keys available for verification during rotation.
- `JWT_ACCESS_TTL` must remain comfortably longer than the client refresh
  interval. The current defaults are 15 minutes and a five-minute client
  keep-alive.
- Do not deploy an archived/alternate env file. In particular, do not use the
  old `auth/.env Working` file without comparing its values to the production
  `.env`.

When both services are started directly from one checkout, use explicit
`API_DATABASE_URL` and `AUTH_DATABASE_URL` rather than two `DATABASE_URL`
entries. Most dotenv loaders retain the *first* duplicate key whereas Compose
interpolation can use the later one; that disagreement can make the two
services start against unintended databases or credentials. `DATABASE_URL`
is supported only as a one-service, backwards-compatible fallback.

The mobile client restores its last access token immediately, refreshes in the
background, shares one in-flight refresh among concurrent 401 responses, and
saves the rotated refresh token before publishing the new access token. A
refresh failure does not sign the user out; read-only screens remain usable
from the scoped cache and a later retry can recover the session.

## Release verification

Before a production build is distributed:

1. Deploy `api` and `auth` together from the same commit and root env file.
2. Confirm both services start successfully and `/health` responds. Before
   routing traffic, also require `/ready` from both services; it checks the
   database connection and returns 503 while the instance is not ready.
3. Sign in on one device, open Wallet, Insights, and You, then background and
   resume the app after the access-token TTL boundary.
4. Confirm the auth log shows one successful refresh and the API accepts the
   new access token.
5. Temporarily test a network loss: cached display data must remain visible;
   after connectivity returns, the queued writes and fresh reads must settle
   without requiring logout/login.

If the UI says `Missing or invalid access token` on every authenticated
screen, check the service configuration first. The most likely causes are a
different `JWT_ACCESS_SECRET` between `api` and `auth`, a stale/reused rotating
refresh token, or a deployment that loaded an old env file. The mobile app
cannot correct a server-side signature mismatch; it can only preserve cached
display data and retry safely.
