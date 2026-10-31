import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/merchant_identity.dart';

void main() {
  group('MerchantIdentity.cleanName', () {
    test('removes recorded/received sentence tails from receipt payees', () {
      expect(
        MerchantIdentity.cleanName('Balaji Sports has been recorded'),
        equals('Balaji Sports'),
      );
      expect(
        MerchantIdentity.cleanName('Sharma Kirana Store was credited'),
        equals('Sharma Kirana Store'),
      );
      expect(
        MerchantIdentity.cleanName('Chai Point has been successfully paid'),
        equals('Chai Point'),
      );
    });

    test('removes reference metadata without eating the name', () {
      expect(
        MerchantIdentity.cleanName('Sunali Mundra Refno 665663775318'),
        equals('Sunali Mundra'),
      );
      expect(
        MerchantIdentity.cleanName('Balaji Sports Ref No 445566'),
        equals('Balaji Sports'),
      );
      expect(
        MerchantIdentity.cleanName('Apollo Pharmacy Order id 99881'),
        equals('Apollo Pharmacy'),
      );
    });

    test('preserves location-bearing names, punctuation and short brands', () {
      expect(
        MerchantIdentity.cleanName('Delhi Public School'),
        equals('Delhi Public School'),
      );
      expect(
        MerchantIdentity.cleanName('Café Coffee Day, Connaught Place'),
        equals('Café Coffee Day, Connaught Place'),
      );
      expect(MerchantIdentity.cleanName('3M'), equals('3M'));
      expect(MerchantIdentity.cleanName('7 Eleven'), equals('7 Eleven'));
      expect(MerchantIdentity.cleanName('Taste of Mumbai'), 'Taste of Mumbai');
      expect(MerchantIdentity.cleanName('STUDIO54STORE'), 'STUDIO54STORE');
    });

    test('preserves unicode payee names', () {
      expect(MerchantIdentity.cleanName('सुशील कुमार'), equals('सुशील कुमार'));
      expect(MerchantIdentity.cleanName('Café Nero'), equals('Café Nero'));
    });

    test('rejects ids, hashes, URLs and boilerplate', () {
      expect(MerchantIdentity.cleanName(null), isNull);
      expect(MerchantIdentity.cleanName('   '), isNull);
      expect(MerchantIdentity.cleanName('665663775318'), isNull);
      expect(MerchantIdentity.cleanName('A1B2C3D4E5F6'), isNull);
      expect(
        MerchantIdentity.cleanName('https://mybillbook.in/cpp/?t=ljbffep4r'),
        isNull,
      );
      expect(
        MerchantIdentity.cleanName('View the payment receipt here'),
        isNull,
      );
      expect(MerchantIdentity.cleanName('Thank you for your purchase'), isNull);
      expect(MerchantIdentity.cleanName('the upcoming mandate'), isNull);
      expect(MerchantIdentity.cleanName('other services-18001234-SBI'), isNull);
      expect(MerchantIdentity.cleanName('MID12345678'), isNull);
    });

    test('opaque QR VPAs never invent a brand', () {
      expect(MerchantIdentity.cleanName('paytmqr63650y@ptys'), isNull);
      expect(MerchantIdentity.cleanName('bharatpe99128@icici'), isNull);
    });

    test('case and internal spacing are preserved', () {
      expect(
        MerchantIdentity.cleanName('  Balaji   Sports  '),
        equals('Balaji Sports'),
      );
      expect(MerchantIdentity.cleanName('BALAJI SPORTS'), equals('BALAJI SPORTS'));
    });
  });

  group('MerchantIdentity.isWeakName', () {
    test('flags blank, generic labels and rejected shapes', () {
      expect(MerchantIdentity.isWeakName(null), isTrue);
      expect(MerchantIdentity.isWeakName('  '), isTrue);
      expect(MerchantIdentity.isWeakName('Unknown merchant'), isTrue);
      expect(MerchantIdentity.isWeakName('Bank debit'), isTrue);
      expect(MerchantIdentity.isWeakName('Purchase'), isTrue);
      expect(MerchantIdentity.isWeakName('Paytm QR'), isTrue);
      expect(MerchantIdentity.isWeakName('BharatPe QR'), isTrue);
      expect(MerchantIdentity.isWeakName('123456789012'), isTrue);
      expect(
        MerchantIdentity.isWeakName('https://mybillbook.in/cpp/?t=x'),
        isTrue,
      );
    });

    test('accepts real people and businesses, including numeric brands', () {
      expect(MerchantIdentity.isWeakName('Balaji Sports'), isFalse);
      expect(MerchantIdentity.isWeakName('Sunali Mundra'), isFalse);
      expect(MerchantIdentity.isWeakName('Delhi Public School'), isFalse);
      expect(MerchantIdentity.isWeakName('3M'), isFalse);
      expect(MerchantIdentity.isWeakName('7 Eleven'), isFalse);
      expect(MerchantIdentity.isWeakName('सुशील कुमार'), isFalse);
    });
  });

  group('MerchantIdentity.transferPayee', () {
    test('reads the payee out of the stored transfer form', () {
      expect(
        MerchantIdentity.transferPayee('Transfer to Sunali Mundra'),
        equals('Sunali Mundra'),
      );
    });

    test('tolerates the casing and spacing a merchant name can arrive with', () {
      expect(MerchantIdentity.transferPayee('TRANSFER TO Zephr'), equals('Zephr'));
      expect(MerchantIdentity.transferPayee('Transfer to  Zephr'), equals('Zephr'));
      expect(MerchantIdentity.transferPayee(' transfer to Zephr '), equals('Zephr'));
    });

    test('returns null rather than a blank or absent payee', () {
      expect(MerchantIdentity.transferPayee('Transfer to'), isNull);
      expect(MerchantIdentity.transferPayee('Transfer to '), isNull);
      expect(MerchantIdentity.transferPayee('BOMBAY BAZAAR'), isNull);
      expect(MerchantIdentity.transferPayee(null), isNull);
    });

    test('payeeDisplayName falls back to the name it was given', () {
      expect(
        MerchantIdentity.payeeDisplayName('Transfer to Zephr'),
        equals('Zephr'),
      );
      expect(MerchantIdentity.payeeDisplayName('Transfer to'), equals('Transfer to'));
      expect(MerchantIdentity.payeeDisplayName('BOMBAY BAZAAR'), equals('BOMBAY BAZAAR'));
      expect(MerchantIdentity.payeeDisplayName(null), isNull);
    });
  });
}
