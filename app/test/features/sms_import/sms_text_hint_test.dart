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

    // Task S-1a (D3): the backup importer groups messages by this hint to
    // decide which card each belongs to, so a shape it can't read costs a
    // whole card's worth of correct attribution. These are the shapes real
    // Indian issuer templates actually use.
    test('extracts the "Card x1234" shape', () {
      expect(
        extractLast4Hint('Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24'),
        '1234',
      );
    });

    test('extracts an asterisk-masked suffix', () {
      expect(extractLast4Hint('INR 899 debited from card ****4455 at BIGBASKET'), '4455');
    });

    test('extracts an ellipsis-masked account suffix', () {
      expect(extractLast4Hint('Your a/c ...9012 has been debited by Rs.200'), '9012');
    });

    // A bare 4-digit number with no masking prefix is not a candidate at
    // all, so this stays unambiguous — which is the desired behaviour: the
    // message says which number is the card, and refusing to read it would
    // lose a correct attribution for no safety gain.
    test('ignores a bare 4-digit OTP sitting next to a masked card suffix', () {
      expect(extractLast4Hint('Card x1234 used. OTP for this txn is 5678.'), '1234');
    });

    test('still refuses to guess between two masked suffixes', () {
      expect(extractLast4Hint('Card x1234 and card x5678 were both used.'), null);
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
