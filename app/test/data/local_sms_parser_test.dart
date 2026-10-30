import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'package:pandapay/data/merchant_identity.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  test('HDFC UPI credit alert is captured as an incoming transaction', () {
    const sender = 'AX-HDFCBK-S';
    const body = 'Credit Alert! Rs.1.00 credited to HDFC Bank A/c XX5552 on 30-10-26 from VPA *r123@oksbi (UPI 630371662093)';
    expect(capturesFinancialSms(body, sender: sender), isTrue);
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: sender,
      body: body,
      receivedAt: DateTime(2026, 10, 30, 13, 37),
    );
    expect(result?.eventType, LocalSmsEventType.transaction);
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.amount.rupees, 1);
    expect(result?.transaction?.entryKind, TxnEntryKind.income);
  });
  test('explicit service renewal keeps stated amount and next date', () {
    final result = LocalSmsParser.parse(
      namespace: 'test',
      sender: '5550101',
      body:
          'Subscription for ChatGPT Plus renewed. Monthly plan payment Rs.499 paid on 29-Oct-2026. Next renewal 29-Nov-2026.',
      receivedAt: DateTime.utc(2026, 10, 29),
    );
    expect(result?.eventType, LocalSmsEventType.autopay);
    expect(result?.billerName, 'ChatGPT Plus');
    expect(result?.amountDue?.rupees, 499);
    expect(result?.dueDate, DateTime(2026, 11, 29));
  });
  test(
    'purchase confirmation with downloadable bill is classified as receipt',
    () {
      const body =
          'Dear GUEST USER, Thank you for your purchase @ Apollo Pharmacy. '
          'Click here http://ms1.in/APLPHR/Vut/3RfdG to download your bill '
          'for Rs.413.10 APLPHR';

      expect(LocalSmsParser.isMerchantReceiptOrEbill(body), isTrue);
      expect(LocalSmsParser.extractReceiptAmount(body)?.paise, 41310);
      expect(
        NeedsReviewRepository.resolveItemKind(
          NeedsReviewItem(
            id: 'apollo-receipt',
            sender: 'CP-APLPHR-S',
            body: body,
            receivedAt: DateTime(2026, 9, 28, 22, 8),
          ),
        ).kind,
        NeedsReviewKind.receipt,
      );
    },
  );

  test('completed auto-debit is not treated as a future reminder', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body:
          'Rs 500 was auto-debited from A/c XX1797 for NETFLIX on 20-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    );
    expect(result?.eventType, LocalSmsEventType.transaction);
    expect(result?.transaction, isNotNull);
  });
  test('Axis card merchant after transaction date and time is extracted', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-AXISBK-S',
      body:
          'Spent INR 505 Axis Bank Card no. XX0000 02-10-26 23:11:37 IST FLIPKART PA Avl Limit: INR 77901 Not you? SMS BLOCK 0000 to 9000000000',
      receivedAt: DateTime(2026, 10, 2, 23, 12),
    );
    expect(result?.transaction?.merchantName, 'FLIPKART PA');
    expect(result?.transaction?.cardLast4, '0000');
    expect(
      result?.transaction?.occurredAt.toUtc(),
      DateTime.utc(2026, 10, 2, 17, 41, 37),
    );
  });
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
    'a completed bank debit counts as spending even without a named recipient',
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
      expect(unclear?.transaction?.entryKind, TxnEntryKind.spend);
      expect(unclear?.transaction?.merchantName, 'Bank debit');
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
      body:
          'IMPS CC PMT Rs.80000 debited from Canara A/c XX2626. UTR 123456789012.',
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

  test(
    'unlabelled credit, refund, reward, loan and fee classifications stay out of income',
    () {
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
    },
  );

  test(
    'credited EMI repayment alerts are loan repayments, not income',
    () {
      for (final body in [
        'Dear Customer, your account no. XX3510 has been credited with Rs.6300 towards the payment of EMI on 04-10-2026. UCO Bank',
        'Dear Customer, your account no. XX2315 has been credited with Rs.9700 towards the payment of EMI on 04-10-2026. UCO Bank',
        'Loan EMI payment of Rs.5000 credited to your account ending 2626.',
        'Your a/c XX4455 has been credited with Rs.8500. Equated Monthly Installment received towards home loan. SBI',
      ]) {
        final result = LocalSmsParser.parse(
          namespace: 'user:test',
          sender: 'VM-UCOBNK-S',
          body: body,
          receivedAt: DateTime(2026, 10, 4),
        );
        expect(
          result?.transaction?.entryKind,
          TxnEntryKind.transfer,
          reason: body,
        );
        expect(
          result?.transaction?.merchantName,
          'Loan or EMI repayment',
          reason: body,
        );
      }
    },
  );

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
      expect(
        result?.transaction?.entryKind,
        TxnEntryKind.transfer,
        reason: body,
      );
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

  test(
    'income words inside a reversal or refund do not make it earned income',
    () {
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
        expect(
          result?.transaction?.entryKind,
          TxnEntryKind.transfer,
          reason: body,
        );
      }
    },
  );

  test(
    'investment redemption proceeds are classified as income with investments category',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'BANK',
        body:
            'Mutual fund redemption proceeds of Rs.5000 credited to your account ending 2626.',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction?.entryKind, TxnEntryKind.income);
      expect(result?.transaction?.merchantName, 'Investment return');
      expect(result?.transaction?.categoryId, 'investments');
      expect(result?.transaction?.categoryName, 'Investments');
    },
  );

  test(
    'broker settlement payout to the bank is an investment return income',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VM-DHANHQ-S',
        body:
            'Dear Sujay We have transferred Rs 93.82 to your bank account ending with XXXXXXX2626 as a part of running account settlement vide Ref No PO26101713812965. To continue trading and investing, add funds back to your Dhan account.',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction?.entryKind, TxnEntryKind.income);
      expect(result?.transaction?.merchantName, 'Investment return · Dhan');
      expect(result?.transaction?.categoryId, 'investments');
      expect(result?.transaction?.categoryName, 'Investments');
      expect(result?.transaction?.accountLast4, '2626');
    },
  );

  test('named wallet top-up still parses as a wallet load transfer', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'PAYTM',
      body:
          'Rs.5000 added to Paytm wallet from your bank account. UPI Ref 123456789012.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
    expect(result?.transaction?.merchantName, 'Wallet load');
  });

  test('broker refill instruction is an investment return and not a wallet load', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-ZERODHA',
      body:
          'Rs 2500 payout credited to your bank a/c XX9123. To continue investing, add funds back to your Zerodha account.',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction?.entryKind, TxnEntryKind.income);
    expect(result?.transaction?.merchantName, 'Investment return · Zerodha');
    expect(result?.transaction?.categoryId, 'investments');
    expect(result?.transaction?.categoryName, 'Investments');
  });

  test(
    'a debit addressed to the profile name is a self-transfer, not spending',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'HDFCBK',
        body:
            'Sent Rs.5000.00 From HDFC Bank A/C *1797 To SUJAY SHANTARAM KURTIKAR. Not you? Call 1800. Ref 12345678',
        receivedAt: DateTime(2026, 10, 18),
        ownUserName: 'Sujay Shantaram Kurtikar',
      );
      expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
      expect(
        result?.transaction?.merchantName,
        'Transfer between own accounts',
      );
    },
  );

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
      body:
          'Loan interest charge of Rs.500 debited from your account ending 2626.',
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

  test(
    'LIC adjusted installment uses the next premium month without inventing a day',
    () {
      const body =
          'Dear Customer, premium due from 04/2026 to 04/2026 under policy no. 931670879 is adjusted on 16/04/2026. Next Premium falls due on 05/2026. -LIC of India';
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VA-LICIND-S',
        body: body,
        receivedAt: DateTime(2026, 4, 17),
      );

      expect(LocalSmsParser.nextPremiumDueMonth(body), DateTime(2026, 5));
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.dueDate, isNull);
      expect(result?.disposition, LocalSmsDisposition.review);
      expect(result?.reasonCodes, contains('next_premium_due_month_only'));
      expect(result?.transaction, isNull);
    },
  );

  test(
    'LIC next premium exact date takes precedence over an older due phrase',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VA-LICIND-S',
        body:
            'Premium due for April was adjusted. Next premium falls due on 15-May-2027.',
        receivedAt: DateTime(2026, 4, 17),
      );

      expect(result?.dueDate, DateTime(2027, 5, 15));
      expect(result?.disposition, LocalSmsDisposition.localCommitment);
    },
  );

  test('dated insurance expiry becomes a renewal commitment, not noise', () {
    const body =
        'Vehicle insurance for DL01CD5678 will expire tomorrow. Premium Rs 2150.';
    final receivedAt = DateTime(2026, 10, 22, 9);
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCER-S',
      body: body,
      receivedAt: receivedAt,
    );

    expect(LocalSmsParser.isActionableInsuranceRenewal(body), isTrue);
    expect(LocalSmsParser.isNonTransactionNoise('VM-HDFCER-S', body), isFalse);
    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.disposition, LocalSmsDisposition.localCommitment);
    expect(result?.dueDate, DateTime(2026, 10, 23));
    expect(result?.billerName, 'Insurance policy');
    expect(result?.transaction, isNull);
  });

  test(
    'downloaded posted rules cannot turn merchant receipts into spending',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'APLPHR',
        body: 'Thank you for your purchase. Download your bill. Paid Rs 420.',
        receivedAt: DateTime(2026, 10, 22),
        downloadedRules: SmsRuleBundle(
          bundleVersion: 1,
          sha256: '',
          publishedAt: DateTime(2026),
          minClientVersion: '1.0.0',
          rules: [
            RestrictedSmsRule.fromJson({
              'id': 'receipt-rule',
              'family': 'posted_movement',
              'senderPattern': 'APLPHR',
              'regex': r'Paid Rs (\d+)',
              'fieldMap': {'amount': 1},
            })!,
          ],
        ),
      );
      expect(result?.transaction, isNull);
      expect(result?.reasonCodes, contains('merchant_ebill_receipt'));
    },
  );

  test(
    'month-only insurance premium bypasses neither review nor date precision',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'LICIND',
        body:
            'Life insurance premium due on 16/04/2026 was adjusted for the month of April. Next premium falls due on 05/2027.',
        receivedAt: DateTime(2026, 4, 17),
      );
      expect(result?.dueDate, isNull);
      expect(result?.disposition, LocalSmsDisposition.review);
      expect(result?.reasonCodes, contains('next_premium_due_month_only'));
    },
  );

  test('renew-today advertising does not replace a later insurance expiry', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCER',
      body: 'Renew today! Your policy expires in 10 days. Premium Rs 2150.',
      receivedAt: DateTime(2026, 10, 22),
    );
    expect(result?.dueDate, DateTime(2026, 11, 1));
  });

  test(
    'insurance expiry without the word premium still has a commitment biller',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'HDFCER',
        body: 'Your vehicle insurance expires on 25-Oct-2026.',
        receivedAt: DateTime(2026, 10, 22),
      );
      expect(result?.disposition, LocalSmsDisposition.localCommitment);
      expect(result?.billerName, 'Insurance policy');
      expect(result?.dueDate, DateTime(2026, 10, 25));
    },
  );

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
        (
          'VM-NSEIND-S',
          'NSE: Zerodha Broking reported your Fund bal Rs 5420.00 and securities bal Rs 45000.00. Balances excludes your Bank.',
        ),
        (
          'AD-BSEIND-S',
          'BSE Alert: Beware of dealing in unsolicited tips through SMS or social media. Avoid unsolicited tips.',
        ),
        (
          'VK-POLBZR-P',
          'Your car insurance policy is due for renewal. Renew now with Policybazaar for 50% discount.',
        ),
        (
          'VM-PAYTMW-P',
          'Your Paytm wallet balance is Rs 0. Add money to wallet to enjoy seamless payments.',
        ),
        ('VZ-ViCARE-S', 'Call Forwarding is now active on your mobile number.'),
        (
          'JZ-JIOPAY-S',
          'Number retention charges of Rs. 9.88 has been deducted from Top-up balance on Jio Number 8010377706 as there was no usage observed for last 90 days. Kindly recharge your Jio Number with a valid plan to avoid these charges in future. To recharge, click http://tiny.jio.com/dmyjiorchgpl',
        ),
        (
          'VD-axioPL-S',
          'Congrats Sujay, We have received your timely repayment towards your Pay Later XXX6016 a/c .You can now check your updated personal loan eligibility here https://u.axio.ac/axo/1XOUraa9OMgJw7 -axio',
        ),
        (
          'CP-AXISBK-S',
          'You have added Goa Electricity Department 60008413407 to Axis Bank Bill Pay service. We will notify you once the bill is generated.',
        ),
        (
          'VM-HDFCBK-S',
          'Transaction Check Alert! We tried to contact you to confirm txn on Card 1234',
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
    expect(result?.amountDue, isNull);
    expect(result?.dueDate, isNull);
    expect(result?.cadenceHint, isNull);
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
    expect(result?.statementDateExplicit, isFalse);
  });

  test(
    'parses Kotak statement amount and due date after earlier due amounts',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'KOTAKB',
        body:
            'Sep-2026 statement for Kotak Credit Card X1234 Total Due: INR 30.00 Min Due: INR 30.00 Due date: 23-Sep-2026. Pay at the bank app.',
        receivedAt: DateTime(2026, 9, 6),
      );
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.cardLast4, '1234');
      expect(result?.amountDue?.rupees, 30);
      expect(result?.minimumDue?.rupees, 30);
      expect(result?.dueDate, DateTime(2026, 9, 23));
    },
  );

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
    expect(result?.statementDateExplicit, isFalse);
    expect(result?.dueDate?.day, 20);
  });

  test('prefers the printed period end over the SMS receive date', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK',
      body:
          'Your statement for HDFC Bank Credit Card ending XX8708 for the period 04-Sep-2026 to 03-Oct-2026 is ready.',
      receivedAt: DateTime(2026, 10, 6),
    );
    expect(result?.statementDate, DateTime(2026, 10, 3));
    expect(result?.statementDateExplicit, isTrue);
  });

  test('does not learn the due date as the billing day', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-HDFCBK',
      body:
          'Your HDFC Bank MoneyBack+ Credit Card statement is ready. Total due Rs 900. Payment due date of your card is 16/10/2026.',
      receivedAt: DateTime(2026, 10, 8),
    );
    expect(result?.statementDate?.day, 8);
    expect(result?.dueDate?.day, 16);
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

  test('keeps MYTNEU Goa Electricity separate from credit-card bills', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'AD-MYTNEU-S',
      body:
          'Your Goa Electricity bill of Rs. 927.00 is ready. Pay by 2026-11-09 to avoid late charges: https://m.tneu.in/MYTNEU/X0jzNhN - Tata Neu',
      receivedAt: DateTime(2026, 10, 25, 8, 22),
    );

    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.billerName, 'Goa Electricity');
    expect(result?.amountDue?.rupees, 927);
    expect(result?.dueDate, DateTime(2026, 11, 9));
    expect(result?.cardLast4, isNull);
    expect(result?.reasonCodes, isNot(contains('credit_card_bill')));
  });

  test('marks suffix-less MYTNEU HDFC bill as positive card evidence', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'JK-MYTNEU-S',
      body:
          'Your HDFC Credit Card bill of Rs. 8331.00 is ready. Pay by 2026-11-08 to avoid late charges: https://m.tneu.in/MYTNEU/r0L1AAE - Tata Neu',
      receivedAt: DateTime(2026, 10, 21, 10, 1),
    );

    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.billerName, 'HDFC Credit Card');
    expect(result?.amountDue?.rupees, 8331);
    expect(result?.dueDate, DateTime(2026, 11, 8));
    expect(result?.cardLast4, isNull);
    expect(result?.reasonCodes, contains('credit_card_bill'));
  });

  test('does not parse an AutoPay bill reference as a money amount', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VD-HDFCBK-S',
      body:
          'LICNEW Bill 930688185 set for AutoPay on HDFC Bank SmartPay via Credit Card XXXXXXXXXXXX8708 is updated.',
      receivedAt: DateTime(2026, 9, 3),
    );

    expect(result?.amountDue, isNull);
    expect(result?.autopayLimit, isNull);
    expect(result?.transaction, isNull);
  });

  test(
    'classifies AutoPay alert deduction as a bill observation without creating spend',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VD-HDFCBK-S',
        body:
            'AutoPay Alert! Your HDFC Bank Credit Card 8708 bill Total Amt: Rs.10944 will be deducted from your A/C 1797 on 09/OCT/2026. Ignore if paid',
        receivedAt: DateTime(2026, 10, 7),
      );
      expect(result?.transaction, isNull);
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.cardLast4, '8708');
      expect(result?.amountDue?.rupees, 10944);
      expect(result?.dueDate, DateTime(2026, 10, 9));
      expect(result?.disposition, LocalSmsDisposition.localObservation);
      expect(result?.isAutopay, isTrue);
      expect(
        result?.reasonCodes,
        containsAll(['due_date_detected', 'autopay_notice']),
      );
      expect(result?.billerName, contains('Credit Card 8708'));
    },
  );

  test(
    'classifies AutoPay reminder deduction as a bill observation without creating spend',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VD-HDFCBN-S',
        body:
            'AutoPay Reminder: Rs.4150 will be deducted from HDFC Bank A/c 1797 on 09/JUL/2026 for Credit Card 8708 bill.',
        receivedAt: DateTime(2026, 7, 6),
      );
      expect(result?.transaction, isNull);
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.cardLast4, '8708');
      expect(result?.amountDue?.rupees, 4150);
      expect(result?.dueDate, DateTime(2026, 7, 9));
    },
  );

  test(
    'classifies credit card scheduled AutoPay notice with card ending, amount, due date and isAutopay',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-AXISBK-S',
        body:
            'AutoPay scheduled for your credit card ending in 4567 on 25-Oct-2026 for Rs 4,500.00. Maintain sufficient balance in your account.',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction, isNull);
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.cardLast4, '4567');
      expect(result?.amountDue?.rupees, 4500);
      expect(result?.dueDate, DateTime(2026, 10, 25));
      expect(result?.isAutopay, isTrue);
      expect(result?.disposition, LocalSmsDisposition.localObservation);
    },
  );

  test(
    'classifies Standing Instruction towards Credit Card with amount, card last 4, due date and isAutopay',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VD-HDFCBK-S',
        body:
            'Standing Instruction of Rs 5,000 towards HDFC Bank Credit Card ending in 5678 will be debited on 20-Oct-2026.',
        receivedAt: DateTime(2026, 10, 12),
      );
      expect(result?.transaction, isNull);
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.cardLast4, '5678');
      expect(result?.amountDue?.rupees, 5000);
      expect(result?.dueDate, DateTime(2026, 10, 20));
      expect(result?.isAutopay, isTrue);
      expect(result?.billerName, 'HDFC Bank Credit Card');
      expect(result?.disposition, LocalSmsDisposition.localObservation);
    },
  );

  test(
    'classifies Atal Pension Yojana contribution notice as a local commitment',
    () {
      const body =
          'Dear customer, your Atal Pension Yojana contribution amount for the Month April is Rs 46/-, Kindly maintain sufficient bal in your account for auto debit on 15/04/2026.';
      expect(LocalSmsParser.isAutoPayNotice(body), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise('AD-ATALPY', body), isFalse);
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-ATALPY',
        body: body,
        receivedAt: DateTime(2026, 4, 10),
      );
      expect(result?.transaction, isNull);
      expect(result?.eventType, LocalSmsEventType.bill);
      expect(result?.disposition, LocalSmsDisposition.localCommitment);
      expect(
        result?.reasonCodes,
        containsAll(['commitment_detected', 'mandate_notice']),
      );
      expect(result?.isAutopay, isTrue);
      expect(result?.billerName, 'Atal Pension Yojana');
      expect(result?.amountDue?.rupees, 46);
      expect(result?.dueDate, DateTime(2026, 4, 15));
      expect(result?.cadenceHint, 'monthly');
    },
  );

  test('classifies Broadband payment due alert as a local commitment', () {
    const body =
        'Alegra Broadband ... Payment of Rs.800/- is due on 24-10-2026.';
    expect(LocalSmsParser.isAutoPayNotice(body), isTrue);
    expect(LocalSmsParser.isNonTransactionNoise('TNBPAY', body), isFalse);
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'TNBPAY',
      body: body,
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNull);
    expect(result?.eventType, LocalSmsEventType.bill);
    expect(result?.disposition, LocalSmsDisposition.localCommitment);
    expect(
      result?.reasonCodes,
      containsAll(['commitment_detected', 'mandate_notice']),
    );
    expect(result?.isAutopay, isTrue);
    expect(result?.billerName, 'Alegra Broadband');
    expect(result?.amountDue?.rupees, 800);
    expect(result?.dueDate, DateTime(2026, 10, 24));
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
  test(
    'MobiKwik wallet debit parses as TxnInstrument.wallet and TxnEntryKind.spend',
    () {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VM-MBKWIK',
        body:
            'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
        receivedAt: DateTime(2026, 10, 18),
      );
      expect(result?.transaction, isNotNull);
      expect(result?.transaction?.instrument, TxnInstrument.wallet);
      expect(result?.transaction?.entryKind, TxnEntryKind.spend);
      expect(result?.transaction?.amount.rupees, 10.0);
      expect(result?.transaction?.accountLast4, 'MobiKwik');
      expect(result?.availableBalance?.rupees, 12.17);
    },
  );

  test('Generic wallet debit parses as wallet spend', () {
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'Paytm',
      body: 'Rs.50.0 debited from your Paytm wallet',
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.instrument, TxnInstrument.wallet);
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
    expect(result?.transaction?.amount.rupees, 50.0);
    expect(result?.transaction?.accountLast4, 'Paytm');
  });

  test('Card setting update is identified as noise and service alert', () {
    const body =
        'Modification Success! Card usage settings for Credit Card ending with XX8708 modified';
    expect(LocalSmsParser.isNonTransactionNoise('HDFCBK', body), isTrue);
    expect(NeedsReviewRepository.isSecurityOrServiceAlert(body), isTrue);
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.disposition, LocalSmsDisposition.localIgnore);
    expect(result?.transaction, isNull);
  });

  test('Delivery memo alert is identified as non-transaction noise', () {
    const body =
        'Bharatgas cylinder is out for delivery with Cash Memo Amount Rs 926.5. Pls share Delivery Code 734900';
    expect(LocalSmsParser.isNonTransactionNoise('BP-BHARAT', body), isTrue);
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'BP-BHARAT',
      body: body,
      receivedAt: DateTime(2026, 10, 18),
    );
    expect(result?.disposition, LocalSmsDisposition.localIgnore);
    expect(result?.transaction, isNull);
  });

  test('Union Bank of India SMS parses payee from Fvg clause', () {
    const body =
        'Union Bank of India A/c *8565 Debited Rs:2900.00 on 21-10-2026 19:28:42 by Mob Bk ref no 629453274545, Fvg: gaudeshi Avl Bal Rs:594.92. Not you?Call 18002333/SMS BLOCK 8565 to 8879365472';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-UBIN',
      body: body,
      receivedAt: DateTime(2026, 10, 21),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.amount.rupees, 2900.0);
    expect(result?.transaction?.merchantName, 'gaudeshi');
    expect(result?.transaction?.accountLast4, '8565');
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
    expect(result?.availableBalance?.rupees, 594.92);
  });

  test('completed bank debit without a payee still counts as spending', () {
    const body =
        'A/c *8565 Debited for Rs:3000.00 on 14-08-2025 21:18:19 by Mob Bk ref no 559227806547 Avl Bal Rs:4583.22. If not you, Call 1800222243 -Union Bank of India';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'JX-UNIONB-S',
      body: body,
      receivedAt: DateTime(2025, 8, 14, 21, 18),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.amount.rupees, 3000.0);
    expect(result?.transaction?.merchantName, 'Bank debit');
    expect(result?.transaction?.accountLast4, '8565');
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('Slice credit card transaction parses correctly', () {
    const body =
        'Rs. 859 spent on your credit card xx9080 at slice on 22-Oct-26 (UPI Ref: 629534133759). Not you? Call 080-4832-9999 - slice';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'AD-SLICE',
      body: body,
      receivedAt: DateTime(2026, 10, 22),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.cardLast4, '9080');
    expect(result?.transaction?.amount.rupees, 859.0);
    expect(result?.transaction?.merchantName, 'slice');
    expect(result?.transaction?.instrument, TxnInstrument.creditCard);
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('Co-operative bank debit parses account and payee', () {
    const body =
        'Dear Customer, A/c *1234 is debited for Rs. 1500.00 on 20-10-2026 by UPI/629453274545/TeaStall. Avl Bal Rs. 8500.00. - Goa Urban Co-op Bank';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'JX-GUCBNK-S',
      body: body,
      receivedAt: DateTime(2026, 10, 20),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.amount.rupees, 1500.0);
    expect(result?.transaction?.accountLast4, '1234');
    expect(result?.transaction?.merchantName, 'TeaStall');
    expect(result?.transaction?.instrument, TxnInstrument.upiBank);
    expect(result?.transaction?.entryKind, TxnEntryKind.spend);
  });

  test('ASBA / IPO application block is classified as investment lien', () {
    const body =
        'Dear Customer, your request for ASBA application no. 1789027578CB90FY for RENTOMOJO LIMITED of Rs. 2,09,272.00 has been accepted successfully on 10/09/2026. - Kotak Bank';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'Kotak Bank',
      body: body,
      receivedAt: DateTime(2026, 9, 10),
    );
    expect(result?.transaction, isNotNull);
    expect(result?.transaction?.amount.rupees, 209272.0);
    expect(result?.transaction?.entryKind, TxnEntryKind.investment);
  });

  test(
    'extractReceiptAmount sanitizes order ID and AWB sequences before extraction',
    () {
      expect(
        LocalSmsParser.extractReceiptAmount(
          'Order ID: 987654321 for Rs. 450.00 confirmed',
        )?.rupees,
        450.0,
      );
      expect(
        LocalSmsParser.extractReceiptAmount(
          'Order No. 123456 total Rs 1,299 paid',
        )?.rupees,
        1299.0,
      );
      expect(
        LocalSmsParser.extractReceiptAmount(
          'AWB 8876543210 shipment fee INR 250.50',
        )?.rupees,
        250.5,
      );
      expect(
        LocalSmsParser.extractReceiptAmount(
          'order number #54321 Rs. 99',
        )?.rupees,
        99.0,
      );
    },
  );

  test('new noise patterns are identified as non-transaction noise', () {
    final noiseAlerts = <(String sender, String body)>[
      ('CDSLIN', 'CDSL: Unpledge confirmed for 100 shares in demat account.'),
      ('NSDLIN', 'NSDL: Pledge setup request initiated for a/c 1234.'),
      (
        'KFINTECH',
        'Updated your address under folio 98765432 based on feed received from KRA.',
      ),
      (
        'CAMS',
        'Address in folio 12345/6 is updated based on feed received from KRA.',
      ),
      (
        'HDFCBK',
        'Due to scheduled maintenance NetBanking services will be unavailable from 02:00 to 05:00.',
      ),
      (
        'ICICIB',
        'Registration alert: device name iPhone 15 was registered on iMobile Pay.',
      ),
      (
        'AMAZON',
        'Reminder: 5 cashback coupons expire at midnight. Use code FESTIVE.',
      ),
      (
        'DELHIV',
        'Order is dispatched through Delhivery with tracking 123456789.',
      ),
      (
        'BLUEDART',
        'Your order is dispatched through Blue Dart express logistics.',
      ),
      (
        'FLIPKT',
        'We have received your order ID OD123456789. We are preparing it for shipment.',
      ),
      (
        'AXISBK',
        'Lifetime-free credit card facility has been enabled for your account. Limit Rs. 2,00,000.',
      ),
      (
        'BAJAJA',
        'Two wheeler insurance for MH01AB1234 has expired. Renew today at Rs. 1499.',
      ),
      (
        'ACKOIN',
        'Car insurance expired! Renew before midnight to protect your NCB.',
      ),
      (
        'JIOFBR',
        'Help us serve you better. Rate your experience with JioFiber.',
      ),
      (
        'VICARE',
        'Your experience matters to us. Take a quick survey and share your feedback.',
      ),
    ];

    for (final (sender, body) in noiseAlerts) {
      expect(
        LocalSmsParser.isNonTransactionNoise(sender, body),
        isTrue,
        reason: 'Expected noise for: ' + body,
      );
    }
  });
  test(
    'feedback text after a completed recharge does not hide the transaction',
    () {
      const body =
          'Recharge of Rs 239 successful. Rate your experience with Jio.';
      expect(LocalSmsParser.isNonTransactionNoise('JIOFBR', body), isFalse);
    },
  );
  test('mutual fund folio unit allotment does not create a cash spend transaction', () {
    const amcMessages = [
      'Folio 1235/67: Purchase of Rs 5000 in HDFC Top 100 Fund processed. 54.321 units allotted at NAV 92.0450 on 05-Oct-2026.',
      'Dear Investor, 45.123 units allotted under Folio 9876543/21 in Nippon India Small Cap Fund - Reg (G) for your investment of Rs 5,000 at NAV 110.8123 on 05-Oct-2026.',
      'Units: 25.432, NAV: 196.50 allotted for your investment of Rs. 5000 in Parag Parikh Flexi Cap Fund, Folio: 123456789.',
      'Units allotted under folio 11223344 for Rs 10000 in ICICI Prudential Bluechip Fund. NAV: 85.25.',
    ];

    for (final body in amcMessages) {
      expect(LocalSmsParser.isInvestmentFolioAllotment(body), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise('HDFCMF', body), isFalse);

      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'HDFCMF',
        body: body,
        receivedAt: DateTime(2026, 10, 5, 14, 30),
      );

      expect(obs, isNotNull);
      expect(
        obs!.transaction?.entryKind,
        TxnEntryKind.investment,
        reason: 'Must mint an investment transaction, never cash spend!',
      );
      expect(obs.transaction?.entryKind == TxnEntryKind.spend, isFalse);
      expect(obs.eventType, LocalSmsEventType.investment);
      expect(obs.reasonCodes, contains('mf_folio_unit_allotment'));
      expect(obs.amount, isNotNull);
      expect(obs.amount!.paise, greaterThan(0));
      expect(obs.amountDue, obs.amount);
      expect(obs.merchantName, isNotNull);
    }
  });

  test('mutual fund SIP allotment with under scheme pattern extracts cleanly', () {
    const body = 'Units allotted under HDFC Gold ETF Fund of Fund-DP Growth for Rs. 100.00 in Folio 1235/67. NAV: 24.50 on 24-Oct-2026.';
    expect(LocalSmsParser.isInvestmentFolioAllotment(body), isTrue);
    expect(LocalSmsParser.isNonTransactionNoise('HDFCMF', body), isFalse);

    final obs = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCMF',
      body: body,
      receivedAt: DateTime(2026, 10, 24, 11, 0),
    );

    expect(obs, isNotNull);
    expect(obs!.transaction?.entryKind, TxnEntryKind.investment);
    expect(obs.transaction?.entryKind == TxnEntryKind.spend, isFalse);
    expect(obs.transaction?.amount.rupees, 100.0);
    expect(obs.transaction?.merchantName, 'HDFC Gold ETF Fund of Fund-DP Growth');
    expect(obs.eventType, LocalSmsEventType.investment);
    expect(obs.disposition, LocalSmsDisposition.sync);
    expect(obs.merchantName, contains('HDFC Gold ETF Fund of Fund'));
    expect(obs.amount, Money.fromRupees(100.00));
    expect(obs.accountLast4, '5/67');
  });

  test('SEBI quarterly settlement with amount transferred is not noise', () {
    const body = 'As per SEBI regulations, unused funds of Rs. 15,400.00 have been transferred to your bank account A/C **1234 towards quarterly settlement.';
    expect(LocalSmsParser.isNonTransactionNoise('VK-ZERODHA', body), isFalse);

    final obs = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-ZERODHA',
      body: body,
      receivedAt: DateTime(2026, 10, 24),
    );
    expect(obs?.transaction, isNotNull);
    expect(obs?.transaction?.entryKind, TxnEntryKind.income);
    expect(obs?.transaction?.merchantName, 'Investment return · Zerodha');
  });

  test('SEBI settlement advisory without amount or future tense is noise', () {
    const advisory1 = 'As per SEBI guidelines, quarterly settlement of accounts will be processed today. Unused funds will be transferred to your bank account.';
    expect(LocalSmsParser.isNonTransactionNoise('VK-ZERODHA', advisory1), isTrue);

    const advisory2 = 'As per SEBI regulations, quarterly settlement is scheduled for Friday. Please ensure your bank details are updated.';
    expect(LocalSmsParser.isNonTransactionNoise('VK-ZERODHA', advisory2), isTrue);
  });
  test('bank account balance and account discovery extracts balance and accounts', () {
    // 1. Canara Bank interest credit 1
    final canara1 = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-CANBNK',
      body:
          'INR 25.00 credited to A/c XXXX1772 on 28/09/2026 towards Interest. Total Avail. Bal. INR 4,304.19. -Canara Bank',
      receivedAt: DateTime(2026, 9, 28),
    );
    expect(canara1?.accountLast4, '1772');
    expect(canara1?.availableBalance, Money.fromRupees(4304.19));
    expect(
      LocalSmsParser.isBankAccountMessage(
        'INR 25.00 credited to A/c XXXX1772 on 28/09/2026 towards Interest. Total Avail. Bal. INR 4,304.19. -Canara Bank',
        'VK-CANBNK',
      ),
      isTrue,
    );

    // 2. Canara Bank interest credit 2
    final canara2 = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-CANBNK',
      body:
          'INR 1,103.00 credited to A/c XXXX2226 on 28/09/2026 towards Interest. Total Avail. Bal. INR 1,83,459.65. -Canara Bank',
      receivedAt: DateTime(2026, 9, 28),
    );
    expect(canara2?.accountLast4, '2226');
    expect(canara2?.availableBalance, Money.fromRupees(183459.65));
    expect(
      LocalSmsParser.isBankAccountMessage(
        'INR 1,103.00 credited to A/c XXXX2226 on 28/09/2026 towards Interest. Total Avail. Bal. INR 1,83,459.65. -Canara Bank',
        'VK-CANBNK',
      ),
      isTrue,
    );

    // 3. Canara Bank ATM withdrawal
    final canaraAtm = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-CANBNK',
      body:
          'A/C XXXX1772 linked to card XXXX5667 debited Rs INR 20,000.00 on 31/03/2026 Seq 3906 ATM txn.Avl Bal is Rs INR 30,188.05.',
      receivedAt: DateTime(2026, 3, 31),
    );
    expect(canaraAtm?.accountLast4, '1772');
    expect(canaraAtm?.cardLast4, '5667');
    expect(canaraAtm?.availableBalance, Money.fromRupees(30188.05));
    expect(
      LocalSmsParser.isBankAccountMessage(
        'A/C XXXX1772 linked to card XXXX5667 debited Rs INR 20,000.00 on 31/03/2026 Seq 3906 ATM txn.Avl Bal is Rs INR 30,188.05.',
        'VK-CANBNK',
      ),
      isTrue,
    );

    // 4. Union Bank debit
    final union = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VK-UNIONB',
      body:
          'An amount of INR 500.00 debited from a/c ...8565. Avl Bal Rs: 594.92',
      receivedAt: DateTime(2026, 10, 1),
    );
    expect(union?.accountLast4, '8565');
    expect(union?.availableBalance, Money.fromRupees(594.92));
    expect(
      LocalSmsParser.isBankAccountMessage(
        'An amount of INR 500.00 debited from a/c ...8565. Avl Bal Rs: 594.92',
        'VK-UNIONB',
      ),
      isTrue,
    );

    for (final (sender, body) in [
      (
        'VM-axioFN',
        'Hi Sujay, Your Pay Later a/c XXX6016 has got you personal loan upto Rs 4,00,000 with instant credit.',
      ),
      (
        'VD-axioLN',
        'Reminder Sujay, by continuing timely EMI payments against your Pay Later a/c XXX6016, you are building a credit score.',
      ),
      (
        'VD-axioLN',
        'We have received your timely repayment towards your Pay Later XXX6016 a/c.',
      ),
    ]) {
      expect(
        LocalSmsParser.isBankAccountMessage(body, sender),
        isFalse,
        reason: '$sender must remain a lending liability, not a bank account',
      );
    }
  });

  test('Axio Amazon Pay Later credit drawdown parses as spend transaction', () {
    const messages = [
      (
        'AX-axioFS-S',
        'Thank you for availing Pay Later credit of Rs299.0. For more info click https://u.axio.ac/axo/UqpJfCtWpqntk To report misuse call 180012001637 -axio',
        299.0,
      ),
      (
        'VM-axioFS-S',
        'Thank you for availing Pay Later credit of Rs859.0. For more info click https://u.axio.ac/axo/OIzBfFTIVHRH30R To report misuse call 180012001637 -axio',
        859.0,
      ),
    ];

    for (final (sender, body, amount) in messages) {
      final result = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 24, 15, 30),
      );

      expect(result, isNotNull);
      expect(result!.eventType, LocalSmsEventType.transaction);
      expect(result.disposition, LocalSmsDisposition.sync);
      expect(result.reasonCodes, contains('axio_pay_later_drawdown'));
      final txn = result.transaction;
      expect(txn, isNotNull);
      expect(txn!.amount, Money.fromRupees(amount));
      expect(txn.merchantName, 'Amazon Pay Later');
      expect(txn.instrument, TxnInstrument.other);
      expect(txn.accountLast4, 'Amazon Pay Later');
      expect(txn.entryKind, TxnEntryKind.spend);
    }
  });
  test('Axio Pay Later bill becomes an upcoming bill, not an account', () {
    const body =
        'Your Pay Later bill of Rs 1038 will be debited on 5th of this month '
        'from registered bank a/c. View Bill https://u.axio.co/axo/example -axio';
    final result = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'VM-axioFS',
      body: body,
      receivedAt: DateTime(2026, 5, 1, 9, 30),
    );

    expect(result, isNotNull);
    expect(result!.eventType, LocalSmsEventType.bill);
    expect(result.disposition, LocalSmsDisposition.localCommitment);
    expect(result.merchantName, 'Axio Pay Later');
    expect(result.amountDue, Money.fromRupees(1038));
    expect(result.dueDate, DateTime(2026, 5, 5));
    expect(result.transaction, isNull);
    expect(LocalSmsParser.isBankAccountMessage(body, 'VM-axioFS'), isFalse);
  });

  test('auto-categorizes Indian corporate merchant entities with FlashText', () {
    // Bundl Technologies -> Swiggy / Dining
    final swiggy = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs 349.00 spent on HDFC Bank Card ending 1234 at BUNDL TECHNOLOGIES on 20-Oct-26.',
      receivedAt: DateTime(2026, 10, 20),
    );
    expect(swiggy?.transaction?.categoryName, 'Dining');
    expect(swiggy?.transaction?.categoryId, 'dining');

    // Eternal Limited -> Zomato / Dining
    final zomato = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'ICICIB',
      body: 'Dear Customer, your Ac XX5678 is debited for INR 450.00 on 21-Oct-26 by UPI: ETERNAL LIMITED. UPI Ref 123456.',
      receivedAt: DateTime(2026, 10, 21),
    );
    expect(zomato?.transaction?.categoryName, 'Dining');
    expect(zomato?.transaction?.categoryId, 'dining');

    // Blink Commerce -> Blinkit / Groceries
    final blinkit = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'AXISBK',
      body: 'INR 620.00 spent on your Axis Bank Card 4321 at BLINK COMMERCE on 22-Oct-26.',
      receivedAt: DateTime(2026, 10, 22),
    );
    expect(blinkit?.transaction?.categoryName, 'Groceries');
    expect(blinkit?.transaction?.categoryId, 'groceries');

    // Kiranakart -> Zepto / Groceries
    final zepto = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'SBINB',
      body: 'Your A/c 9988 debited by Rs 280.00 on 23-Oct-26 at KIRANAKART. Bal: Rs 15000.',
      receivedAt: DateTime(2026, 10, 23),
    );
    expect(zepto?.transaction?.categoryName, 'Groceries');
    expect(zepto?.transaction?.categoryId, 'groceries');

    // Avenue Supermarts -> DMart / Groceries
    final dmart = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'KOTAKB',
      body: 'Sent Rs.1450.00 from Kotak Bank AC 1122 to AVENUE SUPERMARTS on 24-Oct-26.',
      receivedAt: DateTime(2026, 10, 24),
    );
    expect(dmart?.transaction?.categoryName, 'Groceries');
    expect(dmart?.transaction?.categoryId, 'groceries');

    // ANI Technologies -> Ola / Travel
    final ola = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs 199.00 debited from A/c XX1234 on 25-Oct-26 to ANI TECHNOLOGIES.',
      receivedAt: DateTime(2026, 10, 25),
    );
    expect(ola?.transaction?.categoryName, 'Travel');
    expect(ola?.transaction?.categoryId, 'travel');
  });

  test('pre-filters order delivery updates and talktime notices as non-transaction noise', () {
    const swiggyDelivery = 'Your Swiggy order of Rs 450 is out for delivery with our delivery partner. Enjoy your meal!';
    expect(LocalSmsParser.isNonTransactionNoise('SWIGGY', swiggyDelivery), isTrue);
    expect(LocalSmsParser.isCompletedTransactionOrBill(swiggyDelivery), isFalse);

    const zeptoDelivery = 'Your Zepto order of Rs 299 is arriving in 7 mins! Track here: https://zepto.app/t/123';
    expect(LocalSmsParser.isNonTransactionNoise('ZEPTO', zeptoDelivery), isTrue);

    const talktimeAlert = 'Your talktime balance is Rs 5.50. Recharge now to stay connected: https://airtel.in/r';
    expect(LocalSmsParser.isNonTransactionNoise('AIRTEL', talktimeAlert), isTrue);
  });

  group('telecom carrier noise detection (4 agreed scenarios)', () {
    test('Scenario 1: SIM retention charge & top-up balance deduction with unmasked 10-digit number is noise', () {
      const s1Jio = 'Number retention charges of Rs. 9.88 has been deducted from Top-up balance on Jio Number 8010377706 as there was no usage observed for last 90 days. Kindly recharge your Jio Number with a valid plan to avoid these charges in future.';
      expect(LocalSmsParser.isNonTransactionNoise('JZ-JIOPAY-S', s1Jio), isTrue);

      const s1Airtel = 'Rs 20 deducted from top-up balance for number retention charges on 9876543210. Recharge your airtel number to avoid these charges.';
      expect(LocalSmsParser.isNonTransactionNoise('AIRTEL', s1Airtel), isTrue);

      const s1Vi = 'Rs 10 debited from main bal on Vi number 9876543210 as no usage observed for 60 days. Recharge with validity pack now.';
      expect(LocalSmsParser.isNonTransactionNoise('VI-CARE', s1Vi), isTrue);
    });

    test('Scenario 2: telecom recharge upsell / reminder with unmasked 10-digit number without bank debit is noise', () {
      const s2Jio = 'Recharge your Jio number 9876543210 with Rs 299 pack to enjoy unlimited calls and 1.5GB/day data. Recharge now!';
      expect(LocalSmsParser.isNonTransactionNoise('AD-JIO', s2Jio), isTrue);

      const s2Airtel = 'Validity for your Airtel prepaid number 9876543210 is expiring soon. Recharge now with top-up or unlimited pack.';
      expect(LocalSmsParser.isNonTransactionNoise('AIRTEL', s2Airtel), isTrue);

      const s2Vi = 'Recharge now! Get extra talktime on Rs 100 top-up on your Vi mobile 9876543210.';
      expect(LocalSmsParser.isNonTransactionNoise('VI', s2Vi), isTrue);
    });

    test('Scenario 3: bank debit for telecom recharge with masked bank/card account MUST NOT be noise', () {
      const s3Hdfc = 'A/c XX1234 debited Rs 299 for Jio recharge on 8010377706';
      expect(LocalSmsParser.isNonTransactionNoise('HDFCBK', s3Hdfc), isFalse);

      const s3Axis = 'Your A/c ending 5678 is debited for INR 199.00 on 25-Oct-26 towards Airtel recharge of 9876543210.';
      expect(LocalSmsParser.isNonTransactionNoise('AXISBK', s3Axis), isFalse);

      const s3Icici = 'Card XX9012 debited by Rs 499 for Vi prepaid recharge of 9123456780.';
      expect(LocalSmsParser.isNonTransactionNoise('ICICIB', s3Icici), isFalse);
    });

    test('Scenario 4: postpaid telecom bill with amount due / due date / bill generated MUST NOT be noise', () {
      const s4Airtel = 'Your Airtel postpaid bill for 9876543210 has been generated. Amount due: Rs 499, Due date: 15-Nov-2026.';
      expect(LocalSmsParser.isNonTransactionNoise('AIRTEL', s4Airtel), isFalse);

      const s4Jio = 'Bill for your Jio number 9876543210 is ready. Total amount due is Rs 799 payable by 20-Nov-2026.';
      expect(LocalSmsParser.isNonTransactionNoise('JIO', s4Jio), isFalse);

      const s4Vi = 'Dear Customer, Vi postpaid bill generated for 9876543210. Bill amount: Rs 399. Payment due date: 10-Nov-2026.';
      expect(LocalSmsParser.isNonTransactionNoise('VI-CARE', s4Vi), isFalse);
    });
  });

  group('betting/gambling spam and no-amount loan limit marketing', () {
    const loanLimitSpam =
        'New Credit alert\nYour loan limit is revised. Click here to know more: 1kx.in/khOzn2\nBajaj Markets\nT&C';
    const bettingSpam =
        'FRPendingDTIL IPL trusted betting site GullyBET, Instant withdrawal. Fancy bet All games, casino, slots, aviator, cockfight. Huge bonus gbets.win/1w1';

    test('VK-BFDLPS-S loan limit alert is noise and not captured as financial', () {
      expect(
        LocalSmsParser.isNonTransactionNoise('VK-BFDLPS-S', loanLimitSpam),
        isTrue,
      );
      expect(
        capturesFinancialSms(loanLimitSpam, sender: 'VK-BFDLPS-S'),
        isFalse,
      );
    });

    test('CP-DISHTV-S betting spam is noise and not captured as financial', () {
      expect(
        LocalSmsParser.isNonTransactionNoise('CP-DISHTV-S', bettingSpam),
        isTrue,
      );
      expect(
        capturesFinancialSms(bettingSpam, sender: 'CP-DISHTV-S'),
        isFalse,
      );
    });

    test('Counter-tests: Real ATM withdrawal and credit are captured and not noise', () {
      const realAtm = 'Cash withdrawal of Rs. 2,000 from A/c XX1234';
      const realCredit = 'Rs. 5,000 credited to A/c XX1234';

      expect(LocalSmsParser.isNonTransactionNoise('HDFCBK', realAtm), isFalse);
      expect(capturesFinancialSms(realAtm, sender: 'HDFCBK'), isTrue);

      expect(LocalSmsParser.isNonTransactionNoise('HDFCBK', realCredit), isFalse);
      expect(capturesFinancialSms(realCredit, sender: 'HDFCBK'), isTrue);
    });
  });

  group('UPI narration payees', () {
    const axisP2m = 'INR 12.00 debited\n'
        'A/c no. XX2583\n'
        '21-10-26, 22:41:20\n'
        'UPI/P2M/**** 6977/MANYAM VISWANADA RE\n'
        'Not you? SMS BLOCKUPI Cust ID to **** 0002\n'
        'Axis Bank';

    test('P2M merchant follows a masked reference and stops at the footer', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-AXISBK-S',
        body: axisP2m,
        receivedAt: DateTime(2026, 10, 21, 22, 41, 20),
      );

      final txn = parsed?.transaction;
      expect(txn, isNotNull);
      expect(txn!.amount.paise, 1200);
      expect(txn.merchantName, 'MANYAM VISWANADA RE');
      expect(txn.accountLast4, '2583');
      expect(txn.entryKind, TxnEntryKind.spend);
      expect(txn.instrument, TxnInstrument.upiBank);
      expect(txn.occurredAt.year, 2026);
      expect(txn.occurredAt.month, 10);
      expect(txn.occurredAt.day, 21);
    });

    test('P2A narration keeps the person name without the trailing bank', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-AXISBK-S',
        body: 'INR 500.00 debited\nA/c no. XX2583\n20-10-26, 10:00:00\n'
            'UPI/P2A/123456789012/SUNALI MUNDRA/YESB\n'
            'Not you? SMS BLOCKUPI Cust ID to **** 0002',
        receivedAt: DateTime(2026, 10, 20, 10),
      );

      expect(parsed?.transaction?.merchantName, 'SUNALI MUNDRA');
      expect(parsed?.transaction?.amount.paise, 50000);
    });

    test('Unicode-masked P2A reference keeps the actual recipient', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-AXISBK-S',
        body: 'INR 9000.00 debited\nA/c no. XX2583\n'
            '04-10-26, 21:49:33\nUPI/P2A/•••• 2120/AANCHAL YADU\n'
            'Not you? SMS BLOCKUPI Cust ID to •••• 0002\nAxis Bank',
        receivedAt: DateTime(2026, 10, 4, 21, 49, 36),
      );
      expect(parsed?.transaction?.merchantName, 'AANCHAL YADU');
      expect(parsed?.transaction?.entryKind, TxnEntryKind.spend);
    });

    test('processed ICICI card bill is a named transfer', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VM-SBYONO-S',
        body: 'ICICI Credit card bill - of Rs.94567.00 has been '
            'successfully processed from SBI A/C-0208. Your B-connect '
            'Txn id is xxxxKvEe -YONO SBI',
        receivedAt: DateTime(2026, 10, 22, 22, 7, 7),
      );
      expect(parsed?.transaction?.merchantName, 'ICICI credit card bill');
      expect(parsed?.transaction?.entryKind, TxnEntryKind.transfer);
    });

    test('P2M without a payee token leaves no fabricated merchant', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-AXISBK-S',
        body: 'INR 12.00 debited\nA/c no. XX2583\n21-10-26, 22:41:20\n'
            'UPI/P2M/**** 6977\nNot you? SMS BLOCKUPI Cust ID to **** 0002',
        receivedAt: DateTime(2026, 10, 21, 22, 41, 20),
      );

      expect(parsed?.transaction?.amount.paise, 1200);
      expect(
        MerchantIdentity.isWeakName(parsed?.transaction?.merchantName),
        isTrue,
        reason: 'a routing-only narration must not become a merchant',
      );
    });

    test('"debited towards X for INR" names X, not the opaqueness behind it', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-AXISBK-S',
        body: 'Your A/c has been debited towards Google Play for INR 4999.00 '
            'on 10-10-26. '
            '9901e1edad8e46cd937da209ef0baf55@axl - Axis Bank',
        receivedAt: DateTime(2026, 10, 10, 5, 30),
      );

      final txn = parsed?.transaction;
      expect(txn, isNotNull);
      expect(txn!.amount.paise, 499900);
      expect(txn.merchantName, 'Google Play');
      expect(txn.occurredAt.year, 2026);
      expect(txn.occurredAt.month, 10);
      expect(txn.occurredAt.day, 10);
    });

    test('an opaque VPA hash never becomes the merchant', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AD-AXISBK-S',
        body: 'Your A/c has been debited towards INR 4999.00 on 10-10-26. '
            '9901e1edad8e46cd937da209ef0baf55@axl - Axis Bank',
        receivedAt: DateTime(2026, 10, 10, 5, 30),
      );

      final name = parsed?.transaction?.merchantName;
      expect(
        MerchantIdentity.isWeakName(name),
        isTrue,
        reason: 'without a readable payee the row must stay unlabelled, '
            'never carry a hash VPA (got "$name")',
      );
    });

    test('parses Axis Bank UPI ASPRESENTED mandate SMS with date range and amount limit', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'VM-AXISBK-S',
        body: 'Your UPI ASPRESENTED mandate has been successfully created towards Google Asia Pacific Pte.Ltd '
            'from 10-07-26 to 31-12-36 for INR 4000.00 Axis Bank. UMRN is axisf00000000000001',
        receivedAt: DateTime(2026, 7, 10, 11, 30),
      );

      expect(parsed, isNotNull);
      expect(parsed!.isAutopay, isTrue);
      expect(parsed.billerName, contains('Google Asia Pacific'));
      expect(parsed.autopayLimit?.paise, 400000);
      expect(parsed.amountDue, isNull);
      expect(parsed.cadenceHint, 'asPresented');
      expect(parsed.startDate, DateTime(2026, 7, 10));
      expect(parsed.endDate, DateTime(2036, 12, 31));
      expect(parsed.paymentMethod, 'UPI AutoPay (Axis Bank)');
    });

    test('parses Axis Bank Groww AutoPay mandate SMS', () {
      final parsed = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'AX-AXISBK-S',
        body:
            'For the upcoming mandate set for 03-09-26, INR 3000.00 will be debited from your A/c towards ICCL GROWW AUTOPAY for UPI Mandate, •••• 5173. To stop execution, pause mandate - Axis Bank',
        receivedAt: DateTime(2026, 9, 1, 6, 50, 23),
      );

      final draft = LocalSmsParser.reviewDraft(
        namespace: 'user:test',
        sender: 'AX-AXISBK-S',
        body:
            'For the upcoming mandate set for 03-09-26, INR 3000.00 will be debited from your A/c towards ICCL GROWW AUTOPAY for UPI Mandate, •••• 5173. To stop execution, pause mandate - Axis Bank',
        receivedAt: DateTime(2026, 9, 1, 6, 50, 23),
      );
      expect(parsed?.isAutopay, isTrue);
      expect(parsed?.eventType, LocalSmsEventType.investment);
      expect(parsed?.disposition, LocalSmsDisposition.localCommitment);
      expect(parsed?.billerName, 'Groww');
      expect(parsed?.transaction, isNull);
      expect(parsed?.amountDue?.rupees, 3000);
      expect(parsed?.dueDate, DateTime(2026, 9, 3));
      expect(draft.merchantName, isNull);
    });
  });
}
