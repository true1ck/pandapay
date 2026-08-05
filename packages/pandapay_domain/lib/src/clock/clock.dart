/// Injectable time source. All cycle/period/expiry math in the engine and
/// trackers depends on this, never on `DateTime.now()` directly — otherwise
/// every tracker test is flaky and period-boundary bugs are unreproducible.
abstract class Clock {
  DateTime now();

  const factory Clock.system() = SystemClock;
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Deterministic clock for tests. Time only advances when told to.
class TestClock implements Clock {
  DateTime _now;

  TestClock(this._now);

  @override
  DateTime now() => _now;

  void set(DateTime value) => _now = value;

  void advance(Duration duration) => _now = _now.add(duration);
}
