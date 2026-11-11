// Merchants the category rules missed because of HOW a bank or acquirer prints
// them, not because the brand was unknown: names glued together, cut short by a
// bank, in the plural, or a type of business without a brand. Every name below is
// either a public brand or invented; no person's payments are used.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:test/test.dart';

const _rulesDir = '../../rules/sms/v2';

void main() {
  final rules = [
    for (final j in jsonDecode(File('$_rulesDir/category_rules.json').readAsStringSync()) as List)
      CategoryRule.fromJson((j as Map).cast<String, Object?>()),
  ];
  final aliases = [
    for (final j in jsonDecode(File('$_rulesDir/merchant_aliases.json').readAsStringSync()) as List)
      MerchantAlias.fromJson((j as Map).cast<String, Object?>()),
  ];
  final resolver = DefaultCategoryResolver(aliases: aliases);

  CategoryInput input(String name, {CounterpartyKind kind = CounterpartyKind.merchant}) => CategoryInput(
    counterparty: Counterparty(name: name, kind: kind),
    senderBrand: 'HDFCBK',
    bundleRules: rules,
  );

  String purchase(String name) => resolver.resolve(input(name)).slug;

  /// A UPI payment to a merchant: the bank cannot say business or person, so
  /// only a payee whose WHOLE name is a known business gets a category.
  String upi(String name) =>
      resolver.decide(eventType: EventType.p2pOut, input: input(name, kind: CounterpartyKind.unknown))!.slug;

  group('a card purchase, as an acquirer prints the merchant', () {
    test('a brand glued to a branch or a word is still the brand', () {
      const cases = {
        'DOMINOSPIZZA': 'dining',
        'PIZZAHUTKORAMANGALA': 'dining',
        'BURGERKINGINDIA': 'dining',
        'STARBUCKSCOFFEEINDIRANAGAR': 'dining',
        'NYKAAKIOSKVEGACITYBA': 'online',
        'MYNTRADESIGNSPVTLTD': 'online',
        'AIRFIBERPAYMENT5G': 'bills',
        'MAKEMYTRIPINDIAPVT': 'travel',
      };
      cases.forEach((name, slug) => expect(purchase(name), slug, reason: name));
    });

    test('a type of business names its category, singular or plural', () {
      const cases = {
        'WISDEN CLINICS': 'health',
        'CITY HOSPITALS': 'health',
        'SUNRISE PHARMACIES': 'health',
        'RAJESH DENTAL': 'health',
        'GLENS BAKEHOUSE': 'dining',
        'SGS NON VEG GUNDUP': 'dining',
        'MAHARAJA PURE VEG': 'dining',
        'LAKESIDE EATERY': 'dining',
        'MOUNTAIN VIEW CAFES': 'dining',
        'SHRI SAI TIFFIN': 'dining',
      };
      cases.forEach((name, slug) => expect(purchase(name), slug, reason: name));
    });

    test('a brand the rules did not know', () {
      const cases = {
        'POPEYES': 'dining',
        'TUTEDUDE': 'education',
        'PHYSICS WALLAH': 'education',
        'TRULYMADLY': 'entertainment',
        'SHAADI COM': 'entertainment',
        'SONYLIV': 'entertainment',
        'FIRSTCRY': 'online',
        'TORRENT POWER LTD': 'bills',
        'XSTREAM FIBER': 'bills',
        'PHARMEASY': 'health',
        'JIOMART': 'groceries',
        'RAPIDO': 'travel',
      };
      cases.forEach((name, slug) => expect(purchase(name), slug, reason: name));
    });

    test('a name with nothing recognisable stays other', () {
      for (final name in ['MANGALORESEAPARK', 'AVIGHNA ENTERPRISE', 'QIKWELL TECHNOLOGI', 'ECO WORLD 4B CB', 'XYZ TRADERS']) {
        expect(purchase(name), 'other', reason: name);
      }
    });
  });

  group('a UPI payment: only a payee that is wholly a known business is categorised', () {
    test('a name a bank cut short, or a legal name, resolves through its alias', () {
      const cases = {
        'ZEPTO MARKETPLAC': 'groceries',
        'AIR FIBER PAYMEN': 'bills',
        'FLIPKART INTERNE': 'online',
        'AMAZON SELLER SE': 'online',
        'DOMINOSPIZZA': 'dining',
        'ROPPEN TRANSPORT': 'travel',
      };
      cases.forEach((name, slug) => expect(upi(name), slug, reason: name));
    });

    test('a known business by its whole name', () {
      const cases = {'TRULYMADLY': 'entertainment', 'DISTRICT DINING': 'dining', 'BUMBLE': 'entertainment', 'UDEMY': 'education'};
      cases.forEach((name, slug) => expect(upi(name), slug, reason: name));
    });

    test('a person is never given a category, even when a brand word is in the name', () {
      for (final name in [
        'RAVI KUMAR',
        'ASHA RAO',
        'PRIYA SHARMA',
        'SURESH S',
        'JOHN BUMBLE',
        'RAMESH DENTAL',
        'ANITA CAFES',
        'VEG PRADEEP',
        'M S I CLUSTER TE',
      ]) {
        expect(upi(name), 'other', reason: name);
      }
    });

    test('a person (as the engine marks one) never gets a merchant key at all', () {
      final d = resolver.decide(
        eventType: EventType.p2pOut,
        input: input('TRULYMADLY', kind: CounterpartyKind.person),
      )!;
      expect(d.slug, 'other');
    });
  });

  test('what was already categorised keeps its category', () {
    const cases = {
      'SWIGGY INSTAMART': 'groceries',
      'SWIGGY': 'dining',
      'ZOMATO': 'dining',
      'AMAZON': 'online',
      'AMAZON PRIME VIDEO': 'entertainment',
      'NETFLIX': 'entertainment',
      'IRCTC': 'travel',
      'ZEPTONOW': 'groceries',
      'APOLLO PHARMACY': 'health',
      'DISTRICT MOVIES': 'entertainment',
    };
    cases.forEach((name, slug) => expect(purchase(name), slug, reason: name));
  });
}
