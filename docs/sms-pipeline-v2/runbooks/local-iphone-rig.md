# Local iPhone test rig

This rig uses synthetic data, fresh databases, and a new development signing key for every run. Use it for the isolated SMS v2 test lane. It does not need Docker if the Mac already has Postgres command-line tools.

## Start and verify

From the repository root, with Node 22 or newer, Postgres tools (`initdb`, `pg_ctl`, `psql`), Dart, Flutter and `mkcert` on PATH, and the repository dependencies installed:

```sh
node scripts/sms_v2_local_rig.js
```

For CI-style local verification and automatic shutdown, append `--check-only`. The startup check runs actual email OTP login, signed rule download, tamper rejection, synthetic fact ingestion, and ledger sync over TLS. The local flag is enabled in the scratch database only. The normal run prints the scratch directory, auth and API URLs, and test credentials. Stop it with Ctrl-C.

The default endpoints bind to loopback. For a later phone session, use `--lan-ip <private-Mac-IPv4>` on a trusted local network. The two HTTPS endpoints use a dedicated test CA. The test OTP is fixed, so keep the endpoints on the local network and do not expose them through a public tunnel. The rig creates a private scratch directory under /tmp. Logs, generated bundle and certificate files remain there after shutdown.

Run the real app-client integration on the Mac while the loopback rig is running:

```sh
cd app
SMS_V2_LOCAL_RIG=/tmp/pandapay-sms-rig.EXAMPLE flutter test --no-pub \
  test/features/sms_v2/pipeline/local_rig_test.dart --reporter expanded
```

The test uses the normal AuthApi, BundleVerifier and SmsV2Runtime. It explicitly trusts the rig CA for this test client only. Tests use the scratch account `test@example.com` and OTP `1234`.

## Simulator

Boot a dedicated simulator, then run from the repository root:

```sh
python3 scripts/build_sms_v2_local_ios.py /tmp/pandapay-sms-rig.EXAMPLE \
  --simulator <booted-simulator-uuid>
xcrun simctl launch <booted-simulator-uuid> app.pandapay.pandapay.smsv2rig
```

The recipe compiles a Debug app with the printed Flutter defines and installs the separate app identity. Use a simulator reserved for the rig. The development build trusts the scratch CA for the two local HTTPS origins and accepts the ephemeral Ed25519 bundle key. A restarted rig creates new URLs, certificates, and a new key, so rebuild against its fresh defines.

## Physical iPhone installation

An iOS Flutter Debug app needs Flutter or Xcode attached whenever it starts. Opening it directly from the Home Screen can fail before Dart starts and leave a white screen. Use a standalone Profile build for manual iPhone testing:

```sh
python3 scripts/build_sms_v2_local_ios.py /tmp/pandapay-sms-rig.EXAMPLE \
  --device <connected-iPhone-UDID> --build-number <next-test-build-number>
```

The recipe builds, signs, installs and launches **PandaPay SMS v2 Test**. It keeps the existing `app.pandapay.pandapay.smsv2rig` identity and data, omits the regular app's Shortcut URL scheme, and restores temporary Xcode/manifest changes. Profile builds use `SMS_V2_LOCAL_TEST_BUILD=true`; local CA/bundle trust and history controls require that opt-in, exact `PANDAPAY_ENV=dev` and both public trust anchors. Release builds reject local trust regardless of these defines. The actual HTTP client still accepts only the two configured private IPv4 HTTPS origins and rejects redirects. Production signing keys and App Check provisioning remain separate owner tasks.

## Physical iPhone checklist

1. Start the rig on the Mac's private LAN address. Make sure the iPhone can reach that interface over the trusted test network.
2. Run the Profile installation recipe above with the device connected. The app uses its own scratch CA trust for the two rig origins. Remove any test certificate profile installed for earlier builds.
3. Allow Local Network access when prompted. Use **Sign in** with `test@example.com`, `9999999999` in the required phone field, and verification code `1234`. The returning-user sign-in sends the email and keeps phone linkage unchanged. Confirm rule download, import a synthetic tagged-bank message and verify the synced Activity row.
4. Check a test Shortcut automation with a tagged sender, a missing sender with a named issuer, and a contact handle. Record which values Shortcuts delivers. Existing shortcuts stay bound to their saved app identities.
5. Validate the five history screens and interrupted replay in the test build. Actual device history and production App Check are separate acceptance checks.

Only the public CA and bundle trust anchor go to a test device. The rig's private key and CA signing key stay on the Mac.
