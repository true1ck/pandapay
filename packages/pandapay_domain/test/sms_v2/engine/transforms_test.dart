import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

void main() {
  group('parseAmountIndian', () {
    const table = <String, int?>{
      'Rs.1,23,456.78': 12345678,
      'INR 85,000.00': 8500000,
      '₹ 499': 49900,
      'Rs 14250': 1425000,
      'Rs.5,000.00/-': 500000,
      '1,48,701.00': 14870100,
      'Rs.499.5': 49950,
      'rs.0.50': 50,
      'INR 10.': 1000,
      'Rs.1.005': null,
      'abc': null,
      '': null,
      'Rs. ': null,
    };
    table.forEach((input, want) {
      test('"$input" -> $want', () => expect(parseAmountIndian(input), want));
    });
  });

  group('parseDate (IST in, UTC out)', () {
    DateTime u(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) => DateTime.utc(y, mo, d, h, mi, s);
    final ist = const Duration(hours: 5, minutes: 30);
    final table = <(String, String, DateTime?)>[
      ('01-11-26', 'dd-MM-yy', u(2026, 11, 1).subtract(ist)),
      ('01-11-2026', 'dd-MM-yyyy', u(2026, 11, 1).subtract(ist)),
      ('01/11/26', 'dd/MM/yy', u(2026, 11, 1).subtract(ist)),
      ('01Nov26', 'ddMMMyy', u(2026, 11, 1).subtract(ist)),
      ('01-Nov-26', 'dd-MMM-yy', u(2026, 11, 1).subtract(ist)),
      ('01 Nov 2026', 'dd MMM yyyy', u(2026, 11, 1).subtract(ist)),
      ('2026-11-01:12:30:11', 'yyyy-MM-dd:HH:mm:ss', u(2026, 11, 1, 12, 30, 11).subtract(ist)),
      // optional time
      ('01-11-26 14:05:09', 'dd-MM-yy', u(2026, 11, 1, 14, 5, 9).subtract(ist)),
      ('01-11-26 14:05', 'dd-MM-yy', u(2026, 11, 1, 14, 5).subtract(ist)),
      ('01Nov26 09:00:00', 'ddMMMyy', u(2026, 11, 1, 9).subtract(ist)),
      ('01 Nov 2026 23:59:59', 'dd MMM yyyy', u(2026, 11, 1, 23, 59, 59).subtract(ist)),
      ('2026-11-01', 'yyyy-MM-dd:HH:mm:ss', u(2026, 11, 1).subtract(ist)),
      // invalid
      ('31-02-26', 'dd-MM-yy', null),
      ('01-13-26', 'dd-MM-yy', null),
      ('01Xyz26', 'ddMMMyy', null),
      ('nonsense', 'dd-MM-yy', null),
    ];
    for (final (text, fmt, want) in table) {
      test('"$text" as $fmt', () => expect(parseDate(text, [fmt]), want));
    }
    test('tries each format in order', () {
      expect(parseDate('01Nov26', ['dd-MM-yy', 'ddMMMyy']), isNotNull);
    });
    test('IST midnight is the previous day 18:30 UTC', () {
      expect(parseDate('01-11-26', ['dd-MM-yy']), DateTime.utc(2026, 10, 31, 18, 30));
    });
  });

  group('small transforms', () {
    test('digitsOnly', () {
      expect(digitsOnly('XX 12-34'), '1234');
      expect(digitsOnly('abc'), '');
    });
    test('upperTrim', () => expect(upperTrim('  swiggy   instamart '), 'SWIGGY INSTAMART'));
    test('vpaFromText', () {
      expect(vpaFromText('paid to Foo.Bar@OKAXIS via UPI'), 'foo.bar@okaxis');
      expect(vpaFromText('no id here'), isNull);
    });
    test('stripTrailingRefs', () {
      expect(stripTrailingRefs('SWIGGY Ref 4123456789'), 'SWIGGY');
      expect(stripTrailingRefs('ZOMATO 123456789012'), 'ZOMATO');
      expect(stripTrailingRefs('UTR: AXIS12345678'), '');
      expect(stripTrailingRefs('AMAZON PAY'), 'AMAZON PAY');
      expect(stripTrailingRefs('ROOM 12'), 'ROOM 12');
    });
  });

  group('sanitizeNarration (port of IndianNarrationSanitizer)', () {
    const table = <String, String>{
      '': '',
      'RAZORPAY*SWIGGY': 'SWIGGY',
      'POS 412345*MCDONALDS': 'MCDONALDS',
      'UPI/P2M/3294829384/AMAZON SELLER/BARB0': 'AMAZON SELLER',
      'UPI/P2P/4293849283/SURESH KUMAR/OKAXIS': 'SURESH KUMAR',
      'paytmqr63650y@ptys': 'Paytm QR',
      'bharatpe09ab@yesbank': 'BharatPe QR',
      'Fvg: gaudeshi': 'gaudeshi',
      'ACME FOODS PVT LTD': 'ACME FOODS',
      'BIG BAZAAR MUMBAI IN': 'BIG BAZAAR',
      'Delhi Public School': 'Delhi Public School',
      'CAFE TID:AB1234': 'CAFE',
      'A': 'A',
    };
    table.forEach((input, want) {
      test('"$input"', () => expect(sanitizeNarration(input), want));
    });
  });

  group('normalizeSenderBrand', () {
    final senders = [
      SenderEntry(brand: 'HDFCBK', issuerSlug: 'hdfc', issuerKind: IssuerKind.bank, aliases: ['HDFCCC']),
    ];
    test('prefix and suffix', () {
      expect(normalizeSenderBrand('VM-HDFCBK-S').brand, 'HDFCBK');
      expect(normalizeSenderBrand('ad-sbiupi-t').brand, 'SBIUPI');
      expect(normalizeSenderBrand('JD-AXISBK-G').brand, 'AXISBK');
      expect(normalizeSenderBrand('HDFCBK').brand, 'HDFCBK');
    });
    test('iOS filter tag is removed first and kept', () {
      final n = normalizeSenderBrand('VM-HDFCBK-S (smsft_fi)');
      expect(n.brand, 'HDFCBK');
      expect(n.iosFilter, 'smsft_fi');
      expect(normalizeSenderBrand('AX-ICICIB (smsfp)').iosFilter, 'smsfp');
      expect(normalizeSenderBrand('AX-ICICIB').iosFilter, isNull);
    });
    test('aliases resolve through bundle senders', () {
      expect(normalizeSenderBrand('VM-HDFCCC-S', senders).brand, 'HDFCBK');
      expect(normalizeSenderBrand('VM-OTHER-S', senders).brand, 'OTHER');
    });
  });
}
