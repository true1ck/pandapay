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
/// behaving exactly as it did before this change. Every hosted build is
/// expected to pass all three defines. A physical-device QA build may keep
/// the Dev Android flavor and package id while using `dev_hosted`; this keeps
/// the Dev runtime behavior and existing install data while making the
/// backend target explicit and allowing hosted URLs in a release artifact.
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

  /// api/'s base URL. The safe default is the Android emulator's host alias,
  /// not production. Production/staging builds must pass an explicit URL via
  /// the build script so a plain debug build cannot write test data to live.
  static const String apiBaseUrl = String.fromEnvironment(
    'PANDAPAY_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:4000',
  );

  /// auth/'s base URL. See [apiBaseUrl] for why this defaults locally.
  static const String authBaseUrl = String.fromEnvironment(
    'PANDAPAY_AUTH_BASE_URL',
    defaultValue: 'http://10.0.2.2:3210',
  );

  /// Hosted legal pages (Terms, Privacy Policy).
  static const String legalBaseUrl = String.fromEnvironment(
    'PANDAPAY_LEGAL_BASE_URL',
    defaultValue: 'http://10.0.2.2:4000/legal/',
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

  /// A Dev flavor that uses hosted endpoints is still a Dev app from the
  /// user's perspective. The raw value remains distinct so a release build
  /// cannot accidentally use hosted URLs under the plain local `dev` mode.
  static bool get isHostedDev => _rawEnv == 'dev_hosted';

  static bool get isDev => environment == AppEnvironment.dev;

  /// True for the `prod` Android flavor — the one used for the production
  /// application id. SMS capture remains enabled in this flavor; this getter
  /// is retained for other environment-specific presentation decisions.
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

  /// Describes a release build compiled without the required hosted defines.
  ///
  /// Deliberately an unconditional `throw` rather than an `assert`: asserts
  /// are stripped from release builds, which is precisely the build this is
  /// meant to catch. A crash on the first frame with an actionable message is
  /// strictly better than shipping a build that can only ever show users a
  /// network error, and it can only ever fire on a misconfigured release —
  /// never on a real user's device once the build is correct.
  static String? get releaseConfigurationError {
    // `bool.fromEnvironment('dart.vm.product')` rather than Flutter's
    // `kReleaseMode` — identical meaning, but it keeps this file free of any
    // Flutter import. That matters because `tool/verify_live_*.dart` are
    // plain `dart run` scripts with no Flutter engine: importing
    // package:flutter/foundation here made them fail to compile with
    // "Undefined name 'Image'" out of dart:ui, which is a confusing failure
    // a long way from its cause.
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (!isRelease) return null;
    if (environment == AppEnvironment.dev && !isHostedDev) {
      return 'This release build was compiled as dev. Use the production '
          'build script with the prod flavor and hosted backend URLs.';
    }
    if (pointsAtLocalhost) {
      return 'This release build has no hosted backend URL. Rebuild it with '
          'the production build script and PANDAPAY_API_BASE_URL plus '
          'PANDAPAY_AUTH_BASE_URL.';
    }
    return null;
  }

  /// Retained for command-line validation and existing callers. UI startup
  /// uses [releaseConfigurationError] so a malformed APK can explain itself.
  static void assertReleaseConfigured() {
    final error = releaseConfigurationError;
    if (error != null) throw StateError(error);
  }
}
