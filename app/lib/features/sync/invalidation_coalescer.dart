import 'dart:async';

/// Merges a storm of "these entities changed" signals into few refreshes.
///
/// Every refresh makes open screens recompute, so one per imported batch makes
/// pages flicker for the whole import. A change after a quiet [window] is
/// applied immediately (normal use stays instant) and leaves no timer behind.
/// Changes that arrive sooner are merged and applied once, when the window
/// since the last refresh ends.
class InvalidationCoalescer {
  InvalidationCoalescer({
    this.window = const Duration(seconds: 10),
    required this.onFlush,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final void Function(Set<String> entities) onFlush;
  final DateTime Function() _now;

  final Set<String> _pending = {};
  Timer? _timer;
  DateTime? _lastFlush;
  bool _disposed = false;

  void add(Set<String> entities) {
    if (_disposed || entities.isEmpty) return;
    _pending.addAll(entities);
    if (_timer != null) return;
    final last = _lastFlush;
    final since = last == null ? null : _now().difference(last);
    if (since == null || since >= window) {
      _flush();
      return;
    }
    _timer = Timer(window - since, () {
      _timer = null;
      if (!_disposed && _pending.isNotEmpty) _flush();
    });
  }

  void _flush() {
    final entities = Set<String>.of(_pending);
    _pending.clear();
    _lastFlush = _now();
    onFlush(entities);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
