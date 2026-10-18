import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  test('credit card account references never establish bank accounts', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK',
      body:
          'Your credit card account ending 8708 payment due on 20-Oct-2026. Available balance Rs.5000.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result, isNotNull);
    expect(result!.accountLast4, isNull);
  });
  final fixtures =
      jsonDecode(File('test/fixtures/local_sms_cases.json').readAsStringSync())
          as List;
  for (var i = 0; i < fixtures.length; i++) {
    final fixture = fixtures[i] as Map<String, dynamic>;
    test('shared SMS fixture $i', () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VM-HDFCBK',
        body: fixture['body'] as String,
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction?.amount.rupees, fixture['amount']);
      if (fixture['amount'] != null) {
        expect(looksLikeTransactionSms(fixture['body'] as String), isTrue);
        expect(
          result!.transaction!.instrument.wireValue,
          fixture['instrument'],
        );
        expect(result.transaction!.entryKind.wireValue, fixture['kind']);
        expect(result.transaction!.rewardValue, isNull);
      }
      if (fixture['dueDay'] != null) {
        expect(result?.dueDate?.day, fixture['dueDay']);
      }
    });
  }
  test('date parsing rejects rollover and supports day-first ordinals', () {
    expect(LocalSmsParser.parseDate('31/02/2026'), isNull);
    expect(LocalSmsParser.parseDate('3rd Apr 2026'), DateTime(2026, 4, 3));
    expect(LocalSmsParser.parseDate('2026-10-18'), DateTime(2026, 10, 18));
  });
}
