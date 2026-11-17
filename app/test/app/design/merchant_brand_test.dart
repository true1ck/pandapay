import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/merchant_brand.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Crunchyroll and other well-known brands get their logo', () {
    const cases = {
      // The subscription descriptor the bank sends, with the country joined on.
      'CrunchyrollIndia': MerchantBrand.crunchyroll,
      'CRUNCHYROLL': MerchantBrand.crunchyroll,
      'Crunchyroll LLC': MerchantBrand.crunchyroll,
      'Discord Nitro': MerchantBrand.discord,
      'MICROSOFT 365 SUBSCRIPTION': MerchantBrand.microsoft,
      'Microsoft Xbox': MerchantBrand.xbox,
      'Xbox Game Pass': MerchantBrand.xbox,
      'PlayStation Network': MerchantBrand.playstation,
      'LinkedIn Premium': MerchantBrand.linkedin,
      'Google Cloud': MerchantBrand.googleCloud,
      'Google One': MerchantBrand.google,
      'Amazon Music': MerchantBrand.amazonMusic,
      'Amazon': MerchantBrand.amazon,
      'NordVPN': MerchantBrand.nordVpn,
      'Maruti Suzuki India': MerchantBrand.suzuki,
      'Hyundai Motor India': MerchantBrand.hyundai,
      'Nike India': MerchantBrand.nike,
      'ZARA INDIA': MerchantBrand.zara,
      'Booking.com': MerchantBrand.bookingCom,
      'Burger King India': MerchantBrand.burgerKing,
      'IKEA India': MerchantBrand.ikea,
      'OnePlus Technology India': MerchantBrand.oneplus,
    };
    for (final entry in cases.entries) {
      expect(MerchantBrand.forName(entry.key), entry.value, reason: entry.key);
    }
  });

  test('a small shop that shares a famous name does not get the logo', () {
    for (final name in [
      'Maruti Traders',
      'MARUTI KIRANA',
      'Zara Gents Parlour',
      'Mahindra Hardware',
    ]) {
      expect(MerchantBrand.forName(name), isNull, reason: name);
    }
  });

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
