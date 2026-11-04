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
  --dart-define=SMS_PIPELINE_V2=true \
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

The recipe compiles a Debug app with the printed Flutter defines, installs the test CA on the selected simulator and installs the separate app identity. Use a simulator reserved for the rig. The ephemeral Ed25519 public key is accepted only in Debug builds using the development environment. The production key list is unchanged. A restarted rig creates new URLs, certificates, and a new key, so rebuild against its fresh defines.

## Physical iPhone checklist for a later session

1. Start the rig on the Mac's private LAN address. Make sure the iPhone can reach that interface over the trusted test network.
2. Transfer only the rig's public `tls/rootCA.pem` to the device. Install and enable full trust for that specific test root in iOS settings. Remove the test root after the session.
3. Open `app/ios/Runner.xcworkspace` in Xcode with the device connected. Use a separate Debug app identity and development provisioning. Feed the printed `flutter-defines.json` to Flutter's debug build or encode its entries as Xcode `DART_DEFINES`. Keep the test build separate from the normal app install and its storage.
4. Sign in with the rig account, confirm rule download, then import a synthetic tagged-bank message and verify the synced Activity row. Check the Shortcut automation with a tagged sender, a missing sender with a named issuer, and a contact handle. Record which values Shortcuts actually delivers.
5. Validate the five history screens and interrupted replay in the test build. Actual device history and production App Check are separate acceptance checks.

Only the public CA and bundle trust anchor go to a test device. The rig's private key and CA signing key stay on the Mac.
