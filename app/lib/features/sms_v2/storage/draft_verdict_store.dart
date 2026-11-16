import 'dart:convert';

import 'sync_state_store.dart';

/// What this phone decided about the AI draft it holds for a layout, kept next
/// to `ai:<templateHash>` in v2_sync_state as `draft:verdict:<templateHash>`.
/// The verdict belongs to one draft id: a different id (a replacement draft)
/// clears it, see [clearIfReplaced].
class DraftVerdictStore {
  const DraftVerdictStore(this.state);
  final SyncStateStore state;

  static const prefix = 'draft:verdict:';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// The draft id carried by a stored `ai:` result; null when it has none.
  static String? draftIdOf(Map result) {
    final id = result['draftId'];
    return id is String && _uuid.hasMatch(id) ? id : null;
  }

  ({String draftId, bool rejected})? get(String remoteHash) {
    final raw = state.get('$prefix$remoteHash');
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw) as Map;
      final id = value['draftId'];
      if (id is! String) return null;
      return (draftId: id, rejected: value['verdict'] == 'rejected');
    } catch (_) {
      return null;
    }
  }

  void put(String remoteHash, String draftId, {required bool rejected}) =>
      state.put(
        '$prefix$remoteHash',
        jsonEncode({
          'draftId': draftId,
          'verdict': rejected ? 'rejected' : 'passed',
        }),
      );

  /// True when [draftId] is the draft this phone rejected for [remoteHash].
  bool isRejected(String remoteHash, String? draftId) {
    final verdict = get(remoteHash);
    return verdict != null && verdict.rejected && verdict.draftId == draftId;
  }

  /// A new result arrived for [remoteHash]: a verdict about another draft id
  /// (or about a result that carries none) no longer applies.
  void clearIfReplaced(String remoteHash, String? newDraftId) {
    final verdict = get(remoteHash);
    if (verdict != null && verdict.draftId != newDraftId) {
      state.db.execute(
        'DELETE FROM v2_sync_state WHERE namespace=? AND key=?',
        [state.namespace, '$prefix$remoteHash'],
      );
    }
  }
}
