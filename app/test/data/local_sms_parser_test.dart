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

  test('bank account narration without self wording is a transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'CANBNK',
      body:
          'Rs.80000 transferred from Canara Bank A/c XX2626 to HDFC Bank A/c XX9080. UTR 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.accountLast4, '2626');
  });

  test('wallet top-up is a transfer and wallet merchant payment is spending', () {
    final topUp = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'PAYTM',
      body:
          'Rs.5000 added to Paytm wallet from your bank account. UPI Ref 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final purchase = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'PAYTM',
      body:
          'Rs.5000 paid to grocery@upi from your bank account via UPI. UPI Ref 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(topUp?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(purchase?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('abbreviated card bill payment is a transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'CANBNK',
      body: 'IMPS CC PMT Rs.80000 debited from Canara A/c XX2626. UTR 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
  });

  test('generic bank-origin credit is a transfer candidate', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Your HDFC Bank A/c XX9080 is credited with Rs.80,000 from CANARA BANK. UTR 123456789012. Avl Bal Rs.1,20,000.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Bank transfer');
  });

  test('unlabelled credit, refund, reward, loan and fee classifications stay out of income', () {
    final credit = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Your HDFC Bank A/c XX9080 is credited with Rs.80,000. UTR 123456789012. Avl Bal Rs.1,20,000.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final refund = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body:
          'Refund of Rs.250 received in your savings account ending 5799 from AMAZON.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final reward = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: 'Cashback of INR 80 credited to your wallet.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final loan = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: 'EMI repayment of Rs.12000 debited from your bank account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    final fee = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: 'Service charge of Rs.250 debited from your bank account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(credit?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(refund?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(reward?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(loan?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(fee?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('card refunds, reversals and statement rewards remain transfers', () {
    LocalSmsObservation? parse(String body) => LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: body,
      receivedAt: DateTime(2026, 10, 18),
    );
    for (final body in [
      'Your credit card ending 7788 was credited Rs.250 as refund from AMAZON.',
      'Reversal of Rs.500 posted to your credit card ending 7788.',
      'Cashback of Rs.80 credited to your credit card ending 7788.',
      'Statement credit of Rs.100 applied to card ending 7788.',
    ]) {
      final result = parse(body);
      expect(result?.transaction?.entryKind, TxnEntryKind.transfer, reason: body);
    }
  });

  test('salary advance is a loan movement, not earned income', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: 'Salary advance of Rs.25000 credited to your bank account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Loan disbursement');
  });

  test('income words inside a reversal or refund do not make it earned income', () {
    for (final body in [
      'Interest reversal of Rs.500 credited to your account ending 2626.',
      'Dividend refund of Rs.250 credited to your account ending 2626.',
    ]) {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'BANK',
        body: body,
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction?.entryKind, TxnEntryKind.transfer, reason: body);
    }
  });

  test('investment redemption proceeds are not treated as a new contribution', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body:
          'Mutual fund redemption proceeds of Rs.5000 credited to your account ending 2626.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Investment proceeds');
  });

  test('broker settlement payout to the bank is an investment-proceeds transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-DHANHQ-S',
      body:
          'Dear Sujay We have transferred Rs 93.82 to your bank account ending with XXXXXXX2626 as a part of running account settlement vide Ref No PO26101713812965. To continue trading and investing, add funds back to your Dhan account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Investment proceeds');
    expect(result?.transaction?.accountLast4, '2626');
  });

  test('named wallet top-up still parses as a wallet load transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'PAYTM',
      body: 'Rs.5000 added to Paytm wallet from your bank account. UPI Ref 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Wallet load');
  });

  test('broker refill instruction is not a wallet load of this transaction', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-ZERODHA',
      body:
          'Rs 2500 payout credited to your bank a/c XX9123. To continue investing, add funds back to your Zerodha account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, isNot('Wallet load'));
  });

  test('a debit addressed to the profile name is a self-transfer, not spending', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Sent Rs.5000.00 From HDFC Bank A/C *1797 To SUJAY SHANTARAM KURTIKAR. Not you? Call 1800. Ref 12345678',
      receivedAt: DateTime(2026, 10, 18),
      ownUserName: 'Sujay Shantaram Kurtikar',
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Transfer between own accounts');
  });

  test('same person named without a profile name stays a spend', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Sent Rs.5000.00 From HDFC Bank A/C *1797 To SUJAY SHANTARAM KURTIKAR. Not you? Call 1800. Ref 12345678',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('a different named recipient stays spending even with a profile name', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Sent Rs.5000.00 From HDFC Bank A/C *1797 To PRIYA VASANTA RAJAN. Not you? Call 1800. Ref 12345678',
      receivedAt: DateTime(2026, 10, 18),
      ownUserName: 'Sujay Shantaram Kurtikar',
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('a credit received from the profile name is not income', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Rs.5000.0 credited to your HDFC Bank A/C *9080 from SUJAY SHANTARAM KURTIKAR on 20-10-26. Ref 99887765',
      receivedAt: DateTime(2026, 10, 18),
      ownUserName: 'Sujay Shantaram Kurtikar',
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Transfer between own accounts');
  });

  test('explicit loan interest fees count as spending', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BANK',
      body: 'Loan interest charge of Rs.500 debited from your account ending 2626.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
    expect(result?.transaction?.merchantName, 'Bank or service fee');
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

  test(
    'screens screenshot promotions and service notices without hiding real transactions',
    () {
      const ignored = <(String, String)>[
        (
          'TX-WAKFTT-P',
          'Luxury on a budget? Treat yourself to Wakefit sofa at just Rs.28,125. Grab offer https://gs.im/x',
        ),
        (
          'VA-LIFSTL-P',
          'Make Festive Shopping More Rewarding! Shop at Lifestyle stores and get vouchers worth Rs.10,000.',
        ),
        (
          'BP-SBICRD-S',
          'Dear Cardholder, trxns. of combined value Rs.40016 are eligible for conversion to Flexipay EMIs. Click link.',
        ),
        (
          'VA-SBIBNK-S',
          'Dear SBI customer, RINB/YONO services is being blocked due to suspicious txns in your account. Visit nearest branch.',
        ),
        (
          'AY-AIRTEL-P',
          'Breaking news: 5-Din ka Airtel International Roaming pack. Payein sirf Rs.999.',
        ),
      ];
      for (final (sender, body) in ignored) {
        expect(
          LocalSmsParser.isNonTransactionNoise(sender, body),
          isTrue,
          reason: body,
        );
      }
      expect(
        LocalSmsParser.isNonTransactionNoise(
          'AD-FEDSCP-S',
          'Your txn of ₹1,018.00 at 3 Rajdhani Parantha House on your credit card earned you 5% rewards!',
        ),
        isFalse,
      );
      expect(
        LocalSmsParser.isNonTransactionNoise(
          'VM-JIOINF-T',
          'Recharge of Rs.349 successful. Get an additional recharge FREE.',
        ),
        isFalse,
      );
    },
  );

  test('keeps bills and posted purchases with offer footers', () {
    expect(
      LocalSmsParser.isNonTransactionNoise(
        'VM-BANK-S',
        'Your card XX1234 was debited Rs.500 at STORE. Get 5% cashback on your next purchase.',
      ),
      isFalse,
    );
    expect(
      LocalSmsParser.isNonTransactionNoise(
        'VM-BANK-S',
        'Your credit card bill of Rs.5000 is due on 25 Oct. Get cashback when you pay.',
      ),
      isFalse,
    );
    expect(
      LocalSmsParser.sensitive(
        'Purchase of Rs.1200 completed. Offer valid for next order.',
      ),
      isFalse,
    );
    expect(LocalSmsParser.sensitive('123456 valid for 10 minutes.'), isTrue);
    expect(
      LocalSmsParser.isNonTransactionNoise(
        'BP-SBICRD-S',
        'You spent Rs.40016 on your SBI Credit Card and are eligible for conversion to Flexipay EMIs.',
      ),
      isTrue,
    );
    final bill = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-BANK-S',
      body:
          'Your credit card bill of Rs.5000 is due on 25 Oct. Get cashback when you pay.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(bill?.eventType, LocalSmsEventType.bill);
    expect(bill?.disposition, LocalSmsDisposition.localObservation);
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

  test('keeps a completed reversal as a synced money-in transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-ICICIB',
      body: 'INR 200 reversed to your account XX1234.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.eventType, LocalSmsEventType.transaction);
    expect(result?.disposition, LocalSmsDisposition.sync);
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
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
