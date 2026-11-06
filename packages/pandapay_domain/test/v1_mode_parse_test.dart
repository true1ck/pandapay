import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D32a: a schema-1 body is parsed in v1 mode.
///
/// The v1 feed's rule and cap rows are `to_jsonb(row)`, so they carry the v2
/// columns too (`rule_role`, `max_engine_version`, `min_engine_version`,
/// `cap_kind`, ...). The released parser ignores them. The new parser must as
/// well when the body is schema 1, or a v1-served card turns v2-shaped while
/// the precise v2 rows are not in the v1 feed (the v1-only conservative rows
/// are ignored by the v2 engine) and it over-states: cashback-sbi-card earned
/// ₹50 on ₹5,000 of bills, insurance and fuel instead of 0.
const _snapshotDir = '../../db/fixtures/catalogue_v2_cards';

Map<String, dynamic> _fixture(String slug) =>
    (jsonDecode(File('$_snapshotDir/$slug.json').readAsStringSync())
            as Map<String, dynamic>)['card']
        as Map<String, dynamic>;

/// What `v_card_catalogue_export` serves for [card] (migration
/// 20261105120000): the card's own columns, rules with `min_engine_version = 1`
/// and not `info`, caps with `min_engine_version = 1` whose rule(s) are
/// visible (and no `cap_rule_targets` column), milestones without
/// `window_days`. Rows keep EVERY column (`to_jsonb`), including the v2 ones.
Map<String, dynamic> _v1View(Map<String, dynamic> card) {
  final rules = (card['reward_rules'] as List).cast<Map<String, dynamic>>();
  final hidden = {
    for (final r in rules)
      if ((r['min_engine_version'] ?? 1) != 1 || r['rule_role'] == 'info')
        r['id'],
  };
  final caps = [
    for (final k in (card['cap_rules'] as List).cast<Map<String, dynamic>>())
      if ((k['min_engine_version'] ?? 1) == 1 &&
          !hidden.contains(k['reward_rule_id']) &&
          !((k['targets'] as List?) ?? const []).any(hidden.contains))
        Map<String, dynamic>.of(k)..remove('targets'),
  ];
  final out = Map<String, dynamic>.of(card);
  for (final key in [
    'accrual_block_inr',
    'accrual_rounding',
    'cashback_rounding',
    'points_expiry_months',
    'model_status',
    'model_coverage',
    'unlock_rules',
    'redemption_options',
  ]) {
    out.remove(key);
  }
  out['reward_rules'] = [
    for (final r in rules)
      if (!hidden.contains(r['id'])) r,
  ];
  out['cap_rules'] = caps;
  out['milestone_rules'] = [
    for (final m in ((card['milestone_rules'] as List?) ?? const []))
      if ((m as Map)['window_days'] == null) m,
  ];
  return out;
}

/// The released parser, written out independently: only the keys it read.
CardProduct _releasedParse(Map<String, dynamic> body) {
  Map<String, dynamic> keep(Map<String, dynamic> row, Set<String> keys) => {
    for (final e in row.entries)
      if (keys.contains(e.key)) e.key: e.value,
  };
  const ruleKeys = {
    'id',
    'category_id',
    'merchant_pattern',
    'rail',
    'unit',
    'rate',
    'min_txn_inr',
    'max_txn_inr',
    'excluded_categories',
    'effective_from',
    'effective_to',
    'priority',
  };
  const capKeys = {
    'id',
    'reward_rule_id',
    'category_id',
    'label',
    'cap_value',
    'measure',
    'post_cap_unit',
    'post_cap_rate',
    'period',
  };
  const milestoneKeys = {
    'id',
    'label',
    'threshold_spend_inr',
    'reward_value_inr',
    'is_repeatable',
    'period',
    'anchor',
  };
  const cardKeys = {
    'id',
    'name',
    'network',
    'is_upi_linkable',
    'point_value_inr',
    'base_reward_unit',
    'base_reward_rate',
    'excluded_categories',
    'forex',
    'fuel',
    'fee_waiver_rules',
    'benefits',
    'annual_fee_inr',
    'joining_fee_inr',
    'verified_at',
    'issuer_name',
    'card_type',
    'art_asset',
    'art_primary_color',
    'has_apply_url',
  };
  final released = keep(body, cardKeys);
  released['reward_rules'] = [
    for (final r in (body['reward_rules'] as List))
      keep(r as Map<String, dynamic>, ruleKeys),
  ];
  released['cap_rules'] = [
    for (final k in (body['cap_rules'] as List))
      keep(k as Map<String, dynamic>, capKeys),
  ];
  released['milestone_rules'] = [
    for (final m in (body['milestone_rules'] as List))
      keep(m as Map<String, dynamic>, milestoneKeys),
  ];
  return CardProductJson.fromJson(released);
}

Recommendation _rank(
  CardProduct card,
  String category, {
  TxnRail rail = TxnRail.swipe,
  double amount = 5000,
  String? mcc,
}) => const RecommendationEngine()
    .rank(
      RecommendationContext(
        amount: Money.fromRupees(amount),
        categoryId: 'cat-$category',
        categorySlug: category,
        mcc: mcc,
        rail: rail,
        now: DateTime(2026, 11, 6),
      ),
      [CardSnapshot(product: card)],
    )
    .single;

void main() {
  group('cashback-sbi-card: the v1 feed in v1 mode', () {
    final body = _v1View(_fixture('cashback-sbi-card'));

    test('the card stays v1-shaped and takes the v1 engine path', () {
      final card = CardProductJson.fromJson(body, v1Mode: true);
      expect(card.isV2Shaped, isFalse);
      expect(card.parseWarnings, isEmpty);
      for (final r in card.rewardRules) {
        expect(r.role, isNull);
        expect(r.maxEngineVersion, isNull);
        expect(r.hasV2Fields, isFalse);
      }
      for (final c in card.capRules) {
        expect(c.capKind, isNull);
        expect(c.hasV2Fields, isFalse);
      }
    });

    test('bills, insurance and fuel earn 0 on ₹5,000 (v1 excludes them)', () {
      final card = CardProductJson.fromJson(body, v1Mode: true);
      for (final category in ['bills', 'insurance', 'fuel']) {
        final rec = _rank(card, category);
        expect(rec.expectedValue, const Money.zero(), reason: category);
      }
    });

    test('the same body without v1 mode is the defect: v2-shaped, ₹50 on '
        'bills', () {
      final card = CardProductJson.fromJson(body);
      expect(card.isV2Shaped, isTrue);
      expect(
        _rank(card, 'bills').expectedValue,
        Money.fromRupees(50),
        reason: 'what the schema-1 body did before D32a',
      );
    });

    test('equals the released parser on the same body', () {
      final mine = CardProductJson.fromJson(body, v1Mode: true);
      final released = _releasedParse(body);
      for (final category in [
        'bills',
        'insurance',
        'fuel',
        'travel',
        'rent',
        'wallet',
        'education',
        'groceries',
        'online',
      ]) {
        for (final rail in [TxnRail.swipe, TxnRail.online, TxnRail.emi]) {
          final a = _rank(mine, category, rail: rail);
          final b = _rank(released, category, rail: rail);
          expect(a.expectedValue, b.expectedValue, reason: '$category/$rail');
          expect(a.isExcluded, b.isExcluded, reason: '$category/$rail');
          expect(a.exclusionReason, b.exclusionReason);
        }
      }
    });
  });

  group('idfc-first-select: the v1 feed in v1 mode', () {
    final body = _v1View(_fixture('idfc-first-select'));

    test('stays v1-shaped and equals the released parser, including an emi '
        'rail case', () {
      final mine = CardProductJson.fromJson(body, v1Mode: true);
      final released = _releasedParse(body);
      expect(mine.isV2Shaped, isFalse);
      for (final category in [
        'emi',
        'fuel',
        'bills',
        'travel',
        'dining',
        'insurance',
        'groceries',
      ]) {
        for (final rail in [TxnRail.emi, TxnRail.swipe, TxnRail.upiQr]) {
          final a = _rank(mine, category, rail: rail);
          final b = _rank(released, category, rail: rail);
          expect(a.expectedValue, b.expectedValue, reason: '$category/$rail');
          expect(a.isExcluded, b.isExcluded, reason: '$category/$rail');
        }
      }
    });

    test('fuel is excluded (v1 row 0x_fuel#1), not paid at the base rate', () {
      final mine = CardProductJson.fromJson(body, v1Mode: true);
      expect(_rank(mine, 'fuel').expectedValue, const Money.zero());
      // Without v1 mode the max_engine_version 1 row is ignored and fuel
      // earns 3 pts/₹200 (₹18.75 on ₹5,000).
      final misparsed = CardProductJson.fromJson(body);
      expect(_rank(misparsed, 'fuel').expectedValue.paise, greaterThan(0));
    });

    test('travel stays at the conservative railway 1x, not the 10x travel '
        'accelerator', () {
      final mine = CardProductJson.fromJson(body, v1Mode: true);
      final misparsed = CardProductJson.fromJson(body);
      expect(
        _rank(mine, 'travel').expectedValue.paise,
        lessThan(_rank(misparsed, 'travel').expectedValue.paise),
      );
    });
  });

  group('every fixture card: a v1 body never turns v2-shaped in v1 mode', () {
    final dir = Directory(_snapshotDir);
    final slugs = [
      for (final f in dir.listSync().whereType<File>())
        if (!f.uri.pathSegments.last.startsWith('_') &&
            f.path.endsWith('.json'))
          f.uri.pathSegments.last.replaceAll('.json', ''),
    ]..sort();

    test('there are fixture cards to check', () {
      expect(slugs.length, greaterThan(30));
    });

    for (final slug in slugs) {
      test(slug, () {
        final body = _v1View(_fixture(slug));
        final card = CardProductJson.fromJson(body, v1Mode: true);
        expect(card.isV2Shaped, isFalse);
        expect(card.parseWarnings, isEmpty);
        // The same card as the released parser reads it.
        final released = _releasedParse(body);
        expect(card.rewardRules.length, released.rewardRules.length);
        expect(card.capRules.length, released.capRules.length);
      });
    }
  });

  group('v1 mode keeps what the v1 engine reads', () {
    test('a windowed milestone keeps window_days (the engine skips it)', () {
      final card = CardProductJson.fromJson({
        'id': 'c',
        'name': 'c',
        'network': 'visa',
        'milestone_rules': [
          {
            'id': 'm',
            'label': 'Welcome',
            'threshold_spend_inr': 50000,
            'reward_value_inr': 1000,
            'window_days': 60,
            'reward_points': 10,
            'source_local_id': 'welcome',
          },
        ],
      }, v1Mode: true);
      expect(card.milestoneRules.single.windowDays, 60);
      expect(card.milestoneRules.single.rewardPoints, isNull);
      expect(card.milestoneRules.single.sourceLocalId, isNull);
    });

    test('card-level v2 columns are ignored too', () {
      final card = CardProductJson.fromJson({
        'id': 'c',
        'name': 'c',
        'network': 'visa',
        'accrual_rounding': 'floor',
        'cashback_rounding': 'rupee_floor',
        'model_status': 'verified',
      }, v1Mode: true);
      expect(card.isV2Shaped, isFalse);
      expect(card.modelStatus, isNull);
    });

    test('v1 mode is still as strict about v1 fields', () {
      expect(
        () => CardProductJson.fromJson({
          'id': 'c',
          'name': 'c',
          'network': 'visa',
          'base_reward_unit': 'not_a_unit',
          'base_reward_rate': 1,
        }, v1Mode: true),
        throwsFormatException,
      );
    });

    test('the default is unchanged: a v2 body parses as v2', () {
      final card = CardProductJson.fromJson(_fixture('cashback-sbi-card'));
      expect(card.isV2Shaped, isTrue);
      expect(card.modelStatus, isNotNull);
    });
  });
}
