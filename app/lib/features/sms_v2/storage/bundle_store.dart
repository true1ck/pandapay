import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Stores exact signed wire JSON. The signature verifier is required for
/// downloads and cache reads, including after a process restart.
class BundleStore {
  BundleStore(this.db, {required this.verify, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final Database db;
  final Future<RuleBundle?> Function(String) verify;
  final DateTime Function() clock;
  String? _cachedHash;
  RuleBundle? _cached;

  /// The SMS runtime is rebuilt whenever categories, the catalogue or the app
  /// version resolve, and every new BundleStore used to re-parse, re-validate,
  /// re-hash and re-verify the same large bundle on the UI thread (seconds on
  /// a phone, repeated several times at startup). A bundle that already passed
  /// verification for this exact stored JSON on this database is reused.
  static final _verifiedByDb = Expando<(String, RuleBundle)>('verifiedBundle');

  Future<bool> install(String encoded) async {
    final bundle = await verify(encoded);
    if (bundle == null ||
        bundle.bundleVersion == 0 ||
        !bundle.expiresAt.isAfter(clock())) {
      return false;
    }
    final installed = await _latest();
    if (installed != null) {
      if (installed.bundleVersion > bundle.bundleVersion) return false;
      if (installed.bundleVersion == bundle.bundleVersion) {
        Map<String, Object?> content(RuleBundle value) => value.toJson()
          ..remove('signature')
          ..remove('expiresAt')
          ..remove('createdAt');
        if (canonicalJson(content(installed)) !=
                canonicalJson(content(bundle)) ||
            !bundle.expiresAt.isAfter(installed.expiresAt)) {
          return false;
        }
      }
    }
    // Compile before committing so an incompatible engine keeps the last copy.
    try {
      RuleEngine().compiled(bundle);
    } on BundleRefusedException {
      return false;
    }
    db.execute(
      '''
INSERT INTO v2_rule_bundle(bundle_version,json,sha256,signature,expires_at,fetched_at)
VALUES(?,?,?,?,?,?) ON CONFLICT(bundle_version) DO UPDATE SET
  json=excluded.json, sha256=excluded.sha256, signature=excluded.signature,
  expires_at=excluded.expires_at, fetched_at=excluded.fetched_at
WHERE v2_rule_bundle.expires_at < excluded.expires_at
''',
      [
        bundle.bundleVersion,
        encoded,
        sha256.convert(utf8.encode(encoded)).toString(),
        jsonEncode(bundle.signature!.toJson()),
        bundle.expiresAt.toUtc().toIso8601String(),
        clock().toUtc().toIso8601String(),
      ],
    );
    _cached = null;
    _cachedHash = null;
    _verifiedByDb[db] = null;
    return db.updatedRows != 0;
  }

  Future<RuleBundle?> _latest() async {
    for (final row in db.select(
      'SELECT json,sha256 FROM v2_rule_bundle ORDER BY bundle_version DESC',
    )) {
      final encoded = row['json'] as String;
      final hash = sha256.convert(utf8.encode(encoded)).toString();
      if (hash != row['sha256']) continue;
      if (_cachedHash == hash) return _cached;
      final shared = _verifiedByDb[db];
      if (shared != null && shared.$1 == hash) {
        _cached = shared.$2;
        _cachedHash = hash;
        return shared.$2;
      }
      final bundle = await verify(encoded);
      if (bundle == null) continue;
      try {
        RuleEngine().compiled(bundle);
      } on BundleRefusedException {
        continue;
      }
      _cached = bundle;
      _cachedHash = hash;
      _verifiedByDb[db] = (hash, bundle);
      return bundle;
    }
    return null;
  }

  /// A failed download keeps the last verified bundle, even when stale.
  /// The version-zero asset is the explicit empty baseline from WP-01.
  Future<RuleBundle> load({required String shippedJson}) async {
    final installed = await _latest();
    if (installed != null) return installed;
    final signedBaseline = await verify(shippedJson);
    if (signedBaseline != null) return signedBaseline;
    final placeholder = RuleBundle.fromJson(
      (jsonDecode(shippedJson) as Map).cast<String, Object?>(),
    );
    if (placeholder.bundleVersion != 0 ||
        placeholder.rules.isNotEmpty ||
        placeholder.ignoreRules.isNotEmpty ||
        placeholder.signature != null) {
      throw StateError('Shipped SMS baseline is not trusted');
    }
    return placeholder;
  }
}
