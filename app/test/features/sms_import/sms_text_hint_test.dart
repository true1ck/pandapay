import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  group('extractLast4Hint', () {
    test('extracts a single "ending NNNN" style last-4', () {
      expect(
        extractLast4Hint('Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL.'),
        '4321',
      );
    });

    test('extracts "XXNNNN" style last-4', () {
      expect(extractLast4Hint('INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.'), '7788');
    });

    test('returns null when multiple distinct 4-digit candidates appear (ambiguous)', () {
      expect(
        extractLast4Hint('Card ending 1111 used. Ref no 2222. Card ending 3333 also used.'),
        null,
      );
    });

    test('returns null when there is no last-4 mention at all', () {
      expect(extractLast4Hint('Your OTP is 8123. Do not share it with anyone.'), null);
    });

    test('is case-insensitive on the "ending"/"card"/"xx" keyword', () {
      expect(extractLast4Hint('card ENDING 5678 spent'), '5678');
    });
  });

  group('looksLikeTransactionSms', () {
    test('true for a "spent" style bank alert', () {
      expect(looksLikeTransactionSms('Rs.500 spent on your card at STORE'), true);
    });

    test('true for a "debited" style bank alert', () {
      expect(looksLikeTransactionSms('Your account has been debited with INR 500'), true);
    });

    test('false for an unrelated promotional message', () {
      expect(looksLikeTransactionSms('Flat 50% off on your next order! Shop now.'), false);
    });

    test('false for an OTP message', () {
      expect(looksLikeTransactionSms('8123 is your OTP. Valid for 10 minutes.'), false);
    });
  });
}
