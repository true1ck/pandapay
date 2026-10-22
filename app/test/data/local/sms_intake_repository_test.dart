import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

QueuedSms sms(String body) => QueuedSms(
  sender: 'VM-HDFC',
  body: body,
  receivedAt: DateTime(2026, 10, 18),
);

void main() {
  test(
    'acknowledgment preserves captured data and duplicate delivery stays processed',
    () {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final intake = SmsIntakeRepository(database);
      final message = sms('saved locally');
      final id = intake.capture('a', message);
      intake.acknowledge('a', id);
      intake.capture('a', message);
      expect(intake.pending('a'), isEmpty);
      expect(intake.capturedBodies('a'), ['saved locally']);
      expect(intake.capturedBodies('b'), isEmpty);
    },
  );

  test(
    'retry backoff keeps failed work without blocking newly captured messages',
    () {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      var now = DateTime(2026, 10, 18);
      final intake = SmsIntakeRepository(database, now: () => now);
      final failed = intake.capture('a', sms('failed'));
      intake.failed('a', failed);
      intake.capture('a', sms('new arrival'));
      expect(intake.pending('a'), hasLength(2));
      expect(
        intake.pending('a', readyOnly: true).single.message.body,
        'new arrival',
      );
      now = now.add(const Duration(seconds: 31));
      expect(intake.pending('a', readyOnly: true), hasLength(2));
    },
  );
  late AppDatabase db;
  late SmsIntakeRepository intake;
  setUp(() {
    db = openInMemoryForTesting();
    intake = SmsIntakeRepository(db);
  });
  tearDown(() => db.close());
  test('arrival during upload survives acknowledging the older entry', () {
    final old = intake.capture('a', sms('first'));
    intake.capture('a', sms('second'));
    intake.acknowledge('a', old);
    expect(intake.pending('a').single.message.body, 'second');
  });
  test('failed messages survive retries and queue pagination', () {
    for (var i = 0; i < 205; i++) {
      intake.capture('a', sms('message $i'));
    }
    final first = intake.pending('a').first.id;
    for (var i = 0; i < 10; i++) {
      intake.failed('a', first);
    }
    expect(intake.pending('a', limit: 1000), hasLength(205));
  });
  test('normalization deduplicates delivery without crossing accounts', () {
    expect(
      smsSourceKey('user:123', ' VM-HDFC ', 'Rs. 10\n spent'),
      smsSourceKey('user:123', 'vm-hdfc', 'Rs. 10 spent'),
    );
    intake.capture('a', sms('same'));
    intake.capture('a', sms('same'));
    intake.capture('b', sms('same'));
    expect(intake.pending('a'), hasLength(1));
    expect(intake.pending('b'), hasLength(1));
  });
  test(
    'billing upload visits previous month then two months back before other alerts',
    () {
      final ordered = SmsIntakeRepository(
        db,
        now: () => DateTime(2026, 10, 20),
      );
      for (final (body, date) in [
        ('old cycle', DateTime(2026, 7, 15)),
        ('august statement', DateTime(2026, 8, 15)),
        ('september statement', DateTime(2026, 9, 15)),
        ('october payment', DateTime(2026, 10, 2)),
        ('october statement generated', DateTime(2026, 10, 15)),
      ]) {
        ordered.capture(
          'a',
          QueuedSms(sender: 'VM-AXIS', body: body, receivedAt: date),
        );
      }
      expect(
        ordered.pending('a', billingPriority: true).map((e) => e.message.body),
        [
          'september statement',
          'august statement',
          'october statement generated',
          'october payment',
          'old cycle',
        ],
      );
    },
  );

  test('records source decision and forgetRaw cleans intake while retaining decision', () {
    final key = smsSourceKey('a', 'VM-HDFC', 'OTP 123456');
    intake.recordDecision(
      'a',
      sourceKey: key,
      decision: 'ignored_promotion',
      state: 'final',
      reasonCode: 'promotional_message',
      receivedAt: 1729200000000,
      policyVersion: 'v1',
    );

    final dec = intake.decision('a', key);
    expect(dec, isNotNull);
    expect(dec!.decision, 'ignored_promotion');
    expect(dec.state, 'final');
    expect(dec.reasonCode, 'promotional_message');
    expect(intake.wasProcessed('a', key), isTrue);

    intake.capture('a', sms('temp'));
    intake.forgetRaw('a', key);
    expect(intake.decision('a', key), isNotNull);
  });

}
