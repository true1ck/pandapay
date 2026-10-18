import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'local/app_database.dart';

/// Task D-4 (ui-spec D4 Needs Review Queue) — one raw SMS the parser
/// couldn't match, kept entirely ON-DEVICE.
///
/// **Why on-device, not server-side**: `parser_failures` (api/'s existing
/// admin-triage table) is deliberately admin-only (`pandapay.is_admin()`
/// RLS) and has no `profile_id` column at all — checked against the live
/// migration, not just database.sql — plus a `redacted_shape_has_no_digits`
/// CHECK constraint that strips every digit before it's ever stored. That
/// table exists to help admins tune parser_patterns across ALL users, not
/// to give one user back their own message text — the two are different
/// features that happen to share a trigger event (a failed parse).
/// ui-spec D4 explicitly wants "raw text shown for context," which a
/// digit-stripped admin record structurally cannot provide. Rather than
/// requesting a schema change to a table designed for anonymized telemetry
/// (a real, separate decision — flagged, not made unilaterally here), this
/// keeps the raw SMS exactly where it already lives today: the device that
/// received it. Nothing here is ever uploaded.
class NeedsReviewItem {
  final String id;
  final String sender;
  final String body;
  final String? reason;
  final DateTime receivedAt;

  const NeedsReviewItem({
    required this.id,
    required this.sender,
    required this.body,
    this.reason,
    required this.receivedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'body': body,
    'reason': reason,
    'receivedAt': receivedAt.toIso8601String(),
  };

  factory NeedsReviewItem.fromJson(Map<String, dynamic> json) =>
      NeedsReviewItem(
        id: json['id'] as String,
        sender: json['sender'] as String,
        body: json['body'] as String,
        reason: json['reason'] as String?,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );
}

const _needsReviewKey = 'pandapay_app.needs_review_queue_v1';

/// Plain on-device store, same SharedPreferences mechanism
/// dueDateRemindersProvider (providers.dart) already uses for a similar
/// "no server round-trip needed, this is purely local" case.
class NeedsReviewRepository {
  final String namespace;
  final Future<AppDatabase> Function()? loadDatabase;
  NeedsReviewRepository({this.namespace = 'legacy', this.loadDatabase});
  Future<AppDatabase> _database() async {
    final db = await loadDatabase!();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getStringList(_needsReviewKey);
    if (old != null && old.isNotEmpty) {
      final corrupt = <String>[];
      db.db.execute('SAVEPOINT migrate_review');
      try {
        for (final raw in old) {
          NeedsReviewItem item;
          try {
            item = NeedsReviewItem.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (_) {
            corrupt.add(raw);
            continue;
          }
          db.db.execute(
            "INSERT OR IGNORE INTO local_needs_review VALUES ('legacy',?,?)",
            [item.id, jsonEncode(item.toJson())],
          );
        }
        db.db.execute('RELEASE SAVEPOINT migrate_review');
      } catch (_) {
        db.db.execute('ROLLBACK TO SAVEPOINT migrate_review');
        db.db.execute('RELEASE SAVEPOINT migrate_review');
        rethrow;
      }
      if (corrupt.isEmpty) {
        await prefs.remove(_needsReviewKey);
      } else {
        await prefs.setStringList(_needsReviewKey, corrupt);
      }
    }
    return db;
  }

  Future<List<NeedsReviewItem>> fetchAll() async {
    if (loadDatabase != null) {
      final db = await _database();
      return db.db
          .select('SELECT payload FROM local_needs_review WHERE namespace=?', [
            namespace,
          ])
          .map(
            (r) => NeedsReviewItem.fromJson(
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ),
          )
          .toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    return raw
        .map(
          (s) =>
              NeedsReviewItem.fromJson(jsonDecode(s) as Map<String, dynamic>),
        )
        .toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }

  Future<void> add(NeedsReviewItem item) async {
    if (loadDatabase != null) {
      final db = await _database();
      final current = await fetchAll();
      if (current.any(
        (old) =>
            old.id != item.id &&
            old.sender.trim().toLowerCase() ==
                item.sender.trim().toLowerCase() &&
            _normalizeBody(old.body) == _normalizeBody(item.body) &&
            old.receivedAt.difference(item.receivedAt).abs() <=
                const Duration(minutes: 5),
      )) {
        return;
      }
      db.db.execute(
        'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
        [namespace, item.id, jsonEncode(item.toJson())],
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final normalizedSender = item.sender.trim().toLowerCase();
    // SMS gateways sometimes add indentation/newlines when the same alert is
    // delivered through two channels. Treat that as the same message while
    // preserving the original body for display and one-tap resolution.
    final normalizedBody = _normalizeBody(item.body);
    var duplicate = false;
    final withoutRetry = raw.where((entry) {
      try {
        final existing = NeedsReviewItem.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        );
        if (existing.id == item.id) return false;
        final sameMessage =
            existing.sender.trim().toLowerCase() == normalizedSender &&
            _normalizeBody(existing.body) == normalizedBody;
        final closeInTime =
            existing.receivedAt.difference(item.receivedAt).abs() <=
            const Duration(minutes: 5);
        if (sameMessage && closeInTime) duplicate = true;
        return true;
      } catch (_) {
        return true;
      }
    }).toList();
    if (duplicate) return;
    await prefs.setStringList(_needsReviewKey, [
      ...withoutRetry,
      jsonEncode(item.toJson()),
    ]);
  }

  String _normalizeBody(String body) =>
      body.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// "Not a transaction" dismiss, or a successful one-tap-fill resolution —
  /// either way, the item leaves the queue. Which one happened is the
  /// caller's concern (screen-level), not this store's.
  Future<void> remove(String id) async {
    if (loadDatabase != null) {
      (await _database()).db.execute(
        'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
        [namespace, id],
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw
        .where((s) => (jsonDecode(s) as Map<String, dynamic>)['id'] != id)
        .toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }

  Future<void> removeAll(Iterable<String> ids) async {
    if (loadDatabase != null) {
      final db = await _database();
      for (final id in ids) {
        db.db.execute(
          'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
          [namespace, id],
        );
      }
      return;
    }
    final idSet = ids.toSet();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw
        .where(
          (s) => !idSet.contains((jsonDecode(s) as Map<String, dynamic>)['id']),
        )
        .toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }
}
