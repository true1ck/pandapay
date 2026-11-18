import 'package:flutter/foundation.dart' show visibleForTesting;

/// Orders reads against the writes this phone has had acknowledged.
///
/// The bug this exists for (18 Nov 2026): the phone sends a write (a quick-add,
/// an edit, a delete) and, at about the same time, a read of the same data (the
/// full transaction list, the cards, a report). The server answers them in
/// whatever order its connections and admission line happen to run them, so the
/// read can be answered from a moment BEFORE the write while it is received
/// AFTER it. Applied as "the server's list is the truth", that older copy
/// deletes the row the write just created (or puts the old value back), and by
/// then the outbox entry that kept the row visible is already gone.
///
/// The rule: a read that was in flight when a write was acknowledged is not
/// allowed to replace anything. It is dropped and asked again ([readAfterWrites]).
///
/// [ApiRequestHeadersClient] calls [markAcked] for every successful data write
/// to the API (one place, so no endpoint can be forgotten). A reader takes a
/// [begin] token before it sends the request and asks [changedSince] when the
/// answer arrives. The token is a counter, not a clock, so two things in the
/// same millisecond are still ordered.
///
/// One instance per isolate (like `ServerBackoff.process`): the background SMS
/// isolate has its own, and what it writes reaches this one through the change
/// feed, which only ever adds or updates.
class WriteFence {
  WriteFence({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final WriteFence process = WriteFence();

  /// How many times [readAfterWrites] asks again before it gives up and lets the
  /// caller keep the phone's own copy.
  static const defaultRetries = 2;

  final DateTime Function() _now;
  int _acks = 0;
  DateTime? _lastAckAt;

  /// Marks the start of a read. Pass the result to [changedSince] afterwards.
  int begin() => _acks;

  /// True when a write was acknowledged after [token] was taken, so a read that
  /// began at [token] may not contain it.
  bool changedSince(int token) => _acks != token;

  /// When the last write of this run was acknowledged, null before the first.
  DateTime? get lastAckAt => _lastAckAt;

  /// True when a saved server snapshot (written at [storedAt]) is older than a
  /// write acknowledged since. A snapshot stored in an earlier run counts too:
  /// the first write of this run is newer than it.
  bool isSnapshotStale(DateTime storedAt) {
    final last = _lastAckAt;
    return last != null && last.isAfter(storedAt);
  }

  /// The server accepted a write that changes this account's data.
  void markAcked() {
    _acks++;
    _lastAckAt = _now();
  }

  @visibleForTesting
  void reset() {
    _acks = 0;
    _lastAckAt = null;
  }

  /// Paths (below the API base path) whose writes change nothing a screen reads
  /// back, so they must not make every read in flight look out of date.
  static const _notData = <String>[
    '/analytics',
    '/sync/ack',
    '/sync/register-device',
    '/notification-devices',
    '/sms/v2/client-metrics',
    '/data-error-reports',
    '/partner-clicks',
    '/engagement',
    '/acceptance-reports',
    '/support-tickets',
  ];

  /// Whether a request with [method] to [path] (relative to the API base) is a
  /// write that a later read must not predate. Every non-read counts unless it
  /// is on [_notData]: a new endpoint is covered without anyone remembering to
  /// list it.
  static bool countsAsDataWrite(String method, String path) {
    switch (method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
        return false;
    }
    for (final prefix in _notData) {
      if (path == prefix || path.startsWith('$prefix/')) return false;
    }
    return true;
  }
}

/// A read could not be made newer than every write this phone had acknowledged
/// (writes kept landing while it was in flight). Nothing was applied; whoever
/// was waiting for it tries again later.
class StaleReadException implements Exception {
  const StaleReadException([this.what = 'server copy']);
  final String what;

  @override
  String toString() =>
      'StaleReadException: the $what may predate a saved change; not applied';
}

/// The answer of [readFenced]: the last answer received, and whether it is
/// certain to be newer than every write acknowledged before it arrived.
class FencedRead<T> {
  const FencedRead(this.value, {required this.current});
  final T value;

  /// False when writes kept being acknowledged while the read was in flight, on
  /// every attempt. [value] may then predate them: show it, never store it over
  /// anything.
  final bool current;
}

/// Runs [read] (a request to the server) and asks again, up to [retries] more
/// times, while a write was acknowledged during it. See [FencedRead.current].
///
/// Errors from [read] are not caught.
Future<FencedRead<T>> readFenced<T>(
  Future<T> Function() read, {
  int retries = WriteFence.defaultRetries,
  WriteFence? fence,
}) async {
  final f = fence ?? WriteFence.process;
  for (var attempt = 0; ; attempt++) {
    final token = f.begin();
    final value = await read();
    if (!f.changedSince(token)) return FencedRead(value, current: true);
    if (attempt >= retries) return FencedRead(value, current: false);
  }
}

/// [readFenced] for callers that only want an answer they may store: the value
/// when it is current, else null (keep what the phone has). A read whose own
/// answer can be null cannot use this; it uses [readFenced].
Future<T?> readAfterWrites<T>(
  Future<T> Function() read, {
  int retries = WriteFence.defaultRetries,
  WriteFence? fence,
}) async {
  final answer = await readFenced(read, retries: retries, fence: fence);
  return answer.current ? answer.value : null;
}
