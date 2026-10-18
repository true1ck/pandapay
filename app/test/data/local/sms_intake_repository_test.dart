import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  late AppDatabase db;
  late SmsIntakeRepository intake;
  setUp(() {
    db = openInMemoryForTesting();
    intake = SmsIntakeRepository(db);
  });
  tearDown(() => db.close());
  QueuedSms sms(String body) => QueuedSms(
    sender: 'VM-HDFC',
    body: body,
    receivedAt: DateTime(2026, 10, 18),
  );
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
}
