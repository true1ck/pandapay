import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_database.dart';
import 'sms_rule_bundle.dart';

class SmsRuleBundleStore {
  final AppDatabase database;

  SmsRuleBundleStore(this.database) {
    _ensureTable();
  }

  void _ensureTable() {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS sms_rule_bundles (
          bundle_version INTEGER PRIMARY KEY,
          raw_json TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          cached_at INTEGER NOT NULL
        );
      ''');
    } catch (_) {
      // Database might be closed during disposal
    }
  }

  SmsRuleBundle? loadActiveBundleSync() {
    _ensureTable();
    try {
      final rows = database.db.select('''
        SELECT raw_json
          FROM sms_rule_bundles
         WHERE is_active = 1
         ORDER BY bundle_version DESC
         LIMIT 1
      ''');
      if (rows.isEmpty) return null;
      final raw = rows.first['raw_json'] as String;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return SmsRuleBundle.fromJson(decoded, verifySha: true);
      } else if (decoded is Map) {
        return SmsRuleBundle.fromJson(decoded.cast<String, dynamic>(), verifySha: true);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<SmsRuleBundle?> loadActiveBundle() async {
    return loadActiveBundleSync();
  }

  Future<bool> saveBundle(Map<String, dynamic> json) async {
    _ensureTable();
    final bundle = SmsRuleBundle.fromJson(json, verifySha: true);
    if (bundle == null) return false;

    try {
      database.db.execute(
        '''
        INSERT OR REPLACE INTO sms_rule_bundles
          (bundle_version, raw_json, sha256, is_active, cached_at)
        VALUES (?, ?, ?, 1, ?)
      ''',
        [
          bundle.bundleVersion,
          jsonEncode(json),
          bundle.sha256,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> rollback([int? targetVersion]) async {
    _ensureTable();
    try {
      if (targetVersion != null) {
        database.db.execute(
          'UPDATE sms_rule_bundles SET is_active = 0 WHERE bundle_version = ?',
          [targetVersion],
        );
      } else {
        database.db.execute('UPDATE sms_rule_bundles SET is_active = 0');
      }
    } catch (_) {}
  }

  Future<bool> syncRules(
    http.Client client, {
    required String apiBaseUrl,
    String? bearerToken,
  }) async {
    try {
      final active = loadActiveBundleSync();
      final sinceVersion = active?.bundleVersion ?? 0;
      final uri = Uri.parse('$apiBaseUrl/sms/rules/active?since_version=$sinceVersion');

      final headers = <String, String>{
        'Accept': 'application/json',
        if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      };

      final res = await client.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return false;

      // Server indicates a rollback occurred
      if (decoded['rolledBack'] == true) {
        final newVersion = decoded['bundleVersion'] as int? ?? 0;
        if (newVersion == 0) {
          await rollback();
          return true;
        } else {
          // Deactivate newer local bundles and save the lower active version
          await rollback();
          if (decoded is Map<String, dynamic>) {
            return await saveBundle(decoded);
          }
          return true;
        }
      }

      if (decoded['upToDate'] == true) {
        return false;
      }

      if (decoded is Map<String, dynamic>) {
        return await saveBundle(decoded);
      } else {
        return await saveBundle(decoded.cast<String, dynamic>());
      }
    } catch (_) {
      // Offline or network timeout fails open without crashing
      return false;
    }
  }
}
