import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/merchant_context.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// WP9 context builder (C8 D19c, D24f): the merchant name resolves through
/// the directory to a slug, and a missing MCC is filled from the resolved
/// merchant's FIRST listed MCC. The platform is never guessed (C3.1).
MerchantDirectory _directory() => MerchantDirectory.fromJson({
  'merchants': [
    {
      'slug': 'swiggy',
      'name': 'Swiggy',
      'category_slug': 'dining',
      'aliases': ['swiggy', 'bundl technologies'],
      'vpa_prefixes': ['swiggy'],
      'mcc': ['5814', '5812'],
    },
    {
      'slug': 'noodle_bar',
      'name': 'Noodle Bar',
      'aliases': ['noodle bar'],
      'mcc': <String>[],
    },
  ],
  'platforms': [
    {
      'slug': 'phonepe_app',
      'name': 'PhonePe app',
      'kind': 'payment_app',
      'aliases': ['phonepe'],
    },
  ],
});

RecommendationContext _build({
  String? merchantName,
  String? vpa,
  String? mcc,
  MerchantDirectory? directory,
}) => buildRecommendationContext(
  directory: directory ?? _directory(),
  amount: const Money.fromPaise(100000),
  rail: TxnRail.swipe,
  merchantName: merchantName,
  vpa: vpa,
  mcc: mcc,
  categorySlug: 'dining',
);

void main() {
  test('resolves the merchant and sets its slug', () {
    final ctx = _build(merchantName: 'BUNDL TECHNOLOGIES PVT LTD');
    expect(ctx.merchantSlug, 'swiggy');
    expect(ctx.merchantName, 'BUNDL TECHNOLOGIES PVT LTD');
  });

  test('fills a missing MCC from the merchant\'s FIRST listed MCC', () {
    final ctx = _build(merchantName: 'Swiggy');
    expect(ctx.mcc, '5814');
  });

  test('an MCC the caller already has is kept', () {
    final ctx = _build(merchantName: 'Swiggy', mcc: '5812');
    expect(ctx.mcc, '5812');
    expect(ctx.merchantSlug, 'swiggy');
  });

  test('resolves from a UPI VPA when there is no merchant name', () {
    final ctx = _build(vpa: 'swiggy.order@icici');
    expect(ctx.merchantSlug, 'swiggy');
    expect(ctx.mcc, '5814');
    expect(ctx.vpa, 'swiggy.order@icici');
  });

  test('an unresolved merchant leaves slug and MCC alone', () {
    final ctx = _build(merchantName: 'Corner Shop', mcc: null);
    expect(ctx.merchantSlug, isNull);
    expect(ctx.mcc, isNull);
  });

  test('a merchant with no listed MCC leaves the MCC unknown', () {
    final ctx = _build(merchantName: 'Noodle Bar');
    expect(ctx.merchantSlug, 'noodle_bar');
    expect(ctx.mcc, isNull);
  });

  test('an empty directory (v1 fallback) changes nothing', () {
    final ctx = _build(
      merchantName: 'Swiggy',
      directory: MerchantDirectory.empty,
    );
    expect(ctx.merchantSlug, isNull);
    expect(ctx.mcc, isNull);
    expect(ctx.merchantName, 'Swiggy');
  });

  test('blank text resolves nothing', () {
    final ctx = _build(merchantName: '   ', vpa: '');
    expect(ctx.merchantSlug, isNull);
    expect(ctx.mcc, isNull);
  });

  test('never guesses a platform, even when the text names one', () {
    final ctx = _build(merchantName: 'PhonePe Swiggy');
    expect(ctx.platform, isNull);
  });

  test('passes the other fields through', () {
    final now = DateTime(2026, 11, 5);
    final ctx = buildRecommendationContext(
      directory: _directory(),
      amount: const Money.fromPaise(250000),
      rail: TxnRail.upiQr,
      categoryId: 'cat',
      categorySlug: 'dining',
      isP2P: true,
      travelMode: true,
      now: now,
    );
    expect(ctx.amount, const Money.fromPaise(250000));
    expect(ctx.rail, TxnRail.upiQr);
    expect(ctx.categoryId, 'cat');
    expect(ctx.categorySlug, 'dining');
    expect(ctx.isP2P, isTrue);
    expect(ctx.travelMode, isTrue);
    expect(ctx.now, now);
  });

  group('end to end: the filled MCC changes the answer (D19c)', () {
    // A dining 5 pts/₹100 rule that excludes MCC 5814 (fast food), as the
    // loader emits for a narrow-token exclusion (D18b). Without an MCC the
    // category stands in and the rule would pay on a fast-food merchant.
    CardProduct card() => parseCard({
      'id': 'p',
      'name': 'Dining Card',
      'network': 'visa',
      'point_value_inr': 0.25,
      'base_reward_unit': 'points_per_100',
      'base_reward_rate': 1,
      'accrual_rounding': 'floor',
      'reward_rules': [
        {
          'id': 'dining-rule',
          'category_id': 'cat-dining',
          'merchant_pattern': null,
          'rail': null,
          'unit': 'points_per_100',
          'rate': 5,
          'priority': 10,
          'rule_role': 'earn',
          'mcc_exclude': ['5814'],
          'min_engine_version': 2,
        },
      ],
      'cap_rules': <Map<String, dynamic>>[],
    });

    double points(RecommendationContext ctx) =>
        const RecommendationEngine()
            .rank(ctx, [CardSnapshot(product: card())])
            .single
            .reward!
            .points!;

    test('MCC unknown: the category stands in and the bonus is paid', () {
      final ctx = RecommendationContext(
        amount: const Money.fromPaise(1000000),
        categoryId: 'cat-dining',
        rail: TxnRail.swipe,
        merchantName: 'Swiggy',
      );
      expect(points(ctx), 500);
    });

    test('MCC filled from the directory: the exclusion applies', () {
      final ctx = buildRecommendationContext(
        directory: _directory(),
        amount: const Money.fromPaise(1000000),
        categoryId: 'cat-dining',
        rail: TxnRail.swipe,
        merchantName: 'Swiggy',
      );
      expect(ctx.mcc, '5814');
      expect(points(ctx), 100);
    });
  });
}
