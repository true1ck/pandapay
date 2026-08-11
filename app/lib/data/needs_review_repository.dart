import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  factory NeedsReviewItem.fromJson(Map<String, dynamic> json) => NeedsReviewItem(
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
  Future<List<NeedsReviewItem>> fetchAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    return raw.map((s) => NeedsReviewItem.fromJson(jsonDecode(s) as Map<String, dynamic>)).toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }

  Future<void> add(NeedsReviewItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    await prefs.setStringList(_needsReviewKey, [...raw, jsonEncode(item.toJson())]);
  }

  /// "Not a transaction" dismiss, or a successful one-tap-fill resolution —
  /// either way, the item leaves the queue. Which one happened is the
  /// caller's concern (screen-level), not this store's.
  Future<void> remove(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw.where((s) => (jsonDecode(s) as Map<String, dynamic>)['id'] != id).toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }

  Future<void> removeAll(Iterable<String> ids) async {
    final idSet = ids.toSet();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw.where((s) => !idSet.contains((jsonDecode(s) as Map<String, dynamic>)['id'])).toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }
}
