# SMS v2 signing keys and device attestation

Generate an Ed25519 key on a trusted administration machine with restrictive permissions.

```sh
umask 077
openssl genpkey -algorithm Ed25519 -out sms-v2-private.pem
openssl pkey -in sms-v2-private.pem -pubout -out sms-v2-public.pem
```

Store the private PEM in the server secret store as `SMS_RULES_SIGNING_KEY`, and set the matching `SMS_RULES_KEY_ID`. The maintenance import and hourly jobs use the private admin database URL and an active owner actor. Keep the private key outside the repository, build artifacts, logs and phone app.

Extract the 32 public-key bytes from the public PEM using a standard Ed25519 library and base64 encode them. Add that public value to `smsV2RuleKeys` in `rule_keys.dart`. Ship the public key one app release before switching the server to it. During rotation, keep the old and new key IDs installed. Retire the old public key after supported phones have the new one and old bundles have expired.

If a private key leaks, revoke its secret, generate a replacement and republish every bundle with the new key. Ship updated trust anchors and follow the release incident process for phones that only trust the compromised key.

App Check uses Play Integrity on Android and App Attest on iOS. The iOS entitlement uses the production App Attest environment as Firebase requires. Register both app identifiers in the Firebase project's App Check console, register the release Android signing SHA-256, and register debug provider tokens only for development installations. Set `SMS_V2_FIREBASE_PROJECT_NUMBER` and `SMS_V2_FIREBASE_APP_IDS` on the server. The app IDs are a comma-separated allowlist.

Keep `SMS_V2_ATTESTATION_MODE=monitor` during the initial rollout. Unverified devices have half the admission limits, and their input cannot affect shared stats or AI drafting. Review the attestation monitor before the WP-17 decision to use `enforce`. The server verifies RS256, issuer, audience, expiry and configured app IDs against Firebase's six-hour JWKS cache. Entitlement is disabled by default. Setting `SMS_V2_REQUIRE_ENTITLEMENT=true` requires the product entitlement callback to admit downloads.

The checked-in production rule-key map is empty until key provisioning. The app keeps its shipped empty baseline until it has a bundle signed by an installed key.

References are [Firebase custom backend verification](https://firebase.google.com/docs/app-check/custom-resource-backend), [Flutter App Check setup](https://firebase.google.com/docs/app-check/flutter/default-providers), and [App Attest setup](https://firebase.google.com/docs/app-check/ios/app-attest-provider).
