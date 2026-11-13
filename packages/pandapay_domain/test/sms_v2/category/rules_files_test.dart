import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:test/test.dart';

// Checks the assumptions WP-03d made about the resolver, against the real
// rules/sms/v2 files: whole-token matching, aliases on the whole merchant key,
// and context tokens looked up in the merchant key.

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

  CategoryDecision resolve(String name, {List<String> context = const []}) => resolver.resolve(CategoryInput(
        counterparty: Counterparty(name: name, kind: CounterpartyKind.merchant),
        senderBrand: 'HDFCBK',
        contextTokens: context,
        bundleRules: rules,
      ));

  test('the files have the expected size and only catalogue rules', () {
    // 604 + 14 truncated-name and lender/insurer entries seen in a real inbox:
    // PETROLEU (whole token), FLIPKA (exact) and FLIPKARTINTERNE, WELLNESS FOREVE
    // and WELLNESSFOREVER, TURTLEM (exact) and TURTLEMINT, ALEGRA COMMUNICATION,
    // HUNGERBOX, CAPITAL FLOAT, CAPITALFLOAT, PAYU FINANCE, GODIGIT, LIBERTY
    // GENERAL. They are exact, whole-token or full-name keys on purpose: a bare
    // stem such as WELLNES or ALEGRA would also take WELLNESS SPA or ALEGRA FOODS.
    expect(rules.length, 618);
    expect(aliases.length, 166);
    expect(rules.every((r) => r.source == CategorySource.catalogue), isTrue);
    expect(rules.every((r) => r.senders.length == 1 && r.senders.single == '*'), isTrue);
  });

  test('every rule key is already in normal form and has no legal suffix', () {
    for (final r in rules) {
      expect(normalizeMerchantText(r.merchantKey), r.merchantKey, reason: r.merchantKey);
      expect(stripLegalSuffix(r.merchantKey), r.merchantKey, reason: r.merchantKey);
    }
  });

  test('every alias target is in normal form', () {
    for (final a in aliases) {
      expect(normalizeMerchantText(a.merchantKey), a.merchantKey, reason: a.alias);
    }
  });

  test('each rule matches its own key (with a context token when it needs one) and gets its category', () {
    final misses = <String>[];
    for (final r in rules) {
      final d = resolve(r.merchantKey, context: r.context.isEmpty ? const [] : [r.context.first]);
      if (d.slug != r.category) {
        misses.add('${r.merchantKey}(${r.category}) -> ${d.slug}');
      } else if (d.source != CategorySource.catalogue) {
        misses.add('${r.merchantKey}: source ${d.source.wire}');
      }
    }
    expect(misses, isEmpty);
  });

  test('a rule key matches when it is a whole-token span inside a longer merchant name', () {
    for (final r in rules.where((r) => r.context.isEmpty && r.match == CategoryMatch.token)) {
      final d = resolve('${r.merchantKey} KORAMANGALA');
      // A longer rule may win, but only another real rule: never `other`.
      expect(d.source, CategorySource.catalogue, reason: r.merchantKey);
      if (d.slug != r.category) continue;
      expect(d.confidence, 0.8, reason: r.merchantKey);
    }
  });

  test('exact-only rules (OLA, VI) do not match inside a longer name', () {
    for (final r in rules.where((r) => r.match == CategoryMatch.exact)) {
      final d = resolve('${r.merchantKey} XQ');
      expect(d.source, isNot(CategorySource.catalogue), reason: r.merchantKey);
    }
  });

  test('a rule key never matches inside another word', () {
    for (final r in rules.where((r) => r.context.isEmpty && !r.merchantKey.contains(' '))) {
      final d = resolve('X${r.merchantKey}Y');
      expect(d.slug == r.category && d.source == CategorySource.catalogue, isFalse, reason: r.merchantKey);
    }
  });

  test('each alias maps its whole key to the target, and the result resolves like the target', () {
    final problems = <String>[];
    final keyer = MerchantKeyer(aliases);
    for (final a in aliases) {
      final key = keyer.keyForName(a.alias);
      if (key != a.merchantKey) problems.add('${a.alias}: key $key, want ${a.merchantKey}');
      final viaAlias = resolve(a.alias);
      final direct = resolve(a.merchantKey);
      if (viaAlias.slug != direct.slug) {
        problems.add('${a.alias}: ${viaAlias.slug} but ${a.merchantKey} gives ${direct.slug}');
      }
    }
    expect(problems, isEmpty);
  });

  test('alias targets with no category are the deliberate ones: payments apps and brokers', () {
    // 03d dropped PAYTM and CRED as ambiguous and keeps investments out of the
    // spend taxonomy, so these aliases only normalise the key.
    final unresolved = {
      for (final a in aliases)
        if (resolve(a.merchantKey).source == CategorySource.fallback) a.merchantKey,
    };
    expect(unresolved, {'PAYTM', 'CRED', 'GROWW', 'UPSTOX', 'ZERODHA'});
  });

  test('an alias applies to the whole key only', () {
    final keyer = MerchantKeyer(aliases);
    expect(keyer.keyForName('AMAZON PAY IN'), 'AMAZON');
    expect(keyer.keyForName('AMAZON PAY IN KARNATAKA'), 'AMAZON PAY IN KARNATAKA');
    expect(resolve('AMAZON PAY IN KARNATAKA').slug, 'online');
  });

  test('context tokens are looked up in the merchant key and in the caller context', () {
    final indigo = rules.singleWhere((r) => r.merchantKey == 'INDIGO');
    expect(indigo.context, isNotEmpty);
    expect(resolve('INDIGO').slug, 'other');
    for (final c in indigo.context) {
      expect(resolve('INDIGO $c').slug, 'travel', reason: 'merchant key + $c');
      expect(resolve('INDIGO', context: [c]).slug, 'travel', reason: 'caller context $c');
    }
    expect(resolve('INDIGO PAINTS').slug, 'other');
    expect(resolve('INDIGO PAINTS', context: ['PAINT']).slug, 'other');
  });

  test('the shipped collision cases from the audit', () {
    expect(resolve('KUBER HARDWARE').slug, 'other');
    expect(resolve('SPARK ELECTRICALS').slug, 'other');
    expect(resolve('SHELLY BOOK STORE').slug, 'other');
    expect(resolve('UBER EATS').slug, 'dining');
    expect(resolve('SWIGGY INSTAMART').slug, 'groceries');
    expect(resolve('AMAZON PAY IN').slug, 'online');
  });
}
