import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UA-3. Access/refresh tokens are the credential that lets this device act
/// as the signed-in user indefinitely (the refresh token in particular has
/// no short expiry) — OWASP M9 requires these live in the iOS Keychain /
/// Android Keystore, not SharedPreferences' plaintext plist/XML, which is
/// readable on a jailbroken/rooted device and can end up in an unencrypted
/// backup. `flutter_secure_storage` wraps exactly that OS-level storage.
///
/// [load] transparently migrates anyone already signed in under the old
/// SharedPreferences-backed version of this class (pre-dates this fix) —
/// read the old plaintext values once, move them into secure storage, then
/// delete the plaintext copies, so nobody already logged in gets silently
/// signed out by this change.
class TokenStore {
  static const _accessKey = 'pandapay_app.access_token';
  static const _refreshKey = 'pandapay_app.refresh_token';

  final FlutterSecureStorage _secureStorage;
  String? _cachedAccessToken;
  String? _cachedRefreshToken;

  TokenStore(this._secureStorage, {String? accessToken, String? refreshToken})
    : _cachedAccessToken = accessToken,
      _cachedRefreshToken = refreshToken;

  static Future<TokenStore> load() async {
    const secureStorage = FlutterSecureStorage();
    var accessToken = await secureStorage.read(key: _accessKey);
    var refreshToken = await secureStorage.read(key: _refreshKey);

    // Migrate each credential independently. An interrupted first migration
    // can leave the access token in secure storage while the refresh token is
    // still in SharedPreferences (or vice versa). The old all-or-nothing gate
    // skipped migration in that state, leaving the app with an access token
    // that eventually expired and no way to refresh it. Remove the plaintext
    // copy only after the corresponding secure write has succeeded.
    final prefs = await SharedPreferences.getInstance();
    final legacyAccess = prefs.getString(_accessKey);
    final legacyRefresh = prefs.getString(_refreshKey);

    if (accessToken == null && legacyAccess != null) {
      await secureStorage.write(key: _accessKey, value: legacyAccess);
      accessToken = legacyAccess;
    }
    if (refreshToken == null && legacyRefresh != null) {
      await secureStorage.write(key: _refreshKey, value: legacyRefresh);
      refreshToken = legacyRefresh;
    }

    // Even when secure storage already had the value, delete any duplicate
    // legacy copy so a stale plaintext credential cannot survive the upgrade.
    if (accessToken != null && legacyAccess != null) {
      await prefs.remove(_accessKey);
    }
    if (refreshToken != null && legacyRefresh != null) {
      await prefs.remove(_refreshKey);
    }

    return TokenStore(
      secureStorage,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  String? get accessToken => _cachedAccessToken;
  String? get refreshToken => _cachedRefreshToken;

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
  }

  Future<void> clear() async {
    _cachedAccessToken = null;
    _cachedRefreshToken = null;
    await _secureStorage.delete(key: _accessKey);
    await _secureStorage.delete(key: _refreshKey);
  }
}
