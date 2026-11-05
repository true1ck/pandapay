import 'dart:async';

/// Merges a storm of "these entities changed" signals into few refreshes.
///
/// Every refresh makes each open screen show its loading state again, so one
/// per imported batch makes pages flicker for the whole import. The first
/// change is applied immediately (normal use stays instant). Changes that
/// arrive inside [window] (10 seconds by default) are merged and applied once the window ends.
class InvalidationCoalescer {
  InvalidationCoalescer({
    this.window = const Duration(seconds: 10),
    required this.onFlush,
  });

  final Duration window;
  final void Function(Set<String> entities) onFlush;

  final Set<String> _pending = {};
  Timer? _timer;
  bool _disposed = false;

  void add(Set<String> entities) {
    if (_disposed || entities.isEmpty) return;
    _pending.addAll(entities);
    if (_timer == null) {
      _flush();
      _startWindow();
    }
  }

  void _startWindow() {
    _timer = Timer(window, () {
      _timer = null;
      if (_disposed || _pending.isEmpty) return;
      _flush();
      _startWindow();
    });
  }

  void _flush() {
    final entities = Set<String>.of(_pending);
    _pending.clear();
    onFlush(entities);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
