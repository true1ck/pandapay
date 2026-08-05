import 'package:shared_preferences/shared_preferences.dart';

/// UA-3: same pattern as console/lib/data/token_store.dart (SharedPreferences,
/// works on Web via localStorage too) — kept as a separate copy rather than a
/// shared package since the two apps' pubspecs don't share a common
/// non-domain package yet and this is a handful of lines, not worth the
/// coupling.
class TokenStore {
  static const _accessKey = 'pandapay_app.access_token';
  static const _refreshKey = 'pandapay_app.refresh_token';

  final SharedPreferences _prefs;
  const TokenStore(this._prefs);

  static Future<TokenStore> load() async => TokenStore(await SharedPreferences.getInstance());

  String? get accessToken => _prefs.getString(_accessKey);
  String? get refreshToken => _prefs.getString(_refreshKey);

  Future<void> save({required String accessToken, String? refreshToken}) async {
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
