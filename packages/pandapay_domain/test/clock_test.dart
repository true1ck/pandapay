import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  test('TestClock only advances when told to', () {
    final clock = TestClock(DateTime(2026, 1, 1));
    expect(clock.now(), DateTime(2026, 1, 1));

    clock.advance(const Duration(days: 30));
    expect(clock.now(), DateTime(2026, 1, 31));

    clock.set(DateTime(2027, 1, 1));
    expect(clock.now(), DateTime(2027, 1, 1));
  });

  test('SystemClock tracks real time within a generous tolerance', () {
    const clock = SystemClock();
    final before = DateTime.now();
    final observed = clock.now();
    final after = DateTime.now();
    expect(observed.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    expect(observed.isBefore(after.add(const Duration(seconds: 1))), isTrue);
  });
}
