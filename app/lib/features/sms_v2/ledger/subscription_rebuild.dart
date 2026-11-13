import 'dart:async';
import 'dart:isolate';

import '../../../data/local/app_database.dart';
import 'subscription_projection.dart';

class _Rebuilder {
  Future<void>? running;
  Completer<void>? queued;
}

final _rebuilders = <String, _Rebuilder>{};

/// Re-derives the saved subscription rows without holding the UI isolate: a
/// short-lived worker opens its own connection to the same file (a native
/// database handle is never shared across isolates) and runs
/// [SubscriptionProjection.rebuild] there. The same pattern as the capture and
/// Split workers.
///
/// One rebuild per account runs at a time. A caller that arrives while one is
/// running does NOT get that run's result (it may predate what the caller just
/// changed): it gets one more run, started when the current one ends, and every
/// caller that arrives meanwhile shares that single follow-up.
///
/// An in-memory database (most unit tests) cannot be reopened by another
/// isolate, so it is rebuilt in place.
Future<void> rebuildSubscriptionsOffThread(
  AppDatabase database,
  String namespace,
) {
  final key = '${database.filePath ?? identityHashCode(database)}|$namespace';
  final r = _rebuilders.putIfAbsent(key, _Rebuilder.new);
  if (r.running == null) return _start(r, key, database, namespace);
  return (r.queued ??= Completer<void>()).future;
}

Future<void> _start(
  _Rebuilder r,
  String key,
  AppDatabase database,
  String namespace,
) {
  final run = _runUntilCurrent(database, namespace);
  r.running = run;
  run.then<void>(
    (_) => _finish(r, key, database, namespace, null),
    onError: (Object e, StackTrace st) => _finish(r, key, database, namespace, (e, st)),
  );
  return run;
}

void _finish(
  _Rebuilder r,
  String key,
  AppDatabase database,
  String namespace,
  (Object, StackTrace)? failure,
) {
  r.running = null;
  final waiting = r.queued;
  r.queued = null;
  if (waiting == null) {
    _rebuilders.remove(key);
    return;
  }
  // The follow-up that was promised to callers who arrived during the run.
  _start(r, key, database, namespace).then(waiting.complete, onError: waiting.completeError);
}

/// Derives, and derives again (a few times) while the ledger keeps moving under
/// the worker: [SubscriptionProjection.rebuild] refuses to write over newer facts.
Future<void> _runUntilCurrent(AppDatabase database, String namespace) async {
  final path = database.filePath;
  for (var attempt = 0; attempt < 4; attempt++) {
    final committed = path == null
        ? SubscriptionProjection.rebuild(database.db, namespace)
        : await _rebuildInWorker(path, database.keyHexForWorker, namespace);
    if (committed) return;
  }
}

/// A top-level function on purpose: the closure handed to [Isolate.run] must
/// capture only these three plain values. A closure written inside a function
/// that has the live [AppDatabase] in scope shares that scope, and sending a
/// native handle to another isolate fails on a real phone ("unsendable").
Future<bool> _rebuildInWorker(String path, String? keyHex, String namespace) =>
    Isolate.run(() => _rebuildBlocking(path, keyHex, namespace));

bool _rebuildBlocking(String path, String? keyHex, String namespace) {
  final worker = keyHex == null
      ? AppDatabase.openUnencryptedFileForTesting(path)
      : AppDatabase.openFile(path, keyHex: keyHex);
  try {
    return SubscriptionProjection.rebuild(worker.db, namespace);
  } finally {
    worker.close();
  }
}
