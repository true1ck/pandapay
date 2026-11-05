import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../features/sms_import/ios_sms_intake_service.dart';
import '../app/startup_timing.dart';

/// UA-3. Access/refresh tokens let this device keep its session across app
/// restarts. The server keeps a rolling 90-day inactivity limit for an
/// abandoned or lost device — OWASP M9 requires these live in the iOS Keychain /
/// Android Keystore, not SharedPreferences' plaintext plist/XML, which is
/// readable on a jailbroken/rooted device and can end up in an unencrypted
/// backup. `flutter_secure_storage` wraps exactly that OS-level storage.
class TokenStore {
  static const _accessKey = 'pandapay_app.access_token';
  static const _refreshKey = 'pandapay_app.refresh_token';
  static const _requestKey = 'pandapay_app.refresh_request';

  /// A non-sensitive, best-effort hint that this install previously had a
  /// persisted session. It is never used to authorize an API call. The
  /// router uses it only to paint the authenticated shell while the (occasionally
  /// very slow) Android Keystore read is still in flight; secure storage remains
  /// the hard authentication gate.
  static const sessionPresenceKey = 'pandapay_app.session_presence_hint_v1';

  final FlutterSecureStorage _secureStorage;
  String? _cachedAccessToken;
  String? _cachedRefreshToken;

  TokenStore(this._secureStorage, {String? accessToken, String? refreshToken})
    : _cachedAccessToken = accessToken,
      _cachedRefreshToken = refreshToken;

  static Future<TokenStore> load() async {
    markStartup('token load start');
    const secureStorage = FlutterSecureStorage();
    // Restore the session in one native platform call.  The Android plugin
    // runs each method on its secure-storage worker and two sequential
    // `read` calls pay the platform/keystore boundary twice before the
    // router can leave the splash.  `readAll`
    // returns only this plugin's prefixed keys and keeps the same encrypted
    // storage and error behavior.
    final secureValues = await secureStorage.readAll();
    final accessToken = secureValues[_accessKey];
    markStartup('access token read complete');
    final refreshToken = secureValues[_refreshKey];
    markStartup('refresh token read complete');

    final prefs = await SharedPreferences.getInstance();
    markStartup('token preferences ready');

    // A false value is as important as a true one: an interrupted sign-out
    // must never leave a future cold start looking authenticated.
    await prefs.setBool(
      sessionPresenceKey,
      accessToken != null || refreshToken != null,
    );

    markStartup('token load complete');
    return TokenStore(
      secureStorage,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  String? get accessToken => _cachedAccessToken;
  String? get refreshToken => _cachedRefreshToken;

  /// Persist before sending: an interrupted update/network request must retry
  /// the same rotation, rather than consume the old credential a second time.
  Future<String> refreshRequestId(String refreshToken) async {
    final saved = await _secureStorage.read(key: _requestKey);
    if (saved != null) {
      final record = jsonDecode(saved) as Map<String, dynamic>;
      if (record['refresh_token'] == refreshToken) {
        return record['request_id'] as String;
      }
    }
    final id = const Uuid().v4();
    await _secureStorage.write(
      key: _requestKey,
      value: jsonEncode({'refresh_token': refreshToken, 'request_id': id}),
    );
    return id;
  }

  Future<void> save({required String accessToken, String? refreshToken}) async {
    // Refresh tokens rotate and the previous value becomes invalid as soon as
    // the server accepts a refresh. Persist the replacement first so a process
    // death between the two writes can recover with the new credential rather
    // than leaving the device holding an already-spent refresh token.
    if (refreshToken != null) {
      _cachedRefreshToken = refreshToken;
      await _secureStorage.write(key: _refreshKey, value: refreshToken);
    }
    _cachedAccessToken = accessToken;
    await _secureStorage.write(key: _accessKey, value: accessToken);

    // Do this only after both secure writes have succeeded. The hint can
    // shorten the next launch, but it must never make a partially persisted
    // login look durable.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(sessionPresenceKey, true);
    } catch (_) {
      // Secure credentials are authoritative; a preferences failure only
      // forfeits the warm-shell optimization on the next process start.
    }
  }

  Future<void> clear() async {
    // Clear the non-sensitive hint before deleting credentials. If a secure
    // delete is interrupted, the conservative next launch path waits for the
    // authoritative Keystore read instead of exposing a warm shell.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(sessionPresenceKey, false);
    } catch (_) {
      // Credential deletion below remains the source of truth.
    }
    // Revoke the capture-time account before removing its credentials. A cold
    // Shortcut must never keep saving under a signed-out account.
    await IosSmsIntakeService().revoke('signed-out');
    _cachedAccessToken = null;
    _cachedRefreshToken = null;
    await _secureStorage.delete(key: _accessKey);
    await _secureStorage.delete(key: _refreshKey);
    await _secureStorage.delete(key: _requestKey);
  }
}
