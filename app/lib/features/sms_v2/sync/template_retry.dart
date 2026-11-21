import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../storage/sync_state_store.dart';
import '../storage/template_origin_store.dart';

/// "Try again" on a Needs review card for a message the AI could not read.
///
/// One press does two things, once: it clears this phone's own marks for the layout so the next upload pass
/// sends it again at once ([TemplateRetry.reset]), and it asks the server to retry the failed layout
/// ([requestServerRetry]). The automatic retries (a failed layout tried again after a hiccup on the server's side
/// or when the AI is improved, the phone's own back-offs) are untouched.
class TemplateRetry {
  TemplateRetry(this.db, {required this.namespace, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Database db;
  final String namespace;
  final DateTime Function() _clock;

  /// A layout can be retried at most once in this time, from the phone's side. The mark is kept per layout.
  static const minGap = Duration(minutes: 5);

  /// How long "Trying again" is shown while no new answer arrives; after that the card falls back to what the
  /// phone knows (the same bound as "Checking with AI").
  static const showFor = Duration(hours: 24);

  /// The server takes at most this many layouts in one retry request.
  static const maxHashes = 20;

  static const _key = 'template:retry:';
  late final _state = SyncStateStore(db, namespace: namespace);

  /// Every message layout (local hash) that was sent, with the shared layouts (the hashes this phone sent) it
  /// went as: one pass over the saved origins, for a screen that asks about many layouts.
  Map<String, List<String>> index() {
    final origins = TemplateOriginStore(_state);
    final out = <String, List<String>>{};
    for (final row in db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:origins:%'",
      [namespace],
    )) {
      final parsed = origins.parse(row['value'] as String);
      if (parsed == null) continue;
      final remote = (row['key'] as String).substring('template:origins:'.length);
      for (final local in parsed.localHashes) {
        (out[local] ??= []).add(remote);
      }
    }
    return out;
  }

  /// The shared layouts that the message layout [localHash] was sent as.
  List<String> remoteHashesOf(String localHash) =>
      (index()[localHash] ?? const <String>[]).take(maxHashes).toList();

  DateTime? _pressedAt(String remoteHash) =>
      DateTime.tryParse(_state.get('$_key$remoteHash') ?? '');

  /// Whether "Try again" may be offered for a layout that went as [remoteHashes]: none of them was retried in the
  /// last [minGap].
  bool canTryHashes(Iterable<String> remoteHashes) {
    final now = _clock();
    for (final hash in remoteHashes) {
      final at = _pressedAt(hash);
      if (at != null && now.difference(at).abs() < minGap) return false;
    }
    return true;
  }

  bool canTry(String localHash) => canTryHashes(remoteHashesOf(localHash));

  /// True from the press until a new answer for the layout arrives (its saved answer is dropped by [reset], so an
  /// answer row coming back means the server has spoken), for at most [showFor].
  bool isRetryingHashes(Iterable<String> remoteHashes) {
    final now = _clock();
    for (final hash in remoteHashes) {
      final at = _pressedAt(hash);
      if (at == null || now.difference(at) >= showFor) continue;
      if (_state.get('ai:$hash') == null) return true;
    }
    return false;
  }

  bool isRetrying(String localHash) => isRetryingHashes(remoteHashesOf(localHash));

  /// Clears what keeps this phone from sending the layout [localHash] again, and returns the shared hashes it did
  /// it for (at most [maxHashes]; empty when the layout was never sent, or was retried less than [minGap] ago):
  ///  * the sent mark, the refused count and the saved answer (failed, rejected or turned down by this phone) and
  ///    this phone's verdict on its draft, so the layout counts as unsent;
  ///  * the scanned mark of each of [sourceKeys] that pointed at the layout, so the next pass reads the message
  ///    again and queues the layout;
  ///  * the layout's wait in the upload queue, so it is due now.
  /// A wait the server asked for (`template:wait`, a 429) is a limit on the whole queue and is left alone.
  List<String> reset(String localHash, {Iterable<String> sourceKeys = const []}) {
    if (!canTry(localHash)) return const [];
    final hashes = remoteHashesOf(localHash);
    if (hashes.isEmpty) return const [];
    final now = _clock().toUtc().toIso8601String();
    db.execute('SAVEPOINT sms_v2_template_retry');
    try {
      for (final hash in hashes) {
        db.execute(
          'DELETE FROM v2_sync_state WHERE namespace=? AND key IN (?,?,?,?)',
          [
            namespace,
            'template:sent:$hash',
            'template:refused:$hash',
            'ai:$hash',
            'draft:verdict:$hash',
          ],
        );
        db.execute(
          "UPDATE v2_outbox SET next_attempt_at=0 WHERE namespace=? AND kind='template' AND id=?",
          [namespace, 'template:$hash'],
        );
        _state.put('$_key$hash', now);
      }
      for (final source in sourceKeys) {
        final scanned = _state.get('template:scanned:$source');
        if (scanned != null && hashes.contains(scanned)) {
          db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
            namespace,
            'template:scanned:$source',
          ]);
        }
      }
      db.execute('RELEASE sms_v2_template_retry');
    } catch (_) {
      db.execute('ROLLBACK TO sms_v2_template_retry');
      db.execute('RELEASE sms_v2_template_retry');
      rethrow;
    }
    return hashes;
  }
}

/// Asks the server to retry failed layouts: `POST /sms/v2/ai-status/retry`, body `{"templateHashes": [...]}`
/// (at most [TemplateRetry.maxHashes]), answered 202 `{"requeued": n}`. Returns n when the server took it, or null
/// for anything else (a 404 before the endpoint ships, an error, no connection): the retry then goes from the
/// phone only, and nothing is shown to the person. One request per call, never repeated here.
Future<int?> requestServerRetry({
  required http.Client client,
  required Uri baseUri,
  required Future<Map<String, String>> Function() headers,
  required List<String> templateHashes,
}) async {
  final hashes = templateHashes.take(TemplateRetry.maxHashes).toList();
  if (hashes.isEmpty) return null;
  try {
    final response = await client
        .post(
          baseUri.resolve('/sms/v2/ai-status/retry'),
          headers: {...await headers(), 'Content-Type': 'application/json'},
          body: jsonEncode({'templateHashes': hashes}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    try {
      final decoded = jsonDecode(response.body);
      final n = decoded is Map ? decoded['requeued'] : null;
      return n is int && n >= 0 ? n : 0;
    } catch (_) {
      return 0; // took it, said nothing useful
    }
  } catch (_) {
    return null;
  }
}
