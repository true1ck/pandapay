import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:math';

/// Client-wide "the server asked us to slow down" gate.
///
/// A 429 or 503 means the server is shedding load. Every queue (sync, command
/// outbox, quick-add, imports...) shares this one pause so that none of them
/// keeps hammering it, and so a crowd of phones backs off together, spread out
/// by jitter. The delay is the server's `Retry-After` (seconds or HTTP date)
/// when given, otherwise [defaultDelay]; it is capped at [maxDelay]. Nothing is
/// lost: queued work stays queued and resumes when [resumed] fires.
class ServerBackoff {
  ServerBackoff._();

  /// Process-wide instance; tests build their own with [ServerBackoff.test].
  static final ServerBackoff process = ServerBackoff._();

  ServerBackoff.test({DateTime Function()? now, Random? random})
    : _now = now ?? DateTime.now,
      _random = random ?? Random();

  DateTime Function() _now = DateTime.now;
  Random _random = Random();

  static const defaultDelay = Duration(seconds: 30);
  static const maxDelay = Duration(minutes: 10);

  DateTime? _until;
  Timer? _timer;
  final _resumed = StreamController<void>.broadcast();

  /// Fires once when a pause ends, so queues can retry without waiting for
  /// some other trigger.
  Stream<void> get resumed => _resumed.stream;

  bool get isPaused {
    final until = _until;
    return until != null && _now().isBefore(until);
  }

  Duration get remaining =>
      isPaused ? _until!.difference(_now()) : Duration.zero;

  /// A 429 is a rate limit, often per endpoint, so it never freezes every
  /// queue for longer than this.
  static const maxRateLimitDelay = Duration(seconds: 120);

  /// `Retry-After: 0` means "now": a short pause, not [defaultDelay].
  static const minDelay = Duration(seconds: 1);

  /// Call with every HTTP response from our API; only 429 and 503 start a
  /// pause. [path] is the request path: `/auth/*` limiters (OTP, login) are
  /// per person and per endpoint and say nothing about sync, so they are
  /// ignored.
  void noteResponse(int status, String? retryAfterHeader, {String? path}) {
    if (status != 429 && status != 503) return;
    if (path != null && path.contains('/auth/')) return;
    var base = parseRetryAfter(retryAfterHeader, _now()) ?? defaultDelay;
    if (base < minDelay) base = minDelay;
    // Cap first, then jitter: phones told the same capped delay still spread.
    final cap = status == 429 ? maxRateLimitDelay : maxDelay;
    if (base > cap) base = cap;
    // 0-25 % extra so phones that were told the same delay do not return at
    // the same instant.
    final delay =
        base +
        Duration(
          milliseconds: (base.inMilliseconds * 0.25 * _random.nextDouble())
              .round(),
        );
    final until = _now().add(delay);
    if (_until != null && !until.isAfter(_until!))
      return; // keep the longer one
    _until = until;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _until = null;
      if (!_resumed.isClosed) _resumed.add(null);
    });
  }

  /// `Retry-After` as whole seconds or an HTTP date; null when absent or bad.
  static Duration? parseRetryAfter(String? header, DateTime now) {
    final value = header?.trim();
    if (value == null || value.isEmpty) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds);
    }
    try {
      final when = HttpDate.parse(value);
      final delta = when.difference(now);
      return delta.isNegative || delta == Duration.zero ? null : delta;
    } catch (_) {
      return null;
    }
  }

  void resetForTest() {
    _timer?.cancel();
    _until = null;
  }
}
