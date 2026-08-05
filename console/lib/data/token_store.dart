import 'package:shared_preferences/shared_preferences.dart';

/// Chunk 10: the only thing standing between "signed in" and "OTP again on
/// every reload" was that nothing ever wrote the tokens anywhere. Wraps
/// SharedPreferences (works on Flutter Web via localStorage) rather than
/// anything more elaborate — this is a refresh token for an internal admin
/// tool, not a payment credential.
class TokenStore {
  static const _accessKey = 'pandapay_console.access_token';
  static const _refreshKey = 'pandapay_console.refresh_token';

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
