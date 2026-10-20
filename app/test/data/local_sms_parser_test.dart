import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TxnEntryKind;
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  test(
    'both legs of an explicit own-bank transfer stay out of spending and income',
    () {
      final debit = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'HDFCBK',
        body:
            'Sent Rs.5000.00 From your HDFC Bank A/C *1797 To your Canara Bank A/C *5702 On 13/10/26 Ref 131234538577',
        receivedAt: DateTime(2026, 10, 18),
      );
      final credit = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'CANARA',
        body:
            'Your Canara Bank account *5702 was credited with Rs.5000 from your HDFC Bank account *1797 to your Canara Bank account *5702. Ref 131234538577',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(debit?.transaction?.entryKind, TxnEntryKind.transfer);
      expect(debit?.transaction?.accountLast4, '1797');
      expect(credit?.transaction?.entryKind, TxnEntryKind.transfer);
      expect(credit?.transaction?.accountLast4, '5702');
    },
  );

  test(
    'an unclear bank debit needs review, while a named recipient is spending',
    () {
      final unclear = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'BANK',
        body:
            'A/c *8565 Debited for Rs:2.00 on 08-07-2025 by Mob Bk ref no 4987654321',
        receivedAt: DateTime(2026, 10, 18),
      );
      final person = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'BANK',
        body:
            'Sent Rs.5000.00 From HDFC Bank A/C *1797 To ANOTHER PERSON On 13/10/26 Ref 131234538577',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(unclear?.transaction, isNull);
      expect(unclear?.disposition, LocalSmsDisposition.review);
      expect(person?.transaction?.entryKind, TxnEntryKind.spend);
    },
  );

  test('cash withdrawal and SIP debit are not spending', () {
    final withdrawal = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs.20000 withdrawn from HDFC Bank Card x8406 at ATM on 13/10/26.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final sip = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Your HDFC Bank A/c *1797 was debited by Rs.5000 for Mutual Fund SIP on 13/10/26.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(withdrawal?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(sip?.transaction?.entryKind, TxnEntryKind.investment);
  });
  test('card bill repayment is a transfer, card purchase is spending', () {
    final payment = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'AXISBK',
      body:
          'Rs. 80000 debited from your account for Axis Bank Flipkart Credit Card ending 2006.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final purchase = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'AXISBK',
      body:
          'Rs. 80000 spent on your Axis Bank Flipkart Credit Card ending 2006 at FLIPKART INTERNET.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(payment?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(purchase?.transaction?.entryKind, TxnEntryKind.spend);
  });
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
  test('LIC future debit reminders keep distinct policy identities', () {
    LocalSmsObservation? parse(String policy) => LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VA-LICIND-S',
      body:
          'Please keep sufficient funds in your account for LIC policy no $policy premium Rs. 2500 which will be debited on 25-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    );
    final first = parse('12345678');
    final second = parse('87654321');
    expect(first?.eventType, LocalSmsEventType.bill);
    expect(first?.dueDate, DateTime(2026, 10, 25));
    expect(first?.accountLast4, '5678');
    expect(second?.accountLast4, '4321');
    expect(first?.transaction, isNull);
  });

  test('LIC bank account digits are not mistaken for a policy number', () {
    final reminder = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VA-LICIND-S',
      body:
          'Keep sufficient funds in bank account 1234 for LIC premium due on 25-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    );
    expect(reminder?.eventType, LocalSmsEventType.bill);
    expect(reminder?.accountLast4, isNull);
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

  test('classifies a recharge promotion locally without creating spending', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'JM-JIOINF-P',
      body:
          'Want to keep your number active? Recharge with Rs.349 today and get an additional Rs.349 recharge FREE. Offer valid today.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNull);
    expect(result?.eventType, LocalSmsEventType.promotion);
    expect(result?.disposition, LocalSmsDisposition.localIgnore);
  });

  test('does not classify a plain completed recharge as a promotion', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-JIOINF-T',
      body: 'Recharge of Rs.349 successful on your Jio number.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, LocalSmsEventType.unknown);
    expect(result?.disposition, LocalSmsDisposition.review);
  });

  test('keeps existing spend-and-cashback offers out of spending review', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK-P',
      body:
          'Spend INR 15000 on your card and get cashback of INR 250. Offer valid this month.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNull);
    expect(result?.eventType, LocalSmsEventType.promotion);
    expect(result?.disposition, LocalSmsDisposition.localIgnore);
  });

  test('does not ignore a completed recharge that also contains an offer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-JIOINF-T',
      body:
          'Recharge of Rs.349 successful. Get an additional Rs.349 recharge FREE.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, isNot(LocalSmsEventType.promotion));
    expect(result?.disposition, isNot(LocalSmsDisposition.localIgnore));
  });

  test('keeps failed alerts with an actual debit reviewable', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK-B',
      body:
          'Payment failed, but your account was debited INR 500. The amount will be refunded.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, LocalSmsEventType.unknown);
    expect(result?.disposition, LocalSmsDisposition.review);
    expect(result?.transaction, isNull);
  });

  test('classifies AutoPay activation as a local observation, not spending', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-AXISBK-S',
      body:
          'AutoPay activation successful. Txn amt: INR 0.00 Merchant: OpenAI LLC Axis Bank Card no.: XX7105 Max limit: INR 1999.00.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNull);
    expect(result?.eventType, LocalSmsEventType.autopay);
    expect(result?.disposition, LocalSmsDisposition.localIgnore);
    expect(result?.autopayLimit?.rupees, 1999);
  });

  test('does not ignore a completed AutoPay debit as setup', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-AXISBK-S',
      body:
          'AutoPay debit of INR 1000 on credit card XX7105 at NETFLIX was successful.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, LocalSmsEventType.transaction);
    expect(result?.disposition, LocalSmsDisposition.sync);
    expect(result?.transaction?.amount.rupees, 1000);
  });

  test('keeps a completed reversal as incoming money', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-ICICIB',
      body: 'INR 200 reversed to your account XX1234.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, LocalSmsEventType.transaction);
    expect(result?.disposition, LocalSmsDisposition.sync);
    expect(result?.transaction?.entryKind, TxnEntryKind.income);
    expect(result?.transaction?.amount.rupees, 200);
  });

  test('keeps due reminders as observations and preserves their due date', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-ICICIB',
      body:
          'Your credit card XX4321 payment due on 20-Oct-2026. Total amount due INR 3000.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNull);
    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.disposition, LocalSmsDisposition.localObservation);
    expect(result?.amountDue?.rupees, 3000);
    expect(result?.dueDate?.day, 20);
    expect(result?.statementDate, isNull);
  });

  test('keeps the statement-generation day separately from the due date', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK',
      body:
          'Your statement for HDFC Bank Credit Card ending XX8708 is generated. Due on: 20-Oct-2026.',
      receivedAt: DateTime(2026, 9, 5),
    );
    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.statementDate?.day, 5);
    expect(result?.dueDate?.day, 20);
  });

  test('extracts the provider name and bill amount from a bill reminder', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'JX-TNBPAY-S',
      body:
          'Your Alegra Communication Private Limited bill of Rs.1600.00 is due on 2026-09-29. Pay by 2026-09-29.',
      receivedAt: DateTime(2026, 9, 20),
    );

    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.billerName, 'Alegra Communication Private Limited');
    expect(result?.amountDue?.rupees, 1600);
    expect(result?.confidence, greaterThanOrEqualTo(0.85));
  });

  test('review draft pre-fills unresolved transaction suggestions', () {
    final draft = LocalSmsParser.reviewDraft(
      namespace: 'user:test',
      sender: 'VM-UNKNOWN',
      body:
          'Your account was charged INR 875.50 at Green Basket on 16-Oct-2026.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(draft.amount?.rupees, 875.5);
    expect(draft.merchantName, 'Green Basket');
    expect(draft.occurredAt, DateTime(2026, 10, 16));
    expect(draft.entryKind, TxnEntryKind.spend);
  });

  test('review draft does not prefill non-transaction amounts', () {
    final bill = LocalSmsParser.reviewDraft(
      namespace: 'user:test',
      sender: 'VM-ICICIB',
      body:
          'Your credit card XX4321 payment due on 20-Oct-2026. Total amount due INR 3000.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final promotion = LocalSmsParser.reviewDraft(
      namespace: 'user:test',
      sender: 'JM-JIOINF-P',
      body:
          'Recharge with Rs.349 today and get an additional Rs.349 recharge FREE.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(bill.amount, isNull);
    expect(bill.merchantName, isNull);
    expect(promotion.amount, isNull);
    expect(promotion.merchantName, isNull);
  });
}
