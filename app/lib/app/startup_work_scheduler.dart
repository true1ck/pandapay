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
  StartupWorkScheduler({this.initialDelay = const Duration(seconds: 3)});

  final Duration initialDelay;
  final _pending = <String, FutureOr<void> Function()>{};
  Timer? _timer;
  bool _draining = false;
  bool _disposed = false;

  void enqueue(String key, FutureOr<void> Function() work, {Duration? delay}) {
    if (_disposed) return;
    _pending[key] = work;
    _timer ??= Timer(delay ?? initialDelay, _drain);
  }

  Future<void> _drain() async {
    _timer = null;
    if (_disposed || _draining) return;
    _draining = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final entry = _pending.entries.first;
        _pending.remove(entry.key);
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
