import 'dart:convert';

import 'sync_state_store.dart';

/// A message the person set aside from AI auto-resolved with "Dismiss" ("this is
/// not a real transaction"), kept so History can list it and Recover can put it
/// back exactly where it came from.
///
/// Stored as one `v2_sync_state` row per message, key `dismissal:<sourceKey>`,
/// the same place the phone keeps its other small per-message markers (`trace:`,
/// `hidden-event:`). Nothing here is a schema change: an install that never
/// dismissed anything has no such row, and an older build ignores the rows.
class AutoDismissal {
  const AutoDismissal({
    required this.sourceKey,
    required this.kind,
    required this.dismissedAt,
    this.origin = originAutoResolved,
    this.entryId,
    this.eventId,
    this.restoredDecidedAt,
  });

  /// It was on Needs review when it was set aside.
  static const originNeedsReview = 'needs_review';

  /// It was on AI auto-resolved when it was set aside.
  static const originAutoResolved = 'auto_resolved';

  /// A transaction the AI filed: dismissing it took it out of the totals.
  static const kindTransaction = 'transaction';

  /// A message the AI read that made no transaction: dismissing it only hides it.
  static const kindRead = 'read';

  final String sourceKey;

  /// [kindTransaction] or [kindRead].
  final String kind;

  /// Where it came from, and where Recover puts it back.
  final String origin;
  final DateTime dismissedAt;

  /// The transaction row that was hidden (a transaction's `v2:<event id>`).
  final String? entryId;
  final String? eventId;

  /// Set once the person recovered a dismissed transaction: the time the ledger
  /// stamped on its event by the restore. A transaction whose event still carries
  /// exactly this time was put back, not changed by the person, so it is AI
  /// auto-resolved again. Any later edit moves the time on and ends the exception.
  final String? restoredDecidedAt;

  bool get restored => restoredDecidedAt != null;
  bool get isTransaction => kind == kindTransaction;

  AutoDismissal asRestored(String decidedAt) => AutoDismissal(
    sourceKey: sourceKey,
    kind: kind,
    origin: origin,
    dismissedAt: dismissedAt,
    entryId: entryId,
    eventId: eventId,
    restoredDecidedAt: decidedAt,
  );

  Map<String, Object?> toJson() => {
    'kind': kind,
    'origin': origin,
    'at': dismissedAt.toUtc().toIso8601String(),
    'entryId': ?entryId,
    'eventId': ?eventId,
    'restoredDecidedAt': ?restoredDecidedAt,
  };

  static AutoDismissal? fromJson(String sourceKey, Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    final kind = raw['kind'];
    if (at == null || (kind != kindTransaction && kind != kindRead)) {
      return null;
    }
    return AutoDismissal(
      sourceKey: sourceKey,
      kind: kind as String,
      origin: raw['origin'] == originNeedsReview
          ? originNeedsReview
          : originAutoResolved,
      dismissedAt: at,
      entryId: raw['entryId'] as String?,
      eventId: raw['eventId'] as String?,
      restoredDecidedAt: raw['restoredDecidedAt'] as String?,
    );
  }
}

/// True when [eventId] was put back by Recover and its decision time is still the
/// one that restore stamped ([DismissalStore.restoredMarks]): the person has not
/// decided it since.
bool isRestoreOnly(Map<String, DateTime> marks, String eventId, DateTime? decidedAt) {
  final mark = marks[eventId];
  return mark != null && decidedAt != null && decidedAt.isAtSameMomentAs(mark);
}

class DismissalStore {
  const DismissalStore(this.state);
  final SyncStateStore state;

  static const _prefix = 'dismissal:';

  AutoDismissal? get(String sourceKey) {
    final raw = state.get('$_prefix$sourceKey');
    if (raw == null) return null;
    try {
      return AutoDismissal.fromJson(sourceKey, jsonDecode(raw));
    } catch (_) {
      return null; // a record this build cannot read is as good as none
    }
  }

  void put(AutoDismissal dismissal) => state.put(
    '$_prefix${dismissal.sourceKey}',
    jsonEncode(dismissal.toJson()),
  );

  void remove(String sourceKey) => state.db.execute(
    'DELETE FROM v2_sync_state WHERE namespace=? AND key=?',
    [state.namespace, '$_prefix$sourceKey'],
  );

  /// The events Recover put back, with the decision time its restore stamped
  /// (event id to time). An event whose decision time is still this one was put
  /// back, not decided by the person: it is AI auto-resolved again, and a later
  /// rejection of its AI rule may take its reading back like any other.
  /// History dismissal records are kept per device: they are not synced, so
  /// another phone of the same account lists nothing under History for them.
  Map<String, DateTime> restoredMarks() => {
    for (final d in all())
      if (d.eventId != null && d.restoredDecidedAt != null)
        if (DateTime.tryParse(d.restoredDecidedAt!) case final at?) d.eventId!: at,
  };

  /// Every record of this account, dismissed and restored. One range scan over
  /// the primary key (`;` follows `:`), never a table scan.
  List<AutoDismissal> all() {
    final out = <AutoDismissal>[];
    for (final row in state.db.select(
      'SELECT key,value FROM v2_sync_state WHERE namespace=? AND key>=? AND key<?',
      [state.namespace, _prefix, 'dismissal;'],
    )) {
      try {
        final parsed = AutoDismissal.fromJson(
          (row['key'] as String).substring(_prefix.length),
          jsonDecode(row['value'] as String),
        );
        if (parsed != null) out.add(parsed);
      } catch (_) {
        continue;
      }
    }
    return out;
  }
}
