import 'dart:async';

/// Serializes non-critical work that would otherwise all start during the
/// first authenticated interaction window. Jobs with the same key coalesce;
/// the newest callback replaces older work that has not started yet.
///
/// This is deliberately a small lifecycle-owned scheduler, not a background
/// isolate. SQLite repositories and Flutter plugins remain on their owning
/// isolate, while live SMS, reconnect, explicit refresh, and user mutations
/// can continue to bypass this queue.
class StartupWorkScheduler {
  StartupWorkScheduler({
    this.initialDelay = const Duration(seconds: 3),
    this.maxJobsPerDrain = 1,
  }) : assert(maxJobsPerDrain > 0);

  final Duration initialDelay;
  /// Limits how many callbacks can run in one event-loop turn. A callback may
  /// still be asynchronous; network and database policies must bound it too.
  /// The next queued callback is scheduled as a separate zero-delay task so a
  /// long maintenance backlog cannot monopolize the first interaction turn.
  final int maxJobsPerDrain;
  final _pending = <String, FutureOr<void> Function()>{};
  Timer? _timer;
  bool _draining = false;
  bool _disposed = false;

  void enqueue(String key, FutureOr<void> Function() work, {Duration? delay}) {
    if (_disposed) return;
    _pending[key] = work;
    _timer ??= Timer(delay ?? initialDelay, _drain);
  }

  /// Removes a provider-owned job when that provider is disposed. This keeps
  /// a queued startup timer from surviving a test/widget lifecycle that ends
  /// before the deferred work is due.
  void cancel(String key) {
    _pending.remove(key);
    if (_pending.isEmpty && !_draining) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _drain() async {
    _timer = null;
    if (_disposed || _draining) return;
    _draining = true;
    var jobsRun = 0;
    try {
      while (!_disposed &&
          _pending.isNotEmpty &&
          jobsRun < maxJobsPerDrain) {
        final entry = _pending.entries.first;
        _pending.remove(entry.key);
        jobsRun++;
        try {
          await entry.value();
        } catch (_) {
          // Startup work is best effort. A failed maintenance job must not
          // prevent the next independent job from running.
        }
      }
    } finally {
      _draining = false;
      if (!_disposed && _pending.isNotEmpty) {
        // Always yield between bounded drains, including when the previous
        // callback completed synchronously.
        _timer = Timer(Duration.zero, _drain);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
