import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';

/// F4: the outbox wakes at the earliest backoff expiry, not only on the
/// 5 minute timer.
void main() {
  test('wakes at the earliest due time, just after it', () {
    expect(
      outboxRecheckDelay(progressed: false, nextDue: const Duration(seconds: 13)),
      const Duration(seconds: 13, milliseconds: 250),
    );
  });

  test('never later than the 5 minute re-check, and idle waits the cap', () {
    expect(
      outboxRecheckDelay(progressed: false, nextDue: const Duration(minutes: 30)),
      outboxDueRecheckInterval,
    );
    expect(outboxRecheckDelay(progressed: false), outboxDueRecheckInterval);
  });

  test('after a pass that delivered something it continues at once', () {
    expect(
      outboxRecheckDelay(progressed: true, nextDue: const Duration(seconds: 13)),
      outboxContinueInterval,
    );
  });
}
