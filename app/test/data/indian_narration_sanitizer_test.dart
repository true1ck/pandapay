import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/indian_narration_sanitizer.dart';
import 'package:pandapay/data/flashtext_merchant_extractor.dart';

void main() {
  group('IndianNarrationSanitizer', () {
    test('normalizes UPI QR VPA handles to canonical QR merchants', () {
      expect(
        IndianNarrationSanitizer.sanitize('paytmqr63650y@ptys'),
        equals('Paytm QR'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('bharatpe99128@icici'),
        equals('BharatPe QR'),
      );
    });

    test('strips payment gateway aggregator prefixes', () {
      expect(IndianNarrationSanitizer.sanitize('RAZORPAY*SWIGGY'), equals('SWIGGY'));
      expect(IndianNarrationSanitizer.sanitize('PAYTM*ZEPTO'), equals('ZEPTO'));
      expect(IndianNarrationSanitizer.sanitize('CASHFREE*CRED'), equals('CRED'));
      expect(IndianNarrationSanitizer.sanitize('BILLDESK*AIRTEL'), equals('AIRTEL'));
      expect(IndianNarrationSanitizer.sanitize('PINELABS*STARBUCKS'), equals('STARBUCKS'));
      expect(IndianNarrationSanitizer.sanitize('CCAVENUE*BOOKMYSHOW'), equals('BOOKMYSHOW'));
    });

    test('extracts clean merchant from NPCI UPI transaction strings', () {
      expect(
        IndianNarrationSanitizer.sanitize('UPI/P2M/3294829384/AMAZON SELLER/BARB0123/Pay'),
        equals('AMAZON SELLER'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('UPI/P2P/4293849283/SURESH KUMAR/OKAXIS/Payment'),
        equals('SURESH KUMAR'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('UPI/REV/123456789/SWIGGY/HDFCBK/Refund'),
        equals('SWIGGY'),
      );
    });

    test('strips POS and card channel prefixes with location noise', () {
      expect(
        IndianNarrationSanitizer.sanitize('POS 412345*MCDONALDS BANGALORE IND'),
        equals('MCDONALDS'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('ECOM 9988*NETFLIX MUMBAI'),
        equals('NETFLIX'),
      );
    });

    test('strips corporate legal entity markers', () {
      expect(
        IndianNarrationSanitizer.sanitize('BUNDL TECHNOLOGIES PVT LTD'),
        equals('BUNDL TECHNOLOGIES'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('ONE97 COMMUNICATIONS LIMITED'),
        equals('ONE97 COMMUNICATIONS'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('RELIANCE RETAIL LTD'),
        equals('RELIANCE RETAIL'),
      );
    });

    test('strips terminal IDs and numeric noise', () {
      expect(
        IndianNarrationSanitizer.sanitize('STARBUCKS TID987654 BANGALORE'),
        equals('STARBUCKS'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('SHELL PETROL PUMP MID12345678 PUNE'),
        equals('SHELL PETROL PUMP'),
      );
    });

    test('handles empty or blank strings safely', () {
      expect(IndianNarrationSanitizer.sanitize(''), equals(''));
      expect(IndianNarrationSanitizer.sanitize('   '), equals(''));
    });

    test('keeps a city that is part of the business name', () {
      expect(
        IndianNarrationSanitizer.sanitize('Delhi Public School'),
        equals('Delhi Public School'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('MUMBAI DABBAWALA'),
        equals('MUMBAI DABBAWALA'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('NEW DELHI SWEETS'),
        equals('NEW DELHI SWEETS'),
      );
    });

    test('still drops a trailing terminal location run', () {
      expect(
        IndianNarrationSanitizer.sanitize('AMAZON SELLER BANGALORE IND'),
        equals('AMAZON SELLER'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('SUNALI MUNDRA PUNE'),
        equals('SUNALI MUNDRA'),
      );
    });

    test('keeps reference ids out of the payee name', () {
      expect(
        IndianNarrationSanitizer.sanitize('SUNALI MUNDRA REF 665663775318'),
        equals('SUNALI MUNDRA'),
      );
      expect(
        IndianNarrationSanitizer.sanitize('UPI/P2M/3294829384/AMAZON SELLER/BARB0123/Pay'),
        equals('AMAZON SELLER'),
      );
    });
  });

  group('FlashTextMerchantExtractor', () {
    final extractor = FlashTextMerchantExtractor.defaultExtractor;

    test('extracts canonical name and category for direct merchant names', () {
      final res = extractor.extractFirst('Paid Rs 450 at Swiggy on your card');
      expect(res, isNotNull);
      expect(res!.canonicalName, equals('Swiggy'));
      expect(res.category, equals('dining'));
    });

    test('resolves corporate entity aliases to canonical consumer brands', () {
      final swiggyRes = extractor.extractFirst('Payment to BUNDL TECHNOLOGIES successful');
      expect(swiggyRes, isNotNull);
      expect(swiggyRes!.canonicalName, equals('Swiggy'));
      expect(swiggyRes.category, equals('dining'));

      final olaRes = extractor.extractFirst('Txn at ANI TECHNOLOGIES for ride');
      expect(olaRes, isNotNull);
      expect(olaRes!.canonicalName, equals('Ola'));
      expect(olaRes.category, equals('travel'));

      final paytmRes = extractor.extractFirst('Debited for ONE97 COMMUNICATIONS');
      expect(paytmRes, isNotNull);
      expect(paytmRes!.canonicalName, equals('Paytm'));
      expect(paytmRes.category, equals('wallet'));
    });

    test('prefers longest match over short prefix', () {
      final instamartRes = extractor.extractFirst('Purchase at SWIGGY INSTAMART');
      expect(instamartRes, isNotNull);
      expect(instamartRes!.canonicalName, equals('Swiggy Instamart'));
      expect(instamartRes.category, equals('groceries'));
    });

    test('respects strict word boundaries and rejects substring false positives', () {
      // "tuberculosis" contains "uber", but should NOT match
      final fakeUber = extractor.extractFirst('Patient treated for tuberculosis in hospital');
      expect(fakeUber, isNull);

      // "php" contains "hp", but should NOT match Hindustan Petroleum
      final fakeHp = extractor.extractFirst('Developed script in php backend');
      expect(fakeHp, isNull);
    });

    test('end-to-end synergy: sanitizer + flashtext extractor', () {
      final raw = 'UPI/P2M/8972349823/BUNDL TECHNOLOGIES PVT LTD/YESB0001/Payment';
      final sanitized = IndianNarrationSanitizer.sanitize(raw);
      expect(sanitized, equals('BUNDL TECHNOLOGIES'));

      final extracted = extractor.extractFirst(sanitized);
      expect(extracted, isNotNull);
      expect(extracted!.canonicalName, equals('Swiggy'));
      expect(extracted.category, equals('dining'));
    });
  });
}
