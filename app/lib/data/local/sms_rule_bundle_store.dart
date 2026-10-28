import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import '../app_status_repository.dart';
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
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS sms_candidate_rule_bundles (
          namespace TEXT NOT NULL DEFAULT '__legacy__',
          candidate_id TEXT PRIMARY KEY,
          stage TEXT NOT NULL,
          mode TEXT NOT NULL,
          assignment_id TEXT,
          stage_version INTEGER NOT NULL DEFAULT 1,
          raw_json TEXT NOT NULL,
          cached_at INTEGER NOT NULL
        );
      ''');
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS sms_shared_category_rule_bundles (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          raw_json TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          version INTEGER NOT NULL,
          min_client_version TEXT NOT NULL,
          cached_at INTEGER NOT NULL
        );
      ''');
      // Additive upgrades for databases created by an earlier app build.
      for (final statement in [
        "ALTER TABLE sms_candidate_rule_bundles ADD COLUMN namespace TEXT NOT NULL DEFAULT '__legacy__'",
        'ALTER TABLE sms_candidate_rule_bundles ADD COLUMN assignment_id TEXT',
        'ALTER TABLE sms_candidate_rule_bundles ADD COLUMN stage_version INTEGER NOT NULL DEFAULT 1',
      ]) {
        try {
          database.db.execute(statement);
        } catch (_) {}
      }
    } catch (_) {
      // Database might be closed during disposal
    }
  }

  SmsRuleBundle? loadActiveBundleSync({String clientVersion = '1.0.0'}) {
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
        final bundle = SmsRuleBundle.fromJson(decoded, verifySha: true);
        return bundle == null ||
                !_compatible(bundle.minClientVersion, clientVersion)
            ? null
            : bundle;
      } else if (decoded is Map) {
        final bundle = SmsRuleBundle.fromJson(
          decoded.cast<String, dynamic>(),
          verifySha: true,
        );
        return bundle == null ||
                !_compatible(bundle.minClientVersion, clientVersion)
            ? null
            : bundle;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<SmsRuleBundle?> loadActiveBundle({
    String clientVersion = '1.0.0',
  }) async {
    return loadActiveBundleSync(clientVersion: clientVersion);
  }

  List<SmsCandidateRuleBundle> loadCandidateBundlesSync({
    String clientVersion = '1.0.0',
    String namespace = '__legacy__',
  }) {
    _ensureTable();
    try {
      return database.db
          .select(
            'SELECT raw_json FROM sms_candidate_rule_bundles WHERE namespace=?',
            [namespace],
          )
          .map((row) {
            final value = jsonDecode(row['raw_json'] as String);
            return value is Map<String, dynamic>
                ? SmsCandidateRuleBundle.fromJson(value)
                : SmsCandidateRuleBundle.fromJson(
                    value.cast<String, dynamic>(),
                  );
          })
          .whereType<SmsCandidateRuleBundle>()
          .where(
            (candidate) =>
                _compatible(candidate.bundle.minClientVersion, clientVersion),
          )
          .toList(growable: false);
    } catch (_) {
      return const <SmsCandidateRuleBundle>[];
    }
  }

  Future<bool> saveBundle(
    Map<String, dynamic> json, {
    String clientVersion = '1.0.0',
  }) async {
    _ensureTable();
    final bundle = SmsRuleBundle.fromJson(json, verifySha: true);
    if (bundle == null || !_compatible(bundle.minClientVersion, clientVersion))
      return false;

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

  static String computeSharedCategoryRulesSha256({
    required int version,
    required String minClientVersion,
    required List<SmsSharedCategoryRule> rules,
  }) {
    final sorted = [...rules]
      ..sort((a, b) {
        final merchant = a.merchantKey.compareTo(b.merchantKey);
        if (merchant != 0) return merchant;
        final sender = a.senderKey.compareTo(b.senderKey);
        if (sender != 0) return sender;
        final context = a.contextKey.compareTo(b.contextKey);
        if (context != 0) return context;
        final family = a.factFamily.compareTo(b.factFamily);
        if (family != 0) return family;
        return a.categorySlug.compareTo(b.categorySlug);
      });
    final canonical = jsonEncode({
      'categoryRulesV2Version': version,
      'minClientVersion': minClientVersion,
      'categoryRulesV2': sorted.map((rule) => rule.toJson()).toList(),
    });
    return crypto.sha256.convert(utf8.encode(canonical)).toString();
  }

  /// Replaces the cached cross-user mapping only after the complete payload
  /// passes the contract version, hash, threshold, and exact-key checks.
  Future<bool> saveSharedCategoryRules(
    Map<String, dynamic> json, {
    String clientVersion = '1.0.0',
  }) async {
    try {
      final version = json['categoryRulesV2Version'];
      final minimum = json['categoryRulesV2MinClientVersion'];
      final sha = (json['categoryRulesV2Sha256'] as String?)?.toLowerCase();
      final raw = json['categoryRulesV2'];
      if (version is! int ||
          version != 2 ||
          minimum is! String ||
          !_compatible(minimum, clientVersion) ||
          raw is! List ||
          sha == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha))
        return false;
      final rules = <SmsSharedCategoryRule>[];
      for (final item in raw) {
        final parsed = item is Map<String, dynamic>
            ? SmsSharedCategoryRule.fromJson(item)
            : item is Map
            ? SmsSharedCategoryRule.fromJson(item.cast<String, dynamic>())
            : null;
        if (parsed == null) return false;
        rules.add(parsed);
      }
      final tupleKeys = rules.map((rule) => SmsSharedCategoryRule.tupleKey(
        merchantKey: rule.merchantKey,
        senderKey: rule.senderKey,
        contextKey: rule.contextKey,
        factFamily: rule.factFamily,
      )).toSet();
      if (tupleKeys.length != rules.length) return false;
      final expected = computeSharedCategoryRulesSha256(
        version: version,
        minClientVersion: minimum,
        rules: rules,
      );
      if (expected != sha) return false;
      database.db.execute(
        '''INSERT OR REPLACE INTO sms_shared_category_rule_bundles
           (id, raw_json, sha256, version, min_client_version, cached_at)
           VALUES (1, ?, ?, ?, ?, ?)''',
        [
          jsonEncode(rules.map((rule) => rule.toJson()).toList()),
          sha,
          version,
          minimum,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> loadSharedCategoryRulesSync({
    String clientVersion = '1.0.0',
  }) {
    _ensureTable();
    try {
      final rows = database.db.select(
        'SELECT raw_json, sha256, version, min_client_version '
        'FROM sms_shared_category_rule_bundles WHERE id=1',
      );
      if (rows.isEmpty) return const {};
      final row = rows.single;
      final version = row['version'] as int;
      final minimum = row['min_client_version'] as String;
      // A persisted v1 merchant-only cache is unsafe, including while offline.
      if (version != 2 || !_compatible(minimum, clientVersion)) return const {};
      final decoded = jsonDecode(row['raw_json'] as String);
      if (decoded is! List) return const {};
      final rules = <SmsSharedCategoryRule>[];
      for (final item in decoded) {
        final parsed = item is Map<String, dynamic>
            ? SmsSharedCategoryRule.fromJson(item)
            : item is Map
            ? SmsSharedCategoryRule.fromJson(item.cast<String, dynamic>())
            : null;
        if (parsed == null) return const {};
        rules.add(parsed);
      }
      if (computeSharedCategoryRulesSha256(
            version: version,
            minClientVersion: minimum,
            rules: rules,
          ) !=
          row['sha256'])
        return const {};
      return {
        for (final rule in rules)
          SmsSharedCategoryRule.tupleKey(
            merchantKey: rule.merchantKey,
            senderKey: rule.senderKey,
            contextKey: rule.contextKey,
            factFamily: rule.factFamily,
          ): rule.categorySlug,
      };
    } catch (_) {
      return const {};
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
    String clientVersion = '1.0.0',
    String namespace = '__legacy__',
  }) async {
    try {
      final active = loadActiveBundleSync(clientVersion: clientVersion);
      final sinceVersion = active?.bundleVersion ?? 0;
      final uri = Uri.parse(
        '$apiBaseUrl/sms/rules/active?since_version=$sinceVersion',
      );

      final headers = <String, String>{
        'Accept': 'application/json',
        if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      };

      final res = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return false;
      if (decoded.containsKey('categoryRulesV2') &&
          decoded.containsKey('categoryRulesV2Version') &&
          decoded.containsKey('categoryRulesV2MinClientVersion') &&
          decoded.containsKey('categoryRulesV2Sha256')) {
        await saveSharedCategoryRules(
          decoded.cast<String, dynamic>(),
          clientVersion: clientVersion,
        );
      }

      // Server indicates a rollback occurred
      if (decoded['rolledBack'] == true) {
        final newVersion = decoded['bundleVersion'] as int? ?? 0;
        if (newVersion == 0) {
          await rollback();
          await _saveCandidateBundles(
            decoded['candidateRules'],
            clientVersion: clientVersion,
            namespace: namespace,
            revokedCandidateIds: decoded['revokedCandidateIds'],
          );
          return true;
        } else {
          // Deactivate newer local bundles and save the lower active version
          await rollback();
          if (decoded is Map<String, dynamic>) {
            final saved = await saveBundle(
              decoded,
              clientVersion: clientVersion,
            );
            await _saveCandidateBundles(
              decoded['candidateRules'],
              clientVersion: clientVersion,
              namespace: namespace,
              revokedCandidateIds: decoded['revokedCandidateIds'],
            );
            return saved;
          }
          return true;
        }
      }

      if (decoded['upToDate'] == true) {
        // Older compatible servers may omit candidate metadata from a 304
        // style response. Preserve the last verified assignment cache in
        // that case; explicit metadata remains authoritative.
        if (decoded.containsKey('candidateRules') ||
            decoded.containsKey('revokedCandidateIds')) {
          await _saveCandidateBundles(
            decoded['candidateRules'],
            clientVersion: clientVersion,
            namespace: namespace,
            revokedCandidateIds: decoded['revokedCandidateIds'],
          );
        }
        return false;
      }

      if (decoded is Map<String, dynamic>) {
        final saved = await saveBundle(decoded, clientVersion: clientVersion);
        await _saveCandidateBundles(
          decoded['candidateRules'],
          clientVersion: clientVersion,
          namespace: namespace,
          revokedCandidateIds: decoded['revokedCandidateIds'],
        );
        return saved;
      } else {
        final mapped = decoded.cast<String, dynamic>();
        final saved = await saveBundle(mapped, clientVersion: clientVersion);
        await _saveCandidateBundles(
          mapped['candidateRules'],
          clientVersion: clientVersion,
          namespace: namespace,
          revokedCandidateIds: mapped['revokedCandidateIds'],
        );
        return saved;
      }
    } catch (_) {
      // Offline or network timeout fails open without crashing
      return false;
    }
  }

  Future<void> _saveCandidateBundles(
    dynamic raw, {
    String clientVersion = '1.0.0',
    String namespace = '__legacy__',
    dynamic revokedCandidateIds,
  }) async {
    _ensureTable();
    final parsed = <SmsCandidateRuleBundle>[];
    if (raw is List) {
      for (final item in raw) {
        final candidate = item is Map<String, dynamic>
            ? SmsCandidateRuleBundle.fromJson(item)
            : item is Map
            ? SmsCandidateRuleBundle.fromJson(item.cast<String, dynamic>())
            : null;
        if (candidate != null &&
            _compatible(candidate.bundle.minClientVersion, clientVersion)) {
          parsed.add(candidate);
        }
      }
    }
    final revoked = revokedCandidateIds is List
        ? revokedCandidateIds.map((value) => value.toString()).toSet()
        : const <String>{};
    try {
      database.db.execute(
        'DELETE FROM sms_candidate_rule_bundles WHERE namespace=?',
        [namespace],
      );
      for (final candidate in parsed) {
        if (revoked.contains(candidate.candidateId)) continue;
        final json = {
          'candidateId': candidate.candidateId,
          'stage': candidate.stage,
          'mode': candidate.mode,
          'assignmentId': candidate.assignmentId,
          'stageVersion': candidate.stageVersion,
          'bundleVersion': candidate.bundle.bundleVersion,
          'sha256': candidate.bundle.sha256,
          'publishedAt': candidate.bundle.publishedAt.toUtc().toIso8601String(),
          'minClientVersion': candidate.bundle.minClientVersion,
          'rules': [
            for (final rule in candidate.bundle.rules)
              {
                'id': rule.id,
                'family': rule.family.wireValue,
                'senderPattern': rule.senderPattern,
                'regex': rule.regexPattern,
                'fieldMap': rule.fieldMap,
                'defaultFields': rule.defaultFields,
                'confidence': rule.confidence,
              },
          ],
        };
        database.db.execute(
          'INSERT OR REPLACE INTO sms_candidate_rule_bundles(namespace,candidate_id,stage,mode,assignment_id,stage_version,raw_json,cached_at) VALUES (?,?,?,?,?,?,?,?)',
          [
            namespace,
            '$namespace::${candidate.candidateId}',
            candidate.stage,
            candidate.mode,
            candidate.assignmentId,
            candidate.stageVersion,
            jsonEncode(json),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
    } catch (_) {}
  }

  bool _compatible(String minimum, String current) =>
      !isVersionOlderThan(current, minimum);
}
