import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'local/app_database.dart';
import 'local_sms_parser.dart';

enum NeedsReviewKind {
  transaction,
  commitment,
  securityOrServiceAlert,
  investmentSettlement,
  mandate,
}

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
/// features that happen to share a trigger event (a failed parse). The
/// existing review item stays on-device. If the server parser cannot classify
/// it, the AI fallback may send a redacted copy to the configured Gemini
/// provider; local review remains available when AI is disabled or fails.
/// ui-spec D4 explicitly wants "raw text shown for context," which a
/// digit-stripped admin record structurally cannot provide. Rather than
/// requesting a schema change to a table designed for anonymized telemetry
/// (a real, separate decision — flagged, not made unilaterally here), this
/// keeps the raw SMS exactly where it already lives today: the device that
/// received it. The separate, explicit AI fallback uploads only after the
/// normal financial-message filter and removes sensitive identifiers on the
/// server before calling Gemini.
class NeedsReviewItem {
  final String id;
  final String sender;
  final String body;
  final String? reason;
  final DateTime receivedAt;
  final NeedsReviewKind kind;
  final List<Map<String, dynamic>>? aiSuggestions;

  const NeedsReviewItem({
    required this.id,
    required this.sender,
    required this.body,
    this.reason,
    required this.receivedAt,
    this.kind = NeedsReviewKind.transaction,
    this.aiSuggestions,
  });

  NeedsReviewItem copyWith({
    NeedsReviewKind? kind,
    List<Map<String, dynamic>>? aiSuggestions,
  }) =>
      NeedsReviewItem(
        id: id,
        sender: sender,
        body: body,
        reason: reason,
        receivedAt: receivedAt,
        kind: kind ?? this.kind,
        aiSuggestions: aiSuggestions ?? this.aiSuggestions,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'body': body,
    'reason': reason,
    'receivedAt': receivedAt.toIso8601String(),
    'kind': kind.name,
    if (aiSuggestions != null) 'aiSuggestions': aiSuggestions,
  };

  factory NeedsReviewItem.fromJson(Map<String, dynamic> json) {
    final rawSuggestions = json['aiSuggestions'];
    return NeedsReviewItem(
      id: json['id'] as String,
      sender: json['sender'] as String,
      body: json['body'] as String,
      reason: json['reason'] as String?,
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      kind: NeedsReviewKind.values.firstWhere(
        (kind) => kind.name == json['kind'],
        orElse: () => NeedsReviewKind.transaction,
      ),
      aiSuggestions: rawSuggestions is List
          ? rawSuggestions
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : null,
    );
  }
}

const _needsReviewKey = 'pandapay_app.needs_review_queue_v1';

/// Synchronous capture path used by the local SMS parser, which deliberately
/// remains synchronous so foreground/background capture share one transaction.
/// The stable SMS id makes this insert idempotent.
void addNeedsReviewSync(
  AppDatabase database,
  String namespace,
  NeedsReviewItem item,
) {
  if (NeedsReviewRepository.isNoiseItem(item)) return;
  final resolved = NeedsReviewRepository.resolveItemKind(item);
  database.db.execute(
    'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
  );
  final existingRows = database.db.select(
    'SELECT payload FROM local_needs_review WHERE namespace = ?',
    [namespace],
  );
  final normalizedSender = resolved.sender.trim().toLowerCase();
  final normalizedBody = NeedsReviewRepository.normalizeBody(resolved.body);
  for (final row in existingRows) {
    try {
      final payload = row['payload'] as String?;
      if (payload == null) continue;
      final existing = NeedsReviewItem.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      if (existing.id == resolved.id) {
        return;
      }
      final sameSender =
          existing.sender.trim().toLowerCase() == normalizedSender;
      final sameBody =
          NeedsReviewRepository.normalizeBody(existing.body) == normalizedBody;
      final closeInTime =
          existing.receivedAt.difference(resolved.receivedAt).abs() <=
          const Duration(minutes: 5);
      if (sameSender && sameBody && closeInTime) {
        return;
      }
    } catch (_) {}
  }
  database.db.execute(
    'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
    [namespace, resolved.id, jsonEncode(resolved.toJson())],
  );
}

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
      final items = db.db
          .select('SELECT payload FROM local_needs_review WHERE namespace=?', [
            namespace,
          ])
          .map(
            (r) => resolveItemKind(
              NeedsReviewItem.fromJson(
                jsonDecode(r['payload'] as String) as Map<String, dynamic>,
              ),
            ),
          )
          .toList();
      final noise = items.where(_isNoise).map((item) => item.id).toList();
      if (noise.isNotEmpty) await removeAll(noise);
      return items.where((item) => !_isNoise(item)).toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final items = raw
        .map(
          (s) => resolveItemKind(
            NeedsReviewItem.fromJson(jsonDecode(s) as Map<String, dynamic>),
          ),
        )
        .toList();
    final noise = items.where(_isNoise).map((item) => item.id).toList();
    if (noise.isNotEmpty) await removeAll(noise);
    return items.where((item) => !_isNoise(item)).toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }

  static bool isSecurityOrServiceAlert(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:transaction\s+check\s+alert|check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|call\s+forwarding\b|sim\s+swap|service\s+alert|fraud\s+alert|suspicious\s+activity)\b',
    ).hasMatch(text);
  }

  static bool isInvestmentSettlement(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:kotak\s+neo|demat|settlement\s+payout|running\s+a/?c\s+settlement)\b',
    ).hasMatch(text);
  }

  static bool isMandateReview(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:auto[-\s]?pay|e[-\s]?mandate|standing\s+instruction)\b',
    ).hasMatch(text);
  }

  static NeedsReviewItem resolveItemKind(NeedsReviewItem item) {
    if (item.kind != NeedsReviewKind.transaction) return item;
    if (isSecurityOrServiceAlert(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.securityOrServiceAlert);
    }
    if (isInvestmentSettlement(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.investmentSettlement);
    }
    if (isMandateReview(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.mandate);
    }
    return item;
  }

  static bool isNoiseItem(NeedsReviewItem item) {
    final resolved = resolveItemKind(item);
    if (resolved.kind == NeedsReviewKind.securityOrServiceAlert) {
      return true;
    }
    if (resolved.kind == NeedsReviewKind.investmentSettlement ||
        resolved.kind == NeedsReviewKind.mandate) {
      return false;
    }
    return LocalSmsParser.isNonTransactionNoise(resolved.sender, resolved.body);
  }

  bool _isNoise(NeedsReviewItem item) => isNoiseItem(item);

  Future<void> add(NeedsReviewItem item) async {
    if (isNoiseItem(item)) return;
    final resolved = resolveItemKind(item);
    if (loadDatabase != null) {
      final db = await _database();
      final current = await fetchAll();
      if (current.any(
        (old) =>
            old.id != resolved.id &&
            old.sender.trim().toLowerCase() ==
                resolved.sender.trim().toLowerCase() &&
            _normalizeBody(old.body) == _normalizeBody(resolved.body) &&
            old.receivedAt.difference(resolved.receivedAt).abs() <=
                const Duration(minutes: 5),
      )) {
        return;
      }
      db.db.execute(
        'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
        [namespace, resolved.id, jsonEncode(resolved.toJson())],
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final normalizedSender = resolved.sender.trim().toLowerCase();
    // SMS gateways sometimes add indentation/newlines when the same alert is
    // delivered through two channels. Treat that as the same message while
    // preserving the original body for display and one-tap resolution.
    final normalizedBody = _normalizeBody(resolved.body);
    var duplicate = false;
    final withoutRetry = raw.where((entry) {
      try {
        final existing = NeedsReviewItem.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        );
        if (existing.id == resolved.id) return false;
        final sameMessage =
            existing.sender.trim().toLowerCase() == normalizedSender &&
            _normalizeBody(existing.body) == normalizedBody;
        final closeInTime =
            existing.receivedAt.difference(resolved.receivedAt).abs() <=
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
      jsonEncode(resolved.toJson()),
    ]);
  }

  /// Persists owner-scoped, validated Gemini facts onto an existing local
  /// review row. It deliberately never recreates a row that the user already
  /// dismissed or resolved while the network request was in flight.
  Future<bool> updateAiSuggestions(
    String id,
    List<Map<String, dynamic>> suggestions,
  ) async {
    final items = await fetchAll();
    final current = items.where((item) => item.id == id).firstOrNull;
    if (current == null ||
        jsonEncode(current.aiSuggestions ?? const []) ==
            jsonEncode(suggestions)) {
      return false;
    }
    final updated = jsonEncode(
      current.copyWith(aiSuggestions: suggestions).toJson(),
    );
    if (loadDatabase != null) {
      (await _database()).db.execute(
        'UPDATE local_needs_review SET payload=? WHERE namespace=? AND id=?',
        [updated, namespace, id],
      );
      return true;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    var changed = false;
    final patched = raw.map((entry) {
      final value = jsonDecode(entry) as Map<String, dynamic>;
      if (value['id'] != id) return entry;
      changed = true;
      return updated;
    }).toList();
    if (changed) await prefs.setStringList(_needsReviewKey, patched);
    return changed;
  }

  static String normalizeBody(String body) =>
      body.trim().replaceAll(RegExp(r'\s+'), ' ');

  String _normalizeBody(String body) => normalizeBody(body);

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
