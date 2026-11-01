import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';

LocalSmsObservation? _parse(String sender, String body) => LocalSmsParser.parse(
  namespace: 'test',
  sender: sender,
  body: body,
  receivedAt: DateTime(2026, 10, 15, 10),
);

TxnEntryKind? _kind(String sender, String body) =>
    _parse(sender, body)?.transaction?.entryKind;

void main() {
  group('income without the word "salary"', () {
    test('NEFT credit from a company is income', () {
      expect(
        _kind(
          'HDFCBK',
          'Rs. 85,000.00 credited to a/c XX1234 on 01-10-26 by NEFT-ACMETECH '
              'SOLUTIONS PVT LTD-N274120001. Avl bal Rs 1,20,000.00',
        ),
        TxnEntryKind.income,
      );
    });

    test('IMPS credit with a bonus/stipend/incentive word is income', () {
      for (final w in ['STIPEND', 'BONUS', 'INCENTIVE']) {
        expect(
          _kind(
            'AXISBK',
            'INR 12000.00 credited to your A/c no. XX5678 on 01-10-2026 by '
                'IMPS/ACME/$w. Avl Bal INR 5,000.00',
          ),
          TxnEntryKind.income,
          reason: w,
        );
      }
    });

    test('lender, fund house and gateway credits are not income', () {
      for (final payer in [
        'NEFT-BAJAJ FINANCE LIMITED-LOAN123',
        'NEFT-HDFC MUTUAL FUND LTD-RED445',
        'NEFT-RAZORPAY SOFTWARE PVT LTD-SETTLE',
        'NEFT-ACME INSURANCE CO LTD-CLAIM99',
      ]) {
        expect(
          _kind(
            'HDFCBK',
            'Rs. 50,000.00 credited to a/c XX1234 on 01-10-26 by $payer. '
                'Avl bal Rs 1,20,000.00',
          ),
          isNot(TxnEntryKind.income),
          reason: payer,
        );
      }
    });
  });

  group('status notices that move no money are ignored, not reviewed', () {
    test('merchant refund progress notices', () {
      for (final body in [
        'Your refund of Rs. 349 for order #1234567 has been processed and will '
            'reflect in your account in 3-5 business days.',
        'Refund of Rs.349 for your Zomato order has been initiated to your '
            'original payment source. It will be credited in 5-7 working days.',
      ]) {
        final obs = _parse('ZOMATO', body);
        expect(obs?.transaction, isNull);
        expect(obs?.disposition, LocalSmsDisposition.localIgnore, reason: body);
      }
    });

    test('the bank credit for that refund still counts', () {
      final obs = _parse(
        'HDFCBK',
        'Rs. 349.00 credited to a/c XX1234 on 14-10-26 by UPI/ZOMATO/refund. '
            'Avl bal Rs 10,000.00',
      );
      expect(obs?.transaction?.amount.paise, 34900);
      expect(obs?.transaction?.merchantName, 'Refund');
    });

    test('EPFO passbook and claim notices', () {
      for (final body in [
        'Dear Member, your PF contribution of Rs 3,600 for 09/2026 has been '
            'credited to UAN 1012345678 passbook.',
        'EPFO: Your claim ID PYKD2012345678 has been settled. Rs 45,000 will '
            'be credited to your bank a/c XX1234.',
      ]) {
        final obs = _parse('EPFOHO', body);
        expect(obs?.transaction, isNull);
        expect(obs?.disposition, LocalSmsDisposition.localIgnore, reason: body);
      }
    });

    test('a bank credit from EPFO is still money in', () {
      final obs = _parse(
        'HDFCBK',
        'Rs. 45,000.00 credited to a/c XX1234 on 20-10-26 by NEFT-EPFO PF '
            'SETTLEMENT. Avl bal Rs 60,000.00',
      );
      expect(obs?.transaction?.amount.paise, 4500000);
    });
  });
}
