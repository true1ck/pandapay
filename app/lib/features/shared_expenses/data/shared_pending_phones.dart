import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the number typed for a person who was added but not yet invited, so
/// an offline add or a failed invite can be finished later without asking
/// again. It stays on this phone only, is removed once the invite is sent, and
/// entries older than two weeks are dropped.
class SharedPendingPhones {
  SharedPendingPhones(
    this.namespace, {
    Future<SharedPreferences> Function()? load,
  }) : _load = load ?? SharedPreferences.getInstance;
  final String namespace;
  final Future<SharedPreferences> Function() _load;
  static const _lifetime = Duration(days: 14);
  String get _key => 'pandapay_app.shared_pending_phones_v1.$namespace';

  Future<Map<String, Map<String, Object?>>> _read(SharedPreferences p) async {
    try {
      final raw = jsonDecode(p.getString(_key) ?? '{}') as Map;
      final cutoff = DateTime.now().subtract(_lifetime).millisecondsSinceEpoch;
      return {
        for (final e in raw.entries)
          if (e.value is Map && ((e.value as Map)['at'] as int? ?? 0) > cutoff)
            e.key as String: Map<String, Object?>.from(e.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> remember(String memberId, String phone) async {
    final p = await _load();
    final all = await _read(p);
    all[memberId] = {
      'phone': phone,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await p.setString(_key, jsonEncode(all));
  }

  Future<String?> phoneFor(String memberId) async =>
      (await _read(await _load()))[memberId]?['phone'] as String?;

  Future<void> forget(String memberId) async {
    final p = await _load();
    final all = await _read(p);
    if (all.remove(memberId) != null) await p.setString(_key, jsonEncode(all));
  }
}
