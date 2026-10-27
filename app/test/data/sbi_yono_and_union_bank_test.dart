import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/sms_gate_filter.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;

void main() {
  group('Real Device Union Bank & SBI / YONO Parsing Verification', () {
    test('Union Bank credit with "Never Share OTP/PIN/CVV" is a bank transaction, NOT investment', () {
      const msg =
          'A/c *8565 Credited for Rs:2900.00 on 26-10-2026 17:48:45 by Mob Bk ref no 629947468298 Avl Bal Rs:4625.92.Never Share OTP/PIN/CVV-Union Bank of India';
      
      expect(LocalSmsParser.isBankAccountMessage(msg, 'VA-UNIONB-S'), isTrue);

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VA-UNIONB-S',
        body: msg,
        receivedAt: DateTime(2026, 10, 26, 17, 48),
      );

      expect(parsed, isNotNull);
      expect(parsed!.disposition, equals(LocalSmsDisposition.sync));
      expect(parsed.eventType, equals(LocalSmsEventType.transaction));
      expect(parsed.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, equals(290000));
      expect(parsed.transaction!.accountLast4, equals('8565'));
      expect(parsed.transaction!.entryKind, isNot(equals(TxnEntryKind.investment)));
      expect(parsed.transaction!.merchantName, isNot(equals('Investment')));
    });

    test('Today Union Bank credit is recognized properly', () {
      const msg =
          'A/c *8565 Credited for Rs:500.00 on 27-10-2026 12:31:12 by Mob Bk ref no 666601598393 Avl Bal Rs:5125.92.Never Share OTP/PIN/CVV-Union Bank of India';

      expect(LocalSmsParser.isBankAccountMessage(msg, 'JD-UNIONB-S'), isTrue);

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'JD-UNIONB-S',
        body: msg,
        receivedAt: DateTime(2026, 10, 27, 12, 31),
      );

      expect(parsed, isNotNull);
      expect(parsed!.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, equals(50000));
      expect(parsed.transaction!.accountLast4, equals('8565'));
      expect(parsed.transaction!.entryKind, isNot(equals(TxnEntryKind.investment)));
    });

    test('SBI YONO UPI debit extracts counterparty merchant, NOT "YONO"', () {
      const msg =
          'Dear UPI/YONO user, Rs.500.00 debited from A/c No. XX1234 on 26-Oct-26 to VPA/Merchant Ref 1234567890 Available Bal: Rs.1000.00 -SBI';

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'JK-SBIUPI-S',
        body: msg,
        receivedAt: DateTime(2026, 10, 26, 12, 0),
      );

      expect(parsed, isNotNull);
      expect(parsed!.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, equals(50000));
      expect(parsed.transaction!.accountLast4, equals('1234'));
      expect(parsed.transaction!.merchantName, equals('Merchant'));
      expect(parsed.transaction!.entryKind, equals(TxnEntryKind.spend));
    });

    test('SBI YONO transfer debit extracts recipient, NOT source account', () {
      const msg =
          'Dear Customer, Rs 2,500.00 debited from A/C XX4321 on 24-10-26 transfer to Ramesh via YONO SBI ref 987654321. Avl Bal Rs 8,000.00';

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'SBIBNK',
        body: msg,
        receivedAt: DateTime(2026, 10, 24, 12, 0),
      );

      expect(parsed, isNotNull);
      expect(parsed!.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, equals(250000));
      expect(parsed.transaction!.accountLast4, equals('4321'));
      expect(parsed.transaction!.merchantName, equals('Ramesh'));
    });

    test('SBYONO DLT sender maps canonically to sbi and renders SBI', () {
      expect(canonicalBankSender('BZ-SBYONO-S'), equals('sbi'));
      expect(canonicalBankSender('SBYONO'), equals('sbi'));
      expect(canonicalBankSender('SBIYON'), equals('sbi'));
      expect(canonicalBankSender('YONOSB'), equals('sbi'));
      expect(bankDisplayLabel('sbyono'), equals('SBI'));
    });

    test('YONO Bill payment confirmation is parsed as transaction spend, not dropped as balance', () {
      const msg =
          'Payment of Rs 1,199.00 towards Airtel Postpaid from A/C XX1234 successful via YONO on 26-Oct-26. Ref: 987654. Avl Bal Rs: 30,000.00';

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'SBIBNK',
        body: msg,
        receivedAt: DateTime(2026, 10, 26, 12, 0),
      );

      print('YONO Bill payment parsed: eventType=${parsed?.eventType}, disp=${parsed?.disposition}, reasons=${parsed?.reasonCodes}, amount=${parsed?.amount?.paise}, biller=${parsed?.billerName}');

      expect(parsed, isNotNull);
      expect(parsed!.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, equals(119900));
      expect(parsed.transaction!.accountLast4, equals('1234'));
      expect(parsed.transaction!.merchantName, equals('Airtel Postpaid'));
      expect(parsed.transaction!.entryKind, equals(TxnEntryKind.spend));
    });
  });
}
