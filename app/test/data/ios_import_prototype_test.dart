import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_import_prototype.dart';
import 'package:pandapay/data/local_sms_parser.dart';

void main() {
  final fixtures =
      (jsonDecode(
                File(
                  'test/fixtures/ios_shortcuts_messages.json',
                ).readAsStringSync(),
              )
              as List)
          .map((r) => IosPrototypeCapture.fromMap(r as Map<String, dynamic>))
          .toList();

  test(
    'Shortcut envelopes produce debit, credit and bill observations through the existing parser',
    () {
      final debit = fixtures[0].parse();
      expect(debit?.eventType, LocalSmsEventType.transaction);
      expect(debit?.transaction?.amount.paise, 34900);
      expect(debit?.transaction?.merchantName, isNotEmpty);
      final credit = fixtures[1].parse();
      expect(credit?.eventType, LocalSmsEventType.transaction);
      expect(credit?.transaction?.amount.paise, 500000);
      final bill = fixtures[2].parse();
      expect(bill?.eventType, LocalSmsEventType.bill);
      expect(bill?.amountDue?.paise, 90000);
      expect(bill?.dueDate?.day, 30);
    },
  );

  test('an OTP remains rejected by the shared parser', () {
    expect(fixtures[3].parse(), isNull);
  });

  test('real untagged content cannot enter the synthetic prototype', () {
    expect(
      () => IosPrototypeCapture.fromMap({
        'id': 'real',
        'sender': 'BANK',
        'body': 'Rs 100 debited',
        'capturedAt': '2026-10-26T10:00:00Z',
      }),
      throwsFormatException,
    );
  });

  test(
    'original receive time is preserved separately from the time of import',
    () {
      expect(fixtures.first.receivedAt, DateTime.utc(2026, 10, 26, 9, 30));
      expect(fixtures.first.capturedAt, DateTime.utc(2026, 10, 26, 10));
    },
  );
}
