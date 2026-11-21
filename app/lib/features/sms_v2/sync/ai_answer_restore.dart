import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../storage/sync_state_store.dart';

/// Gets back AI answers this phone lost.
///
/// The server sends each answer once per position of the sync cursor, so a
/// phone that has none saved (they were erased, the database was replaced, or
/// they never arrived) while it still has formats waiting for an answer would
/// wait for ever: the server believes it already delivered them, and the links
/// from each answer back to this phone's own messages are gone with them.
///
/// When the phone holds no answer at all and has at least one open unreadable
/// format, this winds back what the server remembers and what the phone
/// remembers:
///
/// * the "answers" part of the sync cursor is dropped, so the next pull sends
///   every answer for this account again;
/// * the "scanned" and "sent" marks of the open formats are dropped, so the
///   next upload pass looks at each format again, which writes the link from the
///   shared format to this phone's own format that an answer is applied through
///   (the server treats a repeated upload as a duplicate).
///
/// At most once every [every] and [maxTries] times in all, so an account that
/// truly has no answers cannot make the phone upload in a loop. Returns true
/// when it acted. The caller has already confirmed the sharing consent.
bool restoreLostAiAnswers(
  Database db, {
  required String namespace,
  required DateTime now,
  Duration every = const Duration(hours: 6),
  int maxTries = 3,
}) {
  final state = SyncStateStore(db, namespace: namespace);
  final last = DateTime.tryParse(state.get('restore:ai:at') ?? '');
  if (last != null && now.difference(last).abs() < every) return false;
  final tries = int.tryParse(state.get('restore:ai:count') ?? '') ?? 0;
  if (tries >= maxTries) return false;
  if (_holdsAnAnswer(db, namespace)) return false;
  // A format "waiting for an answer" is an open question with no reading. A
  // message an AI rule already read (a question the old rule raised for every
  // unverified reading, or one the AI is unsure about) waits for nothing.
  final open = db.select(
    "SELECT 1 FROM v2_review_items r WHERE r.namespace=? AND r.kind='template' AND r.status='open' "
    'AND NOT EXISTS (SELECT 1 FROM v2_facts f WHERE f.namespace=r.namespace '
    "AND f.source_key=json_extract(r.payload,'\$.sourceKey')) LIMIT 1",
    [namespace],
  );
  if (open.isEmpty) return false;
  db.execute(
    "DELETE FROM v2_sync_state WHERE namespace=? AND (key LIKE 'template:scanned:%' OR key LIKE 'template:sent:%')",
    [namespace],
  );
  _dropAnswerPosition(state);
  state.put('restore:ai:at', now.toUtc().toIso8601String());
  state.put('restore:ai:count', '${tries + 1}');
  return true;
}

bool _holdsAnAnswer(Database db, String namespace) {
  for (final row in db.select(
    "SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
    [namespace],
  )) {
    try {
      final value = jsonDecode(row['value'] as String);
      if (value is Map && value['templateHash'] is String) return true;
    } catch (_) {
      continue; // a timestamp or another marker
    }
  }
  return false;
}

/// Removes the answers part (`a`) of the saved sync cursor, keeping the rest.
/// A cursor that cannot be read is left as it is.
void _dropAnswerPosition(SyncStateStore state) {
  final raw = state.get('pull:cursor');
  if (raw == null || raw.isEmpty) return;
  try {
    final parts = (jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(raw))),
    ) as Map).cast<String, Object?>();
    if (!parts.containsKey('a')) return;
    parts.remove('a');
    state.put(
      'pull:cursor',
      base64Url.encode(utf8.encode(jsonEncode(parts))).replaceAll('=', ''),
    );
  } catch (_) {
    // Not a cursor this code knows: leave the position alone.
  }
}
