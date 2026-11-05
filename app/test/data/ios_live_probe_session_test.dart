import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_device_probe_session.dart';
import 'package:pandapay/data/ios_live_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';

Map<Object?, Object?> liveRow(String id) => {
  'id': id,
  'origin': 'live',
  'sender': '',
  'senderEvidence': 'missing_person',
  'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
  'receivedAt': '2026-10-29T08:00:00Z',
  'capturedAt': '2026-10-29T08:01:00Z',
};
void main() {
  test(
    'supplied sender text stays distinct from inferred bank and personal-number triage',
    () {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      final bank = liveRow('bank-text')
        ..['sender'] = 'AD-ICICIB-S'
        ..['senderEvidence'] = 'text';
      final bankOutcome = live.process([bank]).single;
      expect(bankOutcome['effectiveSender'], 'AD-ICICIB-S');
      expect(bankOutcome['senderInferred'], false);
      expect(bankOutcome['outcome'], 'retained_new');
      final personal = {
        ...bank,
        'id': 'personal-text',
        'sender': '+919000000001',
      };
      final personalOutcome = live.process([personal]).single;
      expect(personalOutcome['effectiveSender'], personal['sender']);
      expect(personalOutcome['senderInferred'], false);
      expect(personalOutcome['outcome'], 'ignored');
      expect(personalOutcome['triageReason'], 'p2p_mobile_number');
    },
  );
  test(
    'refresh and failed acknowledgement reuse outcome without duplicate intake',
    () {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      final outcome = live.process([liveRow('one')]).single;
      expect(live.process([liveRow('one')]).single, outcome);
      expect(live.intake.runs['live']!.handedOff, 1);
      final replay = live.process([liveRow('two')]).single;
      expect(replay['outcome'], 'retained_existing');
      expect(live.intake.counts.captured, 1);
      expect(live.intake.runs['live']!.existing, 1);
    },
  );
  test('parser failure stays retryable and never claims processed success', () {
    final intake = IosDeviceProbeSession(openInMemoryForTesting());
    var fail = true;
    final live = IosLiveProbeSession.withIntake(
      intake,
      capture: (rows) {
        if (fail) {
          fail = false;
          throw StateError('synthetic writer failure');
        }
        intake.accept(rows);
      },
    );
    addTearDown(live.dispose);
    expect(
      live.process([liveRow('one')]).single['outcome'],
      'processing_error',
    );
    expect(intake.received, 0);
    expect(live.process([liveRow('one')]).single['outcome'], 'retained_new');
    expect(intake.counts.captured, 1);
    expect(live.process([liveRow('one')]).single['outcome'], 'retained_new');
    expect(intake.runs['live']!.handedOff, 1);
  });
  test(
    'shared rejections report missing date, sensitive and invalid without retaining body',
    () {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      final noDate = liveRow('missing')..remove('receivedAt');
      final sensitive = liveRow('sensitive')
        ..['body'] = 'OTP 123456. Do not share.';
      final invalid = liveRow('invalid')..['body'] = '';
      expect(
        live.process([noDate, sensitive, invalid]).map((row) => row['outcome']),
        ['rejected_missing_date', 'rejected_sensitive', 'rejected_invalid'],
      );
      expect(live.intake.retainedInputs, isEmpty);
      expect(live.intake.transactions, 0);
    },
  );
  test('ordinary nonfinancial text is processed as ignored', () {
    final live = IosLiveProbeSession(openInMemoryForTesting());
    addTearDown(live.dispose);
    final unrelated = liveRow('chat')
      ..['sender'] = 'TEST-PERSON'
      ..['body'] = 'See you for lunch tomorrow.';
    expect(live.process([unrelated]).single['outcome'], 'ignored');
    expect(live.intake.counts.captured, 0);
    expect(live.intake.retainedInputsForRun('live'), isEmpty);
  });
}
