/// Build-time environment configuration (plan Phase 0.3).
///
/// Before this file, `providers.dart` hardcoded `http://localhost:4000` and
/// `http://localhost:3210` as plain `const`s, which meant a release build
/// pointed at the handset itself and could never reach a real backend. These
/// are `String.fromEnvironment`, so the value is fixed at compile time by
/// `--dart-define` and is tree-shaken into the binary as a constant — no
/// runtime lookup, no `.env` file shipped inside the APK/IPA (which would be
/// trivially readable, OWASP M9), and no way for a running app to be pointed
/// somewhere else.
///
/// The defaults are the local dev ports, so `flutter run` with no flags keeps
/// behaving exactly as it did before this change. Every non-dev build is
/// expected to pass all three defines:
///
/// ```bash
/// flutter build apk --release \
///   --dart-define=PANDAPAY_ENV=prod \
///   --dart-define=PANDAPAY_API_BASE_URL=https://api.pandapay.example \
///   --dart-define=PANDAPAY_AUTH_BASE_URL=https://auth.pandapay.example
/// ```
///
/// [assertReleaseConfigured] turns a forgotten define into a loud startup
/// failure rather than a release build that silently tries to reach
/// `localhost` on a user's phone and shows them a generic network error.
library;

enum AppEnvironment { dev, staging, prod }

class Env {
  const Env._();

  static const String _rawEnv = String.fromEnvironment(
    'PANDAPAY_ENV',
    defaultValue: 'dev',
  );

  /// api/'s base URL. Default is api/'s live endpoint.
  static const String apiBaseUrl = String.fromEnvironment(
    'PANDAPAY_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:4000',
  );

  /// auth/'s base URL. Default is auth/'s live endpoint.
  static const String authBaseUrl = String.fromEnvironment(
    'PANDAPAY_AUTH_BASE_URL',
    defaultValue: 'http://10.0.2.2:3210',
  );

  /// iOS OAuth 2.0 client id for the on-device Gmail "1-Tap Auto Find" flow
  /// (`app/lib/features/import/gmail_connect_service.dart`). Empty by default;
  /// Android needs nothing here (the client is matched by package + SHA-1),
  /// but iOS must pass the client id AND carry the reversed-client-id URL
  /// scheme in Info.plist. See `docs/gmail-oauth-setup.md`. Not a secret —
  /// client ids are public — so a compile-time define is fine.
  static const String iosGoogleClientId = String.fromEnvironment(
    'PANDAPAY_IOS_GOOGLE_CLIENT_ID',
    defaultValue: '',
  );

  static AppEnvironment get environment => switch (_rawEnv) {
    'prod' => AppEnvironment.prod,
    'staging' => AppEnvironment.staging,
    _ => AppEnvironment.dev,
  };

  static bool get isDev => environment == AppEnvironment.dev;

  /// True for the `prod` Android flavor — the one Play Console releases
  /// ship under (see app/android/app/build.gradle.kts). Used to hide SMS
  /// auto-import's permission UI: Google Play's SMS/Call Log policy only
  /// allows READ_SMS/RECEIVE_SMS for apps that are the user's default SMS
  /// handler with the permission as core, unremovable functionality —
  /// PandaPay's SMS import is an optional convenience feature (manual entry
  /// and card-scan both work without it), so it doesn't qualify.
  /// app/android/app/src/prod/AndroidManifest.xml strips both permissions
  /// for this flavor at the manifest level; this flag keeps the UI from
  /// showing an "Enable" button whose permission request can only fail.
  static bool get isProd => environment == AppEnvironment.prod;

  /// True when either base URL still points at a loopback address. Used both
  /// by [assertReleaseConfigured] and by the debug banner in H5 so a tester
  /// can tell at a glance which backend a build is talking to.
  static bool get pointsAtLocalhost =>
      _isLoopback(apiBaseUrl) || _isLoopback(authBaseUrl);

  static bool _isLoopback(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    // 10.0.2.2 is the Android emulator's alias for the host machine's
    // loopback — just as unreachable from a real device as `localhost`.
    return host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2';
  }

  /// Fails fast in a release build that was compiled without the defines.
  ///
  /// Deliberately an unconditional `throw` rather than an `assert`: asserts
  /// are stripped from release builds, which is precisely the build this is
  /// meant to catch. A crash on the first frame with an actionable message is
  /// strictly better than shipping a build that can only ever show users a
  /// network error, and it can only ever fire on a misconfigured release —
  /// never on a real user's device once the build is correct.
  static void assertReleaseConfigured() {
    // `bool.fromEnvironment('dart.vm.product')` rather than Flutter's
    // `kReleaseMode` — identical meaning, but it keeps this file free of any
    // Flutter import. That matters because `tool/verify_live_*.dart` are
    // plain `dart run` scripts with no Flutter engine: importing
    // package:flutter/foundation here made them fail to compile with
    // "Undefined name 'Image'" out of dart:ui, which is a confusing failure
    // a long way from its cause.
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease && pointsAtLocalhost) {
      throw StateError(
        'Release build was compiled without --dart-define=PANDAPAY_API_BASE_URL / '
        'PANDAPAY_AUTH_BASE_URL, so it points at $apiBaseUrl and $authBaseUrl. '
        'See app/lib/app/env.dart for the required build flags.',
      );
    }
  }
}
