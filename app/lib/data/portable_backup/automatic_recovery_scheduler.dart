/// Bounded best-effort work while the app is active. OS background execution
/// is not promised; offline changes remain on the phone until a verified copy.
class AutomaticRecoveryScheduler {
  final Future<void> Function() attempt;
  final DateTime Function() now;
  final bool Function() canRun;
  final Duration interval;
  DateTime? _next;
  bool _busy = false, _disposed = false;
  int _failures = 0;

  AutomaticRecoveryScheduler({
    required this.attempt,
    required this.canRun,
    DateTime Function()? now,
    this.interval = const Duration(minutes: 15),
  }) : now = now ?? DateTime.now;

  Future<void> tick() async {
    if (_disposed || _busy || !canRun()) return;
    final instant = now().toUtc();
    if (_next != null && instant.isBefore(_next!)) return;
    _busy = true;
    // Reserve a slot before awaiting; overlapping events cannot run twice.
    _next = instant.add(interval);
    try {
      await attempt();
      _failures = 0;
    } catch (_) {
      // Fixed backoff, no raw exception, contacts or tokens logged.
      _failures = (_failures + 1).clamp(1, 4);
      _next = instant.add(Duration(minutes: 15 * (1 << (_failures - 1))));
    } finally {
      _busy = false;
    }
  }

  void dispose() => _disposed = true;
}
