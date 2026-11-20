import 'package:sqlite3/sqlite3.dart';

import '../storage/sync_state_store.dart';
import 'ai_server_status.dart';

/// A layout the server accepted while this phone was not counted is stored
/// `held` and never drafted, and the phone records it as sent and never sends it
/// again. When the phone becomes counted (the owner's policy changed, or the
/// phone now passes attestation) those layouts would stay held for ever.
///
/// So when the server says "counted now, and N held", forget what was sent so
/// the normal upload sends the still-open layouts again. Sending is idempotent
/// (the server releases a held layout on a counted submission) and bounded by
/// the per-person daily cap. At most once per [every], so a layout the server
/// keeps holding cannot make the phone send in a loop.
///
/// When a re-send last ran. It was kept under `ai:resend:at`, which every query over the AI answers
/// (`key LIKE 'ai:%'`, then json_extract) tripped on: its value is a bare date, not JSON. It lives under
/// `template:` now; a phone that still holds the old key has the value moved over, so the six-hour wait carries on.
const _resendKey = 'template:resend:at';
const _legacyResendKey = 'ai:resend:at';

DateTime? _lastResend(SyncStateStore state) {
  final legacy = state.get(_legacyResendKey);
  if (legacy != null) {
    if (state.get(_resendKey) == null) state.put(_resendKey, legacy);
    state.db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [state.namespace, _legacyResendKey]);
  }
  return DateTime.tryParse(state.get(_resendKey) ?? '');
}

/// Returns true when it reset the sent marks.
bool resendHeldTemplates(
  Database db, {
  required String namespace,
  required AiServerStatus status,
  required DateTime now,
  Duration every = const Duration(hours: 6),
}) {
  if (!status.countedNow || status.held <= 0) return false;
  final state = SyncStateStore(db, namespace: namespace);
  final last = _lastResend(state);
  if (last != null && now.difference(last).abs() < every) return false;
  db.execute(
    "DELETE FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:sent:%'",
    [namespace],
  );
  state.put(_resendKey, now.toUtc().toIso8601String());
  return true;
}

/// Held layouts used to be released only when the person opened the review
/// screen (its status bar asked the server and called [resendHeldTemplates]).
/// Someone who never opens it, or whose layouts were held before the owner
/// counted unattested members, kept them held for ever. This does the same from
/// the background sync: ask the server how this phone's layouts stand at most
/// every [every], and release held ones when the phone is counted now. A
/// failed ask is tried again in about five minutes. Returns true when it reset
/// the sent marks.
Future<bool> releaseHeldTemplatesInBackground(
  Database db, {
  required String namespace,
  required DateTime now,
  required Future<AiServerStatus?> Function() fetchStatus,
  Duration every = const Duration(minutes: 30),
}) async {
  final state = SyncStateStore(db, namespace: namespace);
  _lastResend(state); // moves a mark an earlier build left under ai:, even when nothing is released this time
  final last = DateTime.tryParse(state.get('template:heldcheck:at') ?? '');
  if (last != null && now.difference(last).abs() < every) return false;
  final status = await fetchStatus();
  // Success waits the full interval; a failure only about five minutes.
  state.put(
    'template:heldcheck:at',
    (status == null ? now.subtract(every - const Duration(minutes: 5)) : now)
        .toUtc()
        .toIso8601String(),
  );
  if (status == null) return false;
  return resendHeldTemplates(db, namespace: namespace, status: status, now: now);
}
