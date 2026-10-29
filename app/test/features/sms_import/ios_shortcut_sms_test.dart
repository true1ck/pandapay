import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';

void main() {
  Map<Object?, Object?> row() => {
    'sender': 'VM-ICICIB',
    'body':
        'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.\nRef TEST-42 🧾',
    'receivedAt': '2026-09-30T20:10:51.277+05:30',
  };

  test('preserves full text, raw sender and the original timestamp', () {
    final input = row();
    input['bodyCharacters'] = (input['body'] as String).length;
    final batch = IosShortcutSmsBatch.fromRows([input]);
    expect(batch.messages, hasLength(1));
    final message = batch.messages.single;
    expect(message.body, input['body']);
    expect(message.sender, input['sender']);
    expect(message.receivedAt, DateTime.utc(2026, 9, 30, 14, 40, 51, 277));
  });

  test('missing dates are withheld and missing sender can be inferred', () {
    final noSender = row()..['sender'] = '';
    final noDate = row()..remove('receivedAt');
    final unzonedDate = row()..['receivedAt'] = '2026-09-30T20:10:51';
    final contactName = row()..['senderEvidence'] = 'name';
    final batch = IosShortcutSmsBatch.fromRows([
      noSender,
      noDate,
      unzonedDate,
      contactName,
    ]);
    expect(batch.messages, hasLength(2));
    expect(batch.incomplete, 2);
    expect(batch.missingSender, 1);
    expect(batch.missingDate, 2);
    // Inferred sender for noSender: contains ICICI -> VM-ICICIB
    expect(batch.messages[0].sender, 'VM-ICICIB');
  });

  test(
    'body date and capture time never substitute for original receive date',
    () {
      final input = row()
        ..remove('receivedAt')
        ..['body'] =
            'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 03-03-2026.'
        ..['capturedAt'] = '2026-10-29T10:00:00Z';
      final batch = IosShortcutSmsBatch.fromRows([input]);
      expect(batch.messages, isEmpty);
      expect(batch.missingDate, 1);
      expect(batch.incomplete, 1);
    },
  );

  test('rejects OTPs and damaged bodies before shared persistence', () {
    final otp = row()..['body'] = 'OTP 123456 for Rs 250. Do not share.';
    final damaged = row()..['bodyCharacters'] = 1;
    final batch = IosShortcutSmsBatch.fromRows([otp, damaged]);
    expect(batch.messages, isEmpty);
    expect(batch.sensitive, 1);
    expect(batch.invalid, 1);
  });
}
