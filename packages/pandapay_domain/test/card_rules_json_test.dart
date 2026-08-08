import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  // A real GET /catalogue response captured from a live api/ + pandapay
  // Postgres database (db/seed/0001_demo_cards.sql), not hand-written JSON —
  // this is what actually catches "the parser assumes numbers, Postgres
  // sends numeric columns as strings" bugs.
  final fixture = jsonDecode(
    File('test/fixtures_catalogue_response.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cardsJson = (fixture['cards'] as List).cast<Map<String, dynamic>>();

  test('fixture has the 4 seeded cards', () {
    expect(cardsJson, hasLength(4));
  });

  test('parses every card in the live fixture without throwing', () {
    for (final json in cardsJson) {
      final card = CardProductJson.fromJson(json);
      expect(card.id, isNotEmpty);
      expect(card.name, isNotEmpty);
    }
  });

  test('axis-ace: RuPay/UPI-linkable, two reward rules, one cap rule', () {
    final json = cardsJson.firstWhere((c) => c['slug'] == 'axis-ace');
    final card = CardProductJson.fromJson(json);

    expect(card.network, CardNetwork.rupay);
    expect(card.isUpiLinkable, isTrue);
    expect(card.rewardRules, hasLength(2));
    expect(card.rewardRules.first.unit, RewardUnit.cashbackPercent);
    expect(card.rewardRules.first.rate, 5);
    expect(card.capRules, hasLength(1));
    expect(card.capRules.first.capValue, Money.fromRupees(500));
    expect(card.capRules.first.period, CapPeriod.calendarMonth);
    expect(card.capRules.first.postCapRate, 1.5);
  });

  test('icici-amazon-pay: points/100 unit, forex rule, milestone rule all parse', () {
    final json = cardsJson.firstWhere((c) => c['slug'] == 'icici-amazon-pay');
    final card = CardProductJson.fromJson(json);

    expect(card.rewardRules.first.unit, RewardUnit.pointsPer100);
    expect(card.forexRule, isNotNull);
    expect(card.forexRule!.markupPercent, 3.5);
    expect(card.milestoneRules, hasLength(1));
    expect(card.milestoneRules.first.thresholdSpend, Money.fromRupees(1000000));
    expect(card.milestoneRules.first.rewardValue, Money.fromRupees(1000));
  });

  test('a numeric top-level column sent as a JSON string (annual_fee_inr) does not throw', () {
    final json = cardsJson.first;
    expect(json['annual_fee_inr'], isA<String>()); // confirms the fixture really has this shape
    // point_value_inr also arrives as a string ("1.0000") — parsed via pointValueInr.
    final card = CardProductJson.fromJson(json);
    expect(card.pointValueInr, 1.0);
  });

  test('Task C-0: catalogue-display fields (fee/freshness/issuer/art) parse from the live fixture', () {
    final json = cardsJson.firstWhere((c) => c['slug'] == 'axis-ace');
    final card = CardProductJson.fromJson(json);

    expect(card.annualFeeInr, Money.fromRupees(499));
    expect(card.joiningFeeInr, Money.fromRupees(499));
    expect(card.verifiedAt, isNotNull);
    expect(card.issuerName, 'Axis Bank');
    // art_asset/art_primary_color are null in this fixture (not seeded) —
    // asserting the parse doesn't throw on absent art is the point here.
    expect(card.artAssetUrl, isNull);
    expect(card.artPrimaryColor, isNull);
  });

  test('Task C-0: fee_waiver_rules and benefits parse from a hand-built response shape', () {
    // The seed fixture's fee_waiver_rules/benefits arrays are empty (not
    // seeded yet) — this exercises the actual field-mapping against the
    // real v_card_catalogue_export shape (database.sql) rather than relying
    // on seed data catching up first.
    final json = {
      ...cardsJson.first,
      'fee_waiver_rules': [
        {
          'id': 'fw-1',
          'threshold_spend_inr': '250000.00',
          'period': 'annual',
          'waives_fee_inr': '499.00',
          'excluded_categories': ['cat-fuel'],
          'notes': 'Fuel and rent excluded',
        },
      ],
      'benefits': [
        {
          'id': 'b-1',
          'kind': 'lounge_domestic',
          'label': '8 domestic lounge visits/year',
          'description': 'Priority Pass required',
          'quota_count': 8,
          'quota_period': 'annual',
          'network_program': 'Priority Pass',
          'value_estimate_inr': '3200.00',
        },
      ],
    };
    final card = CardProductJson.fromJson(json);

    expect(card.feeWaiverRules, hasLength(1));
    expect(card.feeWaiverRules.first.thresholdSpend, Money.fromRupees(250000));
    expect(card.feeWaiverRules.first.period, CapPeriod.annual);
    expect(card.feeWaiverRules.first.waivesFee, Money.fromRupees(499));
    expect(card.feeWaiverRules.first.excludedCategoryIds, ['cat-fuel']);

    expect(card.benefits, hasLength(1));
    expect(card.benefits.first.kind, BenefitKind.loungeDomestic);
    expect(card.benefits.first.quotaCount, 8);
    expect(card.benefits.first.quotaPeriod, CapPeriod.annual);
    expect(card.benefits.first.networkProgram, 'Priority Pass');
    expect(card.benefits.first.valueEstimate, Money.fromRupees(3200));
  });

  test('parsed cards are directly usable by RecommendationEngine.rank()', () {
    final cards = cardsJson.map((j) => CardProductJson.fromJson(j)).toList();
    final engine = RecommendationEngine();
    // The seed data (db/seed/0001_demo_cards.sql) only inserts category-specific
    // reward rules, no "all other spends" fallback — so a context naming a
    // covered category (online: hdfc-millennia, sbi-cashback, icici-amazon-pay)
    // is what actually exercises ranking; axis-ace correctly excludes here since
    // it has no online-category rule, which is the engine's real, working
    // "never silently drop" behavior, not a bug in this test.
    final ctx = RecommendationContext(
      amount: Money.fromRupees(1000),
      categoryId: cardsJson
          .firstWhere((c) => c['slug'] == 'hdfc-millennia')['reward_rules'][0]['category_id'] as String,
      rail: TxnRail.swipe,
    );

    final results = engine.rank(ctx, cards.map((c) => CardSnapshot(product: c)).toList());

    expect(results, hasLength(4));
    expect(results.any((r) => !r.isExcluded), isTrue);
    expect(results.where((r) => r.card.id == cards.firstWhere((c) => c.name == 'Axis Ace').id).first.isExcluded,
        isTrue); // no online-category rule on this card — correctly excluded, not dropped
  });
}
