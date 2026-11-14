import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/merchant_brand.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'catalogue and published business aliases resolve to the correct marks',
    () {
      const cases = {
        'InterGlobe Aviation': MerchantBrand.indigo,
        'IRCTC.CO.IN': MerchantBrand.irctc,
        'Domino’s Pizza': MerchantBrand.dominos,
        'Tata SIA Airlines': MerchantBrand.vistara,
        'JioCinema': MerchantBrand.jioHotstar,
        'Tata1mg': MerchantBrand.tata1Mg,
        'Bangalore Electricity Supply Company': MerchantBrand.bescom,
        'Flipkart Health+': MerchantBrand.flipkart,
        'Coursera': MerchantBrand.coursera,
        'DevYani International': null,
        'croma@paytm': null,
      };
      for (final entry in cases.entries) {
        expect(
          MerchantBrand.forName(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test('recognizes brand names inside bank descriptions and clipped names', () {
    const cases = {
      'AMAZON WEBSERVI': MerchantBrand.aws,
      'POS*AMAZON RETAIL 123': MerchantBrand.amazon,
      'AMAZONPRIME MONTHLY': MerchantBrand.primeVideo,
      'YOUTUBE CYBS': MerchantBrand.youtube,
      'CARD*YOUTUBECYBS': MerchantBrand.youtube,
      'JIOHOME': MerchantBrand.jio,
      'JIO MART MUMBAI': MerchantBrand.jiomart,
      'JIOHOTSTAR AUTOPAY': MerchantBrand.jioHotstar,
      'ZOMATO MONEY': MerchantBrand.zomato,
      'AIRTEL RECHARGE': MerchantBrand.airtel,
      'SPACESHIP': MerchantBrand.spaceship,
      'PYU*FLIPKAR MUMBAI': MerchantBrand.flipkart,
      'IndiGo Travel Services': MerchantBrand.indigo,
      'AVIGHNA ENTERPRISE': null,
      'Unknown merchant': null,
      'chocolate store': null,
      'swig': null,
    };
    for (final entry in cases.entries) {
      expect(MerchantBrand.forName(entry.key), entry.value, reason: entry.key);
    }
  });

  test('every registered brand has a decodable local asset', () async {
    for (final brand in MerchantBrand.values) {
      final bytes = await rootBundle.load(brand.asset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
    }
  });
}
