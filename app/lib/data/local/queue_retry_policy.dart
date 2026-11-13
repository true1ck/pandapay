import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api_exception.dart';

/// How a queue should treat one failed delivery attempt (WP-C2, Q-01/02/04).
///
/// The same rule is shared by every durable outbox so a flaky connection never
/// burns retry budget, a transient server problem backs off, and a request the
/// server will never accept is parked instead of blocking newer work.
enum QueueFailure {
  /// No usable response: the device could not reach the server (socket error,
  /// timeout, TLS failure, an `ApiException` without an HTTP status) or the
  /// session was rejected (401). Says nothing about the row itself, so it does
  /// not count as an attempt, sets no backoff, and the rest of the batch is
  /// skipped because it would fail the same way (one 15 s timeout per row
  /// otherwise).
  network,

  /// The server answered with something that may succeed later (5xx, 408, 429)
  /// or the failure is unknown. Counts as an attempt and backs off.
  retryable,

  /// The server answered with a 4xx that retrying cannot change (not 401, 408
  /// or 429). The row is parked: kept with its error for the user to see, but
  /// never retried automatically.
  permanent,
}

/// Classifies [error] for queue bookkeeping. See [QueueFailure].
QueueFailure classifyQueueFailure(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is TlsException) {
    return QueueFailure.network;
  }
  if (error is ApiException) {
    final status = error.statusCode;
    if (status == null) return QueueFailure.network;
    if (status == 401) return QueueFailure.network;
    if (status == 408 || status == 429) return QueueFailure.retryable;
    if (status >= 400 && status < 500) return QueueFailure.permanent;
    return QueueFailure.retryable;
  }
  return QueueFailure.retryable;
}

/// True for a failure that means "could not reach the server right now".
bool isPureNetworkFailure(Object error) =>
    classifyQueueFailure(error) == QueueFailure.network;

/// Delay before the next automatic attempt after [attempts] counted failures
/// (1 = first): 30 s, 60 s, 2 min ... capped at 30 min.
Duration queueBackoff(
  int attempts, {
  Duration base = const Duration(seconds: 30),
  Duration max = const Duration(minutes: 30),
}) {
  if (attempts <= 1) return base;
  final shift = attempts - 1 > 20 ? 20 : attempts - 1;
  final delay = base * (1 << shift);
  return delay > max ? max : delay;
}
