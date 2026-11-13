import 'dart:async';
import 'dart:isolate';

import '../../../data/local/app_database.dart';
import 'subscription_projection.dart';

final _inFlight = <String, Future<void>>{};

/// Re-derives the saved subscription rows without holding the UI isolate: a
/// short-lived worker opens its own connection to the same file (a native
/// database handle is never shared across isolates) and runs
/// [SubscriptionProjection.rebuild] there. The same pattern as the capture and
/// Split workers.
///
/// An in-memory database (most unit tests) cannot be reopened by another
/// isolate, so it is rebuilt in place. One rebuild per account runs at a time;
/// a caller that arrives meanwhile waits for it.
Future<void> rebuildSubscriptionsOffThread(
  AppDatabase database,
  String namespace,
) {
  final path = database.filePath;
  final key = '${path ?? identityHashCode(database)}|$namespace';
  final running = _inFlight[key];
  if (running != null) return running;
  final Future<void> work = path == null
      ? Future<void>.sync(() => SubscriptionProjection.rebuild(database.db, namespace))
      : _rebuildInWorker(path, database.keyHexForWorker, namespace);
  late final Future<void> tracked;
  tracked = work.whenComplete(() {
    if (identical(_inFlight[key], tracked)) _inFlight.remove(key);
  });
  _inFlight[key] = tracked;
  return tracked;
}

/// A top-level function on purpose: the closure handed to [Isolate.run] must
/// capture only these three plain values. A closure written inside
/// [rebuildSubscriptionsOffThread] shares its enclosing scope, which holds the
/// live [AppDatabase] (a native handle), and sending that to another isolate
/// fails on a real phone ("object is unsendable").
Future<void> _rebuildInWorker(String path, String? keyHex, String namespace) =>
    Isolate.run(() => _rebuildBlocking(path, keyHex, namespace));

void _rebuildBlocking(String path, String? keyHex, String namespace) {
  final worker = keyHex == null
      ? AppDatabase.openUnencryptedFileForTesting(path)
      : AppDatabase.openFile(path, keyHex: keyHex);
  try {
    SubscriptionProjection.rebuild(worker.db, namespace);
  } finally {
    worker.close();
  }
}
