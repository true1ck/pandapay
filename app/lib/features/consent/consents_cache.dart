import 'dart:async';
import 'dart:convert';

import '../../app/providers.dart'
    show cacheNamespaceProvider, commandOutboxProvider, consentsApiProvider, responseCacheProvider;
import '../../data/consents_api.dart';
import '../../data/local_first/command_outbox.dart';
import '../account/account_local_first.dart';

/// WP-C11 (R-07): the consents list and history are kept on the phone and
/// shown cache-first; changes queued offline are laid over the cached rows so
/// the toggles show what the person chose.
///
/// [ref] is a provider `Ref`. [history] picks `/consents/history` over
/// `/consents` (latest row per purpose). [onRefreshed] runs when a background
/// refresh found different rows (the provider invalidates itself).
Future<List<ConsentRecord>> loadConsentsCacheFirst(
  dynamic ref, {
  required bool history,
  required void Function() onRefreshed,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final api = ref.read(consentsApiProvider) as ConsentsApi?;
  if (api == null) return const [];
  final namespace = ref.read(cacheNamespaceProvider) as String;
  final key = '$namespace:consents_${history ? 'history' : 'latest'}';
  dynamic cache;
  try {
    cache = await ref.read(responseCacheProvider.future);
  } catch (_) {}

  Future<List<ConsentRecord>> fetch() async {
    final rows = await (history ? api.fetchHistory() : api.fetchLatest())
        .timeout(timeout);
    try {
      await cache?.put(key, jsonEncode([for (final r in rows) r.toJson()]));
    } catch (_) {}
    return rows;
  }

  List<ConsentRecord>? cached;
  if (kAccountLocalFirst && cache != null) {
    try {
      final raw = await cache.get(key) as String?;
      if (raw != null) {
        cached = [
          for (final m in jsonDecode(raw) as List)
            ConsentRecord.fromJson(Map<String, dynamic>.from(m as Map)),
        ];
      }
    } catch (_) {
      cached = null;
    }
  }

  List<ConsentRecord> rows;
  if (cached != null) {
    rows = cached;
    final before = jsonEncode([for (final r in cached) r.toJson()]);
    unawaited(
      fetch().then((fresh) {
        if (jsonEncode([for (final r in fresh) r.toJson()]) != before) {
          onRefreshed();
        }
      }).catchError((_) {}),
    );
  } else {
    rows = await fetch();
  }
  return _withPending(ref, rows, history: history);
}

Future<List<ConsentRecord>> _withPending(
  dynamic ref,
  List<ConsentRecord> rows, {
  required bool history,
}) async {
  try {
    final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
    final pending = commands.pendingOf({AccountCommand.consentSubmit});
    if (pending.isEmpty) return rows;
    final out = [...rows];
    for (final c in pending) {
      final p = c.payload;
      final granted = p['granted'] as bool;
      final record = ConsentRecord(
        purpose: p['purpose'] as String,
        granted: granted,
        grantedAt:
            DateTime.tryParse(p['clientRecordedAt'] as String? ?? '') ??
            DateTime.now(),
        policyVersion: p['policyVersion'] as String?,
        sourceScreen: p['sourceScreen'] as String?,
      );
      if (history) {
        out.insert(0, record);
      } else {
        out.removeWhere((r) => r.purpose == record.purpose);
        out.add(record);
      }
    }
    return out;
  } catch (_) {
    return rows;
  }
}
