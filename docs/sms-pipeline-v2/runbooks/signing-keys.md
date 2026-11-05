# SMS v2 signing keys and device attestation

Generate an Ed25519 key on a trusted administration machine with restrictive permissions.

```sh
umask 077
openssl genpkey -algorithm Ed25519 -out sms-v2-private.pem
openssl pkey -in sms-v2-private.pem -pubout -out sms-v2-public.pem
```

Store the private PEM in the secret store as `SMS_RULES_SIGNING_KEY`, and set the matching `SMS_RULES_KEY_ID`. **Only the private admin host (`admin-api`, the `sms-v2-rule-jobs` service, and operator imports and releases) holds these.** The public API never has the key: it serves bundles that were signed ahead of time and stored in `sms_v2_bundles.served_body`. In production the public API logs an error at start-up if `SMS_RULES_SIGNING_KEY` is present in its environment; remove it there. The maintenance import and hourly jobs use the private admin database URL and an active owner actor. Keep the private key outside the repository, build artifacts, logs and phone app.

### Pre-signed serving and expiry

Every bundle carries a 7-day `expiresAt`, and a phone ignores an expired bundle. Minting (import, publish, pause, rollback) signs the served copy straight away. The hourly job (the `sms-v2-rule-jobs` service in `deploy/admin/compose.private.yml`, which runs `src/sms_v2/jobs/rule_jobs_main.js --loop` at start-up and at minute 7 of every hour) then re-signs the active bundle of each cohort when its served copy has less than `SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS` left (default 72, allowed 1 to 120) or was signed by a different key id than the one in the job's environment. It refuses to sign a stored body whose content hash no longer matches the hash recorded when it was minted (`bundle_corrupt`).

If the job stops, phones keep the bundle they have; the public API answers `503 bundle_unavailable` once the served copy expires (it never re-signs and never serves an expired or unsigned copy). A failed run logs `{"event":"sms_v2_rule_jobs","status":"failed"}` and is retried at the next hour; the console's System status shows "SMS rule set signing" as failed when any active rule set has less than 48 hours left. Alert on that and on `503 bundle_unavailable` from `/sms/v2/rules`. Recovery is to fix the cause and restart the service (`docker compose -f docker-compose.prod.yml -f deploy/admin/compose.private.yml --profile admin restart sms-v2-rule-jobs`), which runs the job at start-up. `node api/scripts/run_sms_v2_rule_jobs.js --admin-id <id>` from an operator checkout still runs it once and exits non-zero on failure.

Deploy order for the pre-signed serving change: apply migration `20261114100000_sms_v2_presigned_bundles.sql`, run the job once (it fills `served_body` for existing rows), then deploy the API and remove the key from its environment. Until the job has run, new API code answers 503 for rows with no served copy.

Extract the 32 public-key bytes from the public PEM using a standard Ed25519 library and base64 encode them. Add that public value to `smsV2RuleKeys` in `rule_keys.dart`. Ship the public key one app release before switching the server to it. During rotation, keep the old and new key IDs installed. Retire the old public key after supported phones have the new one and old bundles have expired.

### Revoking a leaked rule key without an app release (LO-13)

Phones trust the keys compiled into `rule_keys.dart`, so a leaked key cannot be removed from installed apps without a release. What can be done at once, with no release:

1. Keep a **spare key** shipped one release ahead (the rotation rule above) so the replacement is already trusted. Without a spare there is no release-free recovery; generate one now and ship it.
2. Revoke the secret: remove the leaked private key from the secret store and every host that held it.
3. Put the spare private key and its key id into the maintenance environment (`SMS_RULES_SIGNING_KEY`, `SMS_RULES_KEY_ID`) and run `node api/scripts/run_sms_v2_rule_jobs.js --admin-id <id>` once. A different key id makes every active cohort bundle due, so all four are re-signed with the spare and the API serves them from then on. Phones pick them up at their next check (about 6 hours) and from then on only receive bundles signed by the spare.
4. The leaked key is still accepted by installed apps until a release removes it, but an attacker can only use it by delivering a forged bundle to a phone, which means intercepting TLS to our API or compromising the API. Phones also refuse a bundle whose version is lower than the stored one, and a forged high version is the only way to lock out legitimate updates. Watch the metrics page for phones reporting rejected bundles.
5. In the next app release, delete the leaked key from `smsV2RuleKeys` and ship a new spare. After that release reaches supported phones, the old key is dead everywhere.

If both the active and the spare key are lost, the only fix is a release with new trust anchors; phones keep their last good bundle until it expires after 7 days, and the shipped baseline takes over.

App Check uses Play Integrity on Android and App Attest on iOS. The iOS entitlement uses the production App Attest environment as Firebase requires. Register both app identifiers in the Firebase project's App Check console, register the release Android signing SHA-256, and register debug provider tokens only for development installations. Set `SMS_V2_FIREBASE_PROJECT_NUMBER` and `SMS_V2_FIREBASE_APP_IDS` on the server. The app IDs are a comma-separated allowlist.

### Binding, replay and debug tokens (LO-10, LO-15)

An App Check token only proves a genuine install made it. The server binds a token to the first account and installation id that present it: a later request with the same token from another profile or another `X-Sms-Device-Id` is treated as unattested (half limits and no shared learning in `monitor`, `403` in `enforce`) and logged as `bound_elsewhere`. Only SHA-256 digests and the token expiry are stored (`sms_v2_attestation_bindings`, migration `20261114110000`, rows cleaned up after expiry). `SMS_V2_ATTESTATION_BINDING` is `db` (durable, every replica agrees; the production default when the API has a database client), `memory` (per process; the default elsewhere) or `off`. Apply the migration before deploying. A user who signs out and into another account on the same phone within the token's lifetime (about an hour) is unattested until the app fetches a new token.

Limited-use token replay protection is available but **off by default**. It needs Firebase credentials and an app that sends `getLimitedUseToken()` tokens (`DeviceAttestation.limitedUseHeaders()` exists; the sync client does not call it yet). To enable: install `google-auth-library` in `api/`, give the API application default credentials allowed to call `verifyAppCheckToken` on the Firebase project, and set `SMS_V2_APPCHECK_REPLAY_PROTECTION=on`. The server then consumes the token with Firebase on `SMS_V2_APPCHECK_LIMITED_USE_ROUTES` (default `unknown-templates,corrections,rule-stats`); a token that was already used, or a check that fails, makes the request unattested. The server refuses to start with replay protection on and no credentials. Do not turn it on before the app sends limited-use tokens on those routes, or `enforce` would refuse normal requests.

Debug providers: in `NODE_ENV=production` the server rejects tokens that look like debug-provider tokens (a `provider` style claim naming a debug provider, or a subject listed in `SMS_V2_DEBUG_APP_IDS`). Firebase documents no stable claim for this, so the dependable control is to register debug installs only in a separate Firebase project, or under dedicated app ids that you list in `SMS_V2_DEBUG_APP_IDS`. Set `SMS_V2_ALLOW_DEBUG_APP_CHECK=true` only for a deliberate production test.

Keep `SMS_V2_ATTESTATION_MODE=monitor` during the initial rollout. Unverified devices have half the admission limits, and their input cannot affect shared stats or AI drafting. Review the attestation monitor before the WP-17 decision to use `enforce`. The server verifies RS256, issuer, audience, expiry and configured app IDs against Firebase's six-hour JWKS cache. Entitlement is disabled by default. Setting `SMS_V2_REQUIRE_ENTITLEMENT=true` requires the product entitlement callback to admit downloads.

The checked-in production rule-key map is empty until key provisioning. The app keeps its shipped empty baseline until it has a bundle signed by an installed key.

References are [Firebase custom backend verification](https://firebase.google.com/docs/app-check/custom-resource-backend), [Flutter App Check setup](https://firebase.google.com/docs/app-check/flutter/default-providers), and [App Attest setup](https://firebase.google.com/docs/app-check/ios/app-attest-provider).
