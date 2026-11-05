// Lane W: processed and failed standing-instruction notices attach to one
// subscription service without counting the spend twice, a non-IPO raised
// mandate is a subscription, and an IPO issuer's mandate never is.
// Synthetic messages only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';

import '../support/scenario_model.dart';

QueuedSms sms(String sender, String body, String at) =>
    QueuedSms(sender: sender, body: body, receivedAt: DateTime.parse(at));

final _november = (
  DateTime.utc(2026, 10, 31, 18, 30),
  DateTime.utc(2026, 11, 30, 18, 30),
);

void main() {
  testWidgets('a processed and a failed standing instruction share one service', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final model = await replayScenarios(
        ['lanew_standing_instruction_processed_then_failed'],
      );
      final series = subscriptionsFromLedger(
        model.facts,
        model.snapshot().events,
        now: DateTime.utc(2026, 12, 20),
      );
      expect(series, hasLength(1));
      expect(series.single.displayName.toUpperCase(), contains('SPOTIFY'));
      expect(series.single.lifecycleStatus, 'failed_payment');
      expect(series.single.occurrenceCount, 1);
      final totals = model.snapshot().totals(_november.$1, _november.$2);
      expect(totals.spendMinor, 11900);
      expect(totals.transactionCount, 1);
    });
  });

  testWidgets('the notice before the spend alert is the same one charge', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final model = await replayScenarios(
        ['lanew_standing_instruction_notice_before_alert'],
      );
      final series = subscriptionsFromLedger(
        model.facts,
        model.snapshot().events,
        now: DateTime.utc(2026, 11, 20),
      );
      expect(series, hasLength(1));
      expect(series.single.occurrenceCount, 1);
      expect(
        model.snapshot().totals(_november.$1, _november.$2).spendMinor,
        11900,
      );
    });
  });

  testWidgets('a small raised mandate is a subscription; IPO issuers are not', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final model = await replayScenarios(
        const [],
        extra: [
          sms(
            'AX-ICICIT-S',
            'Dear Customer, the mandate of INR 649.00 is raised by SAMPLE STREAM on 10-Aug-26 for your approval, through RRN 600100200300-ICICI Bank.',
            '2026-08-10T08:00:00Z',
          ),
          sms(
            'AX-ICICIT-S',
            'Dear Customer, you have approved the mandate of INR 649.00 raised by SAMPLE STREAM on 10-Aug-26, through RRN 600100200300-ICICI Bank.',
            '2026-08-10T08:05:00Z',
          ),
          for (final (i, step) in [
            'you have approved the mandate of INR 15000.00 raised by SAMPLE WORKS LI on 10-Nov-26, through RRN 600100200301-ICICI Bank.',
            'the mandate of INR 15000.00 is raised by SAMPLE WORKS LI on 10-Nov-26 for your approval, through RRN 600100200301-ICICI Bank.',
            'the mandate of INR 15000.00 raised by SAMPLE WORKS LI on 10-Nov-26 and is revoked through RRN 600100200301-ICICI Bank.',
          ].indexed)
            sms('AX-ICICIT-S', 'Dear Customer, $step', '2026-11-1${i}T08:00:00Z'),
          sms(
            'VM-SBIUPI-S',
            'UPI-Mandate successfully created towards SAMPLE ISSUE L for Rs15000.00 -SBI',
            '2026-11-12T08:00:00Z',
          ),
          sms(
            'VM-SBIUPI-S',
            'UPI-Mandate successfully Revoked by SAMPLE ISSUE L for Rs15000.00 -SBI',
            '2026-11-14T08:00:00Z',
          ),
        ],
      );
      final series = subscriptionsFromLedger(
        model.facts,
        model.snapshot().events,
        now: DateTime.utc(2026, 11, 20),
      );
      expect(
        [for (final s in series) s.displayName.toUpperCase()],
        ['SAMPLE STREAM'],
      );
    });
  });
}
