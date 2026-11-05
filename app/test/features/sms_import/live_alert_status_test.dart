import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/live_alert_status.dart';

void main() {
  final now = DateTime(2026, 11, 2, 21, 15);
  LiveAlertStatus of(DateTime? last, {bool enabled = true}) =>
      LiveAlertStatus.of(enabled: enabled, lastLiveAt: last, now: now);

  test('off while SMS saving is switched off', () {
    final status = of(now, enabled: false);
    expect(status.health, LiveAlertHealth.off);
  });

  test('waits for the first SMS after setup', () {
    final status = of(null);
    expect(status.health, LiveAlertHealth.waiting);
    expect(status.label, contains('Waiting for your first SMS'));
  });

  test('working shows when the last SMS arrived', () {
    expect(
      of(DateTime(2026, 11, 2, 20, 40)).label,
      'On · last SMS today, 8:40 pm',
    );
    expect(
      of(DateTime(2026, 11, 1, 9, 5)).label,
      'On · last SMS yesterday, 9:05 am',
    );
    expect(
      of(DateTime(2026, 10, 31, 9, 5)).label,
      'On · last SMS 31 Oct, 9:05 am',
    );
    expect(of(DateTime(2026, 10, 31, 9, 5)).health, LiveAlertHealth.working);
  });

  test('three quiet days suggest live alerts were switched off', () {
    final status = of(now.subtract(const Duration(days: 4)));
    expect(status.health, LiveAlertHealth.quiet);
    expect(status.label, 'No SMS for 4 days. Live alerts may be off.');
  });
}
