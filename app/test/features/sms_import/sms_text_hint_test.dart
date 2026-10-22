import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  group('extractLast4Hint', () {
    test('extracts a single "ending NNNN" style last-4', () {
      expect(
        extractLast4Hint(
          'Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL.',
        ),
        '4321',
      );
    });

    test('extracts "XXNNNN" style last-4', () {
      expect(
        extractLast4Hint('INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.'),
        '7788',
      );
    });

    test(
      'returns null when multiple distinct 4-digit candidates appear (ambiguous)',
      () {
        expect(
          extractLast4Hint(
            'Card ending 1111 used. Ref no 2222. Card ending 3333 also used.',
          ),
          null,
        );
      },
    );

    test('returns null when there is no last-4 mention at all', () {
      expect(
        extractLast4Hint('Your OTP is 8123. Do not share it with anyone.'),
        null,
      );
    });

    test('is case-insensitive on the "ending"/"card"/"xx" keyword', () {
      expect(extractLast4Hint('card ENDING 5678 spent'), '5678');
    });

    // Task S-1a (D3): the backup importer groups messages by this hint to
    // decide which card each belongs to, so a shape it can't read costs a
    // whole card's worth of correct attribution. These are the shapes real
    // Indian issuer templates actually use.
    test('extracts the "Card x1234" shape', () {
      expect(
        extractLast4Hint(
          'Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24',
        ),
        '1234',
      );
    });

    test('extracts an asterisk-masked suffix', () {
      expect(
        extractLast4Hint('INR 899 debited from card ****4455 at BIGBASKET'),
        '4455',
      );
    });

    test('extracts an ellipsis-masked account suffix', () {
      expect(
        extractLast4Hint('Your a/c ...9012 has been debited by Rs.200'),
        '9012',
      );
    });

    // A bare 4-digit number with no masking prefix is not a candidate at
    // all, so this stays unambiguous — which is the desired behaviour: the
    // message says which number is the card, and refusing to read it would
    // lose a correct attribution for no safety gain.
    test('ignores a bare 4-digit OTP sitting next to a masked card suffix', () {
      expect(
        extractLast4Hint('Card x1234 used. OTP for this txn is 5678.'),
        '1234',
      );
    });

    test('still refuses to guess between two masked suffixes', () {
      expect(
        extractLast4Hint('Card x1234 and card x5678 were both used.'),
        null,
      );
    });
  });

  group('looksLikeTransactionSms', () {
    test('true for a "spent" style bank alert', () {
      expect(
        looksLikeTransactionSms('Rs.500 spent on your card at STORE'),
        true,
      );
    });

    test('true for a "debited" style bank alert', () {
      expect(
        looksLikeTransactionSms('Your account has been debited with INR 500'),
        true,
      );
    });

    test('true for a statement-only due-date alert', () {
      expect(
        looksLikeTransactionSms(
          'Your statement for Axis Bank Credit Card no. XX7105 is generated. '
          'Due on: 02-11-26 Total amt: INR Dr. 2147.00 Min amt due: INR Dr. 100.00',
        ),
        true,
      );
    });

    test('true for a due alert without a currency keyword', () {
      expect(
        looksLikeTransactionSms(
          'Your bill is payable by 02/11/2026 for card ending 7105.',
        ),
        true,
      );
    });

    test('true for an issuer funds-ready reminder used to learn a due day', () {
      expect(
        looksLikeTransactionSms(
          'HDFC Bank Credit Card ending XX1234. Please keep sufficient funds '
          'in your account for payment on 16/10/2026.',
        ),
        true,
      );
    });

    test('false for an unrelated promotional message', () {
      expect(
        looksLikeTransactionSms('Flat 50% off on your next order! Shop now.'),
        false,
      );
    });

    test('false for an OTP message', () {
      expect(
        looksLikeTransactionSms('8123 is your OTP. Valid for 10 minutes.'),
        false,
      );
    });

    test(
      'false for an OTP that also mentions a transaction, amount, and card suffix',
      () {
        expect(
          looksLikeTransactionSms(
            'OTP is 643697 for txn of INR 889.46 at TATAPAYMENT on HDFC Bank card ending 1366. Valid till 07:25. Do not share OTP.',
          ),
          false,
        );
      },
    );

    test('false for a declined card transaction', () {
      expect(
        looksLikeTransactionSms(
          'TXN DECLINED: Rs.400.00 on HDFC Bank Debit Card xx8406.',
        ),
        false,
      );
    });

    test('forwards reversals for parser classification', () {
      expect(
        looksLikeTransactionSms(
          'Transaction Reversed on HDFC Bank Credit Card xx8708 Amt Rs.103.49.',
        ),
        true,
      );
    });
  });

  group('capturesFinancialSms promotional filtering', () {
    test('keeps a completed debit with a promotional footer', () {
      expect(
        capturesFinancialSms(
          'Your card XX1234 was debited Rs.500 at STORE. '
          'Get 5% cashback on your next purchase.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test('keeps a bill reminder with an offer footer', () {
      expect(
        capturesFinancialSms(
          'Your credit card bill of Rs.5000 is due on 25 Oct. '
          'Get cashback when you pay.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test('filters a spend threshold cashback promotion', () {
      expect(
        capturesFinancialSms(
          'Spend INR 15000 on your card and get cashback of INR 250. '
          'Offer valid this month.',
          sender: 'VM-BANK-P',
        ),
        isFalse,
      );
    });

    test('filters an EMI solicitation quoting historic spend', () {
      expect(
        capturesFinancialSms(
          'Your combined spends of Rs.40016 are eligible for conversion '
          'to Flexipay EMIs. Click link.',
          sender: 'BP-SBICRD-S',
        ),
        isFalse,
      );
    });

    test('filters OTPs even when they contain transaction wording', () {
      expect(
        capturesFinancialSms(
          'OTP 123456 to confirm your transaction of INR 500. Do not share.',
          sender: 'VM-BANK-S',
        ),
        isFalse,
      );
    });

    test('keeps a completed card purchase from a promotional sender', () {
      expect(
        capturesFinancialSms(
          'Your transaction of INR 1,250.00 on card XX4321 at STORE is successful. '
          'Get 10% cashback on your next purchase.',
          sender: 'VM-BANK-P',
        ),
        isTrue,
      );
    });

    test('filters an offer with a quoted price and a spend threshold', () {
      expect(
        capturesFinancialSms(
          'Shop now: buy a phone for Rs.19999. Spend INR 5000 and earn '
          'cashback. Offer valid until 30 Nov.',
          sender: 'VM-BRAND-P',
        ),
        isFalse,
      );
    });

    test('filters a card offer that says no annual fee will be charged', () {
      expect(
        capturesFinancialSms(
          'Apply now for our card. No annual fee will be charged. '
          'Get exclusive offers and cashback on shopping.',
          sender: 'VM-BANK-P',
        ),
        isFalse,
      );
    });

    test(
      'filters an offer that mentions card transactions but no completed event',
      () {
        expect(
          capturesFinancialSms(
            'Use your HDFC Bank card for purchases this weekend and get 5% off. '
            'Shop now; offer valid at participating stores.',
            sender: 'VM-HDFCBK-P',
          ),
          isFalse,
        );
      },
    );

    test('keeps a balance snapshot with a promotional footer', () {
      expect(
        capturesFinancialSms(
          'Available balance in account XX1234 is INR 8,450.25 as of 22 Oct. '
          'Apply now for a personal loan.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test('keeps a bill due notice with an offer footer', () {
      expect(
        capturesFinancialSms(
          'Your statement is generated. Total amount due INR 4,200 by 5 Nov. '
          'Get cashback when you pay.',
          sender: 'VM-BANK-P',
        ),
        isTrue,
      );
    });

    test('keeps a refund actually credited despite an offer footer', () {
      expect(
        capturesFinancialSms(
          'Refund of INR 799 has been credited to your account. '
          'Enjoy exclusive offers with our card.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test('keeps an AutoPay mandate notice for lifecycle classification', () {
      expect(
        capturesFinancialSms(
          'Your AutoPay mandate for INR 999 is scheduled for 25 Oct.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test('keeps a declined payment as a reviewable financial attempt', () {
      expect(
        capturesFinancialSms(
          'Your card payment of Rs.500 was declined. No amount has been debited.',
          sender: 'VM-BANK-S',
        ),
        isTrue,
      );
    });

    test(
      'filters security and verification messages containing a money amount',
      () {
        expect(
          capturesFinancialSms(
            'Security code 123456 for payment of INR 500. Never share this code.',
            sender: 'VM-BANK-S',
          ),
          isFalse,
        );
      },
    );

    test('filters a non-financial service notice with account wording', () {
      expect(
        capturesFinancialSms(
          'Alert: call forwarding is active on your mobile number. Dial ##002# to deactivate.',
          sender: 'VM-TELECOM-S',
        ),
        isFalse,
      );
    });

    test('filters unrelated, empty, and whitespace-only messages', () {
      expect(
        capturesFinancialSms('Your parcel will arrive tomorrow.'),
        isFalse,
      );
      expect(capturesFinancialSms(''), isFalse);
      expect(capturesFinancialSms('   \n\t  '), isFalse);
    });
  });

  group('classifySmsTriage', () {
    test('classifies OTP/security as sensitive', () {
      final res = classifySmsTriage('VM-BANK', '8123 is your OTP. Do not share.');
      expect(res.kind, SmsTriageKind.sensitive);
      expect(res.reasonCode, 'security_message');
    });

    test('classifies completed movement as financialCandidate', () {
      final res = classifySmsTriage('VM-HDFCBK', 'Rs.500 debited from a/c XX1234 at SWIGGY. Get 10% off next order');
      expect(res.kind, SmsTriageKind.financialCandidate);
      expect(res.reasonCode, 'financial_evidence');
    });

    test('classifies statement/bill as financialCandidate', () {
      final res = classifySmsTriage('VM-AXISBK', 'Statement generated for Card XX1234. Total amount due Rs. 5000 by 15-Nov.');
      expect(res.kind, SmsTriageKind.financialCandidate);
      expect(res.reasonCode, 'financial_evidence');
    });

    test('classifies AutoPay mandate as financialCandidate', () {
      final res = classifySmsTriage('VM-ICICIB', 'Your AutoPay mandate of Rs. 999 is scheduled.');
      expect(res.kind, SmsTriageKind.financialCandidate);
      expect(res.reasonCode, 'mandate_lifecycle');
    });

    test('classifies declined payment attempt as financialCandidate', () {
      final res = classifySmsTriage('VM-HDFCBK', 'Your txn of Rs. 400 on card xx1234 was declined.');
      expect(res.kind, SmsTriageKind.financialCandidate);
      expect(res.reasonCode, 'failed_attempt');
    });

    test('classifies promo message as promotion', () {
      final res = classifySmsTriage('VM-HDFCBK-P', 'Apply now for pre-approved personal loan up to 5 Lakhs!');
      expect(res.kind, SmsTriageKind.promotion);
    });

    test('classifies empty or random text as unrelated', () {
      final res1 = classifySmsTriage('VM-OTHER', '');
      expect(res1.kind, SmsTriageKind.unrelated);
      expect(res1.reasonCode, 'empty_body');

      final res2 = classifySmsTriage('VM-OTHER', 'Good morning, have a nice day!');
      expect(res2.kind, SmsTriageKind.unrelated);
      expect(res2.reasonCode, 'no_financial_signal');
    });
  });

}
