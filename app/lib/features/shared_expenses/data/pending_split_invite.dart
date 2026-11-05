import 'package:shared_preferences/shared_preferences.dart';
import 'shared_invitations.dart';

/// Keeps a split-invite token across install, onboarding and sign-in so the
/// person lands on the Join screen afterwards. The token is a join request
/// secret only: it expires with the server invite (7 days) and is cleared as
/// soon as the invite is answered, declined or found unusable.
class PendingSplitInviteStore {
  PendingSplitInviteStore({Future<SharedPreferences> Function()? load})
    : _load = load ?? SharedPreferences.getInstance;
  static const _tokenKey = 'pandapay_app.pending_split_invite_v1';
  static const _atKey = 'pandapay_app.pending_split_invite_at_v1';
  static const lifetime = Duration(days: 7);
  final Future<SharedPreferences> Function() _load;

  Future<void> capture(String? token, {DateTime? now}) async {
    if (token == null ||
        sharedInviteTokenFromUri(Uri.parse(sharedInviteUrl(token))) != token)
      return;
    final prefs = await _load();
    await prefs.setString(_tokenKey, token);
    await prefs.setInt(_atKey, (now ?? DateTime.now()).millisecondsSinceEpoch);
  }

  /// The newest stored token, or null if none or older than a week.
  Future<String?> read({DateTime? now}) async {
    final prefs = await _load();
    final token = prefs.getString(_tokenKey), at = prefs.getInt(_atKey);
    if (token == null || at == null) return null;
    final age = (now ?? DateTime.now()).difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    if (age > lifetime || age.isNegative || sharedInviteUrlOk(token) == false) {
      await clear();
      return null;
    }
    return token;
  }

  Future<void> clear() async {
    final prefs = await _load();
    await prefs.remove(_tokenKey);
    await prefs.remove(_atKey);
  }

  static bool sharedInviteUrlOk(String token) =>
      sharedInviteTokenFromUri(Uri.parse(sharedInviteUrl(token))) == token;
}
