import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;

const _myBillBookReceipt =
    'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
    'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
    '- myBillBook';

const _sbiCurrencylessDebit =
    'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct26 trf to Sunali '
    'Mundra Refno 665663775318 If not u? call-1800111109 for other '
    'services-18001234-SBI';

SmsRuleBundle _postedMovementBundle(String senderPattern) => SmsRuleBundle(
  bundleVersion: 1,
  sha256: '',
  publishedAt: DateTime(2026, 10, 1),
  minClientVersion: '1.0.0',
  rules: [
    RestrictedSmsRule.fromJson({
      'id': 'posted-movement-rule',
      'family': 'posted_movement',
      'senderPattern': senderPattern,
      'regex': r'Rs\.?\s*([\d,]+(?:\.\d+)?)',
      'fieldMap': {'amount': 1},
    })!,
  ],
);

void main() {
  group('arbitrary named-shop receipts', () {
    test('exact myBillBook receipt extracts payee and amount without spend', () {
      expect(LocalSmsParser.isMerchantReceiptOrEbill(_myBillBookReceipt), isTrue);
      expect(
        LocalSmsParser.isNonTransactionNoise('CP-MBILBK-S', _myBillBookReceipt),
        isFalse,
      );
      expect(
        LocalSmsParser.extractReceiptMerchant(_myBillBookReceipt),
        equals('Balaji Sports'),
      );
      expect(LocalSmsParser.extractReceiptAmount(_myBillBookReceipt)?.paise, 70000);

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'CP-MBILBK-S',
        body: _myBillBookReceipt,
        receivedAt: DateTime(2026, 10, 22, 18, 5),
      );

      expect(parsed, isNotNull);
      expect(parsed!.disposition, LocalSmsDisposition.review);
      expect(parsed.eventType, LocalSmsEventType.unknown);
      expect(parsed.transaction, isNull);
      expect(parsed.amount?.paise, 70000);
      expect(parsed.billerName, equals('Balaji Sports'));
      expect(parsed.reasonCodes, contains('merchant_ebill_receipt'));
      expect(parsed.reasonCodes, contains('receipt_amount_extracted'));
      expect(parsed.reasonCodes, contains('receipt_merchant_extracted'));

      final draft = LocalSmsParser.reviewDraft(
        namespace: 'user:test',
        sender: 'CP-MBILBK-S',
        body: _myBillBookReceipt,
        receivedAt: DateTime(2026, 10, 22, 18, 5),
      );
      expect(draft.amount?.paise, 70000);
      expect(draft.merchantName, equals('Balaji Sports'));
      expect(draft.instrument, TxnInstrument.other);
      expect(draft.occurredAt, DateTime(2026, 10, 22, 18, 5));
    });

    test('payee is grammatical, not hardcoded, across shops and statuses', () {
      const kirana =
          'Your payment of INR 1,250.50 to Sharma Kirana Store has been '
          'recorded. View the payment receipt here: '
          'https://mybillbook.in/cpp/?t=abc123 - myBillBook';
      const chai =
          'Payment of Rs 40 to Chai Point was recorded. View the payment '
          'receipt here: https://mybillbook.in/cpp/?t=chai99 - myBillBook';

      expect(LocalSmsParser.isMerchantReceiptOrEbill(kirana), isTrue);
      expect(LocalSmsParser.extractReceiptMerchant(kirana), 'Sharma Kirana Store');
      expect(LocalSmsParser.extractReceiptAmount(kirana)?.paise, 125050);

      expect(LocalSmsParser.isMerchantReceiptOrEbill(chai), isTrue);
      expect(LocalSmsParser.extractReceiptMerchant(chai), 'Chai Point');

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'CP-MBILBK-S',
        body: kirana,
        receivedAt: DateTime(2026, 10, 22),
      );
      expect(parsed?.transaction, isNull);
      expect(parsed?.amount?.paise, 125050);
      expect(parsed?.billerName, 'Sharma Kirana Store');
    });

    test('order confirmation payee comes from the receipt clause', () {
      const body =
          'Dear GUEST USER, Thank you for your purchase @ Apollo Pharmacy. '
          'Click here http://ms1.in/APLPHR/Vut/3RfdG to download your bill '
          'for Rs.413.10 APLPHR';

      expect(LocalSmsParser.isMerchantReceiptOrEbill(body), isTrue);
      expect(LocalSmsParser.extractReceiptMerchant(body), 'Apollo Pharmacy');
      expect(LocalSmsParser.extractReceiptAmount(body)?.paise, 41310);
    });

    test('ids are rejected but numeric brands and unicode survive', () {
      expect(
        LocalSmsParser.extractReceiptMerchant(
          'Your payment of Rs 500 to A1B2C3D4E5F6 has been recorded. '
          'View the payment receipt here: https://mybillbook.in/cpp/?t=x',
        ),
        isNull,
      );
      expect(
        LocalSmsParser.extractReceiptMerchant(
          'Your payment of Rs 99 to 3M has been recorded. View the payment '
          'receipt here: https://mybillbook.in/cpp/?t=x',
        ),
        '3M',
      );
      expect(
        LocalSmsParser.extractReceiptMerchant(
          'Your payment of Rs 99 to 7 Eleven has been recorded. View the '
          'payment receipt here: https://mybillbook.in/cpp/?t=x',
        ),
        '7 Eleven',
      );
      expect(
        LocalSmsParser.extractReceiptMerchant(
          'Your payment of Rs 300 to सुशील कुमार has been recorded. View the '
          'payment receipt here: https://mybillbook.in/cpp/?t=x',
        ),
        'सुशील कुमार',
      );
    });
  });

  group('currencyless bank debit clauses', () {
    test('exact SBI alert parses amount, compact date and clean payee', () {
      expect(
        LocalSmsParser.isNonTransactionNoise('AX-SBIUPI-S', _sbiCurrencylessDebit),
        isFalse,
      );

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body: _sbiCurrencylessDebit,
        receivedAt: DateTime(2026, 10, 18, 9, 30),
      );

      expect(parsed, isNotNull);
      expect(parsed!.eventType, LocalSmsEventType.transaction);
      expect(parsed.disposition, LocalSmsDisposition.sync);
      expect(parsed.transaction, isNotNull);
      expect(parsed.transaction!.amount.paise, 5000);
      expect(parsed.transaction!.merchantName, 'Sunali Mundra');
      expect(parsed.transaction!.accountLast4, '5121');
      expect(parsed.transaction!.instrument, TxnInstrument.upiBank);
      expect(parsed.transaction!.entryKind, TxnEntryKind.spend);
      // 17Oct26 is the printed transaction date, not the receive date.
      expect(parsed.transaction!.occurredAt, DateTime(2026, 10, 17));

      final draft = LocalSmsParser.reviewDraft(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body: _sbiCurrencylessDebit,
        receivedAt: DateTime(2026, 10, 18, 9, 30),
      );
      expect(draft.amount?.paise, 5000);
      expect(draft.merchantName, 'Sunali Mundra');
      expect(draft.occurredAt, DateTime(2026, 10, 17));
    });

    test('currencyless debit is not replaced by an available balance', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test', sender: 'AX-SBIUPI-S',
        body: '$_sbiCurrencylessDebit Avail Bal Rs 1200.00.',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.transaction?.amount.paise, 5000);
      expect(parsed?.transaction?.merchantName, 'Sunali Mundra');
    });

    test('bank recipient cleanup excludes a recorded sentence suffix', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test', sender: 'AX-SBIUPI-S',
        body: 'Rs 700 debited from A/c XX5121 to Balaji Sports has been recorded.',
        receivedAt: DateTime(2026, 10, 24),
      );
      expect(parsed?.transaction?.merchantName, 'Balaji Sports');
      expect(parsed?.transaction?.amount.paise, 70000);
    });

    test('Rs ref variant keeps the same clean payee and amount', () {
      const body =
          'Dear UPI User A/C X5121 debited by Rs 50.00 on date 17Oct26 trf to '
          'Sunali Mundra Refno 665663775318 If not u? call-1800111109 for '
          'other services-18001234-SBI';

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body: body,
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.transaction?.amount.paise, 5000);
      expect(parsed?.transaction?.merchantName, 'Sunali Mundra');
      expect(parsed?.transaction?.occurredAt, DateTime(2026, 10, 17));
    });

    test('compact future date falls back to the receive date', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body:
            'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct27 trf to '
            'Sunali Mundra Refno 665663775318 -SBI',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.transaction?.occurredAt, DateTime(2026, 10, 18));
    });

    test('a bare number outside a movement clause is not an amount', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body:
            'Dear UPI User A/C X5121 50.00 on date 17Oct26 trf to Sunali '
            'Mundra Refno 665663775318 -SBI',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.amount, isNull);
      expect(parsed?.transaction, isNull);
    });

    test('review draft does not invent a currencyless amount for a receipt', () {
      const body =
          'Hello, your bill of 700.0 is ready. View the bill here: '
          'https://example.com/b/1';
      final draft = LocalSmsParser.reviewDraft(
        namespace: 'user:test',
        sender: 'VM-BANK-S',
        body: body,
        receivedAt: DateTime(2026, 10, 22),
      );
      expect(draft.amount, isNull);
    });
  });

  group('failed, future and receipt safety before downloaded rules', () {
    test('failed notice with no money moved is acknowledged, never spent', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body:
            'Dear UPI User A/C X5121 debit of 50.00 to Sunali Mundra failed. '
            'No money debited. If not u? call-1800111109 -SBI',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.transaction, isNull);
      expect(parsed?.eventType, LocalSmsEventType.failed);
      expect(parsed?.disposition, LocalSmsDisposition.localIgnore);
      expect(parsed?.reasonCodes, contains('unsuccessful_transaction'));
    });

    test('failed debit wording alone never becomes posted spending', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body:
            'Dear UPI User A/C X5121 debit of 50.00 to Sunali Mundra failed. '
            'If not u? call-1800111109 -SBI',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(parsed?.transaction, isNull);
    });

    test('would/shall/will obligations never sync through a downloaded rule', () {
      for (final body in const [
        'Rs 500 would be debited from A/c XX1234 on 25-10-2026 towards NETFLIX',
        'Rs 500 will be debited from A/c XX1234 on 25-10-2026 towards NETFLIX',
        'Rs 500 shall be deducted from A/c XX1234 on 25-10-2026 towards NETFLIX',
      ]) {
        final parsed = LocalSmsParser.parse(
          namespace: 'user:test',
          sender: 'AX-SBIUPI-S',
          body: body,
          receivedAt: DateTime(2026, 10, 18),
          downloadedRules: _postedMovementBundle('SBIUPI'),
        );
        expect(
          parsed?.transaction,
          isNull,
          reason: 'future obligation must not become spend: $body',
        );
        expect(parsed?.eventType, isNot(LocalSmsEventType.transaction));
        expect(
          parsed?.reasonCodes,
          isNot(contains('downloaded_rule_match')),
          reason: 'downloaded rule must be blocked: $body',
        );
      }
    });

    test('completed debit with a downloaded rule still syncs exactly once', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body: 'Rs 500.00 debited from A/c XX1234 on 25-10-2026 towards NETFLIX',
        receivedAt: DateTime(2026, 10, 25),
        downloadedRules: _postedMovementBundle('SBIUPI'),
      );
      expect(parsed?.transaction, isNotNull);
      expect(parsed?.transaction?.amount.paise, 50000);
      expect(parsed?.disposition, LocalSmsDisposition.sync);
      expect(parsed?.reasonCodes, contains('downloaded_rule_match'));
    });

    test('merchant receipt with a bank debit stays one posted spend', () {
      const body =
          'Rs 700.0 debited from A/c XX5121 to Balaji Sports on 17Oct26. '
          'Your payment of Rs. 700.0 to Balaji Sports has been recorded. '
          'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
          '- myBillBook';

      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-SBIUPI-S',
        body: body,
        receivedAt: DateTime(2026, 10, 18),
      );

      expect(parsed?.transaction, isNotNull);
      expect(parsed?.disposition, LocalSmsDisposition.sync);
      expect(parsed?.transaction?.amount.paise, 70000);
      expect(parsed?.transaction?.merchantName, 'Balaji Sports');
      expect(parsed?.reasonCodes, isNot(contains('merchant_ebill_receipt')));
    });

    test('a receipt payment method is not a separate bank debit', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test', sender: 'CP-MBILBK-S',
        body: 'You paid Rs 700 to Balaji Sports by credit card. View the payment receipt.',
        receivedAt: DateTime(2026, 10, 24),
      );
      expect(parsed?.transaction, isNull);
      expect(parsed?.disposition, LocalSmsDisposition.review);
    });

    test('receipt without instrument stays review even with a posted rule', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'CP-MBILBK-S',
        body: _myBillBookReceipt,
        receivedAt: DateTime(2026, 10, 22),
        downloadedRules: _postedMovementBundle('MBILBK'),
      );
      expect(parsed?.transaction, isNull);
      expect(parsed?.disposition, LocalSmsDisposition.review);
      expect(parsed?.reasonCodes, contains('merchant_ebill_receipt'));
      expect(parsed?.reasonCodes, isNot(contains('downloaded_rule_match')));
    });
  });
}
