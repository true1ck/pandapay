import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Native compatibility storage. Browser builds erase legacy credentials and
/// use only the server's HttpOnly cookie; no bearer token is persisted here.
/// Native admin refresh tokens remain sensitive privileged credentials.
class TokenStore {
  static const _accessKey = 'pandapay_console.access_token';
  static const _refreshKey = 'pandapay_console.refresh_token';

  final SharedPreferences _prefs;
  final bool browserSessions;
  const TokenStore(this._prefs, {this.browserSessions = kIsWeb});

  static Future<TokenStore> load({bool browserSessions = kIsWeb}) async {
    final store = TokenStore(
      await SharedPreferences.getInstance(),
      browserSessions: browserSessions,
    );
    if (store.browserSessions) await store.clear();
    return store;
  }

  String? get accessToken =>
      browserSessions ? null : _prefs.getString(_accessKey);
  String? get refreshToken =>
      browserSessions ? null : _prefs.getString(_refreshKey);

  Future<void> save({required String accessToken, String? refreshToken}) async {
    if (browserSessions) {
      await clear();
      return;
    }
    await _prefs.setString(_accessKey, accessToken);
    if (refreshToken != null) {
      await _prefs.setString(_refreshKey, refreshToken);
    }
  }

  Future<void> clear() async {
    await _prefs.remove(_accessKey);
    await _prefs.remove(_refreshKey);
  }
}
