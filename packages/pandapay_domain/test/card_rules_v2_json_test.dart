import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C1/C2 v2 catalogue fields: tolerant parsing (a bad v2 value skips a
/// rule or cap, never the card), the C3.2 v1/v2 switch, the C8/D1 identity
/// keys, and a lossless toJson round trip for the offline cache.
Map<String, dynamic> _card({
  List<Map<String, dynamic>> rules = const [],
  List<Map<String, dynamic>> caps = const [],
  Map<String, dynamic> extra = const {},
}) => {
  'id': 'card-1',
  'name': 'Test Card',
  'network': 'visa',
  'point_value_inr': 0.25,
  'base_reward_unit': 'points_per_100',
  'base_reward_rate': 1,
  'reward_rules': rules,
  'cap_rules': caps,
  ...extra,
};

Map<String, dynamic> _rule(
  String id, [
  Map<String, dynamic> extra = const {},
]) => {
  'id': id,
  'category_id': null,
  'merchant_pattern': null,
  'rail': null,
  'unit': 'points_per_100',
  'rate': 5,
  'priority': 10,
  ...extra,
};

Map<String, dynamic> _cap(String id, [Map<String, dynamic> extra = const {}]) =>
    {
      'id': id,
      'reward_rule_id': null,
      'category_id': null,
      'label': 'Cap $id',
      'measure': 'reward_value',
      'period': 'calendar_month',
      'cap_value': 100,
      'post_cap_unit': null,
      'post_cap_rate': null,
      ...extra,
    };

void main() {
  group('v1 compatibility', () {
    test('the pinned v1 feed parses with no warnings and is v1-shaped', () {
      final feed =
          jsonDecode(
                File(
                  'test/fixtures_catalogue_response.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final raw in (feed['cards'] as List).cast<Map<String, dynamic>>()) {
        final card = CardProductJson.fromJson(raw);
        expect(card.parseWarnings, isEmpty, reason: card.id);
        expect(card.isV2Shaped, isFalse, reason: card.id);
        for (final r in card.rewardRules) {
          expect(r.role, isNull);
          expect(r.hasV2Fields, isFalse);
        }
        for (final c in card.capRules) {
          expect(c.capKind, isNull);
          expect(c.hasV2Fields, isFalse);
        }
      }
    });

    test(
      'a v1 field is still strict: an unknown reward unit fails the card',
      () {
        expect(
          () => CardProductJson.fromJson(
            _card(
              rules: [
                _rule('r1', {'unit': 'points_per_999'}),
              ],
            ),
          ),
          throwsFormatException,
        );
      },
    );

    test('v1 rule/cap toJson has no v2 keys', () {
      final card = CardProductJson.fromJson(
        _card(rules: [_rule('r1')], caps: [_cap('c1')]),
      );
      final json = card.toJson();
      final rule = (json['reward_rules'] as List).single as Map;
      final cap = (json['cap_rules'] as List).single as Map;
      expect(rule.containsKey('rule_role'), isFalse);
      expect(rule.containsKey('merchant_slugs'), isFalse);
      expect(cap.containsKey('cap_kind'), isFalse);
      expect(cap.containsKey('scope'), isFalse);
      expect(json.containsKey('accrual_rounding'), isFalse);
      expect(json.containsKey('unlock_rules'), isFalse);
    });
  });

  group('C3.2 v2 switch', () {
    test('D10: DB-defaulted v2 columns alone keep a card v1-shaped', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('r1', {
              'rule_role': 'earn',
              'merchant_slugs': [],
              'platform_slugs': [],
              'mcc_include': [],
              'mcc_exclude': [],
              'block_inr': null,
              'min_engine_version': 1,
              'source_local_id': 'x',
              'display_note': 'note',
            }),
          ],
          caps: [
            _cap('c1', {
              'cap_kind': null,
              'scope': 'targets',
              'targets': [],
              'min_engine_version': 1,
            }),
          ],
          extra: {'accrual_rounding': null, 'model_status': 'basic'},
        ),
      );
      expect(card.isV2Shaped, isFalse);
    });

    for (final entry in <String, Map<String, dynamic>>{
      'rule_role base': {'rule_role': 'base'},
      'rule_role exclusion': {'rule_role': 'exclusion'},
      'rule_role info': {'rule_role': 'info'},
      'merchant_slugs': {
        'merchant_slugs': ['swiggy'],
      },
      'platform_slugs': {
        'platform_slugs': ['phonepe_app'],
      },
      'mcc_include': {
        'mcc_include': ['5411'],
      },
      'mcc_exclude': {
        'mcc_exclude': ['5411'],
      },
      'block_inr': {'block_inr': 150},
      'min_engine_version 2': {'min_engine_version': 2},
    }.entries) {
      test('D10: ${entry.key} marks the card v2', () {
        final card = CardProductJson.fromJson(
          _card(
            rules: [
              _rule('r1', {'rule_role': 'earn', ...entry.value}),
            ],
          ),
        );
        expect(card.isV2Shaped, isTrue);
      });
    }

    test('a non-null cap_kind marks the card v2', () {
      final card = CardProductJson.fromJson(
        _card(
          caps: [
            _cap('c1', {'cap_kind': 'bonus_points', 'cap_amount': 400}),
          ],
        ),
      );
      expect(card.isV2Shaped, isTrue);
    });

    test('accrual_rounding marks the card v2', () {
      final card = CardProductJson.fromJson(
        _card(extra: {'accrual_rounding': 'round'}),
      );
      expect(card.isV2Shaped, isTrue);
      expect(card.accrualRounding, AccrualRounding.round);
    });

    test('D11: cashback_rounding marks the card v2', () {
      final card = CardProductJson.fromJson(
        _card(extra: {'cashback_rounding': 'rupee_floor'}),
      );
      expect(card.isV2Shaped, isTrue);
      expect(card.cashbackRounding, CashbackRounding.rupeeFloor);
      expect(card.parseWarnings, isEmpty);
    });

    test('D11: an unknown cashback_rounding reads as null with a warning', () {
      final card = CardProductJson.fromJson(
        _card(extra: {'cashback_rounding': 'nearest_ten'}),
      );
      expect(card.cashbackRounding, isNull);
      expect(card.isV2Shaped, isFalse);
      expect(card.parseWarnings.single, contains('cashback_rounding'));
    });

    test('null v2 values do not mark a card v2', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('r1', {'rule_role': null, 'merchant_slugs': null}),
          ],
          caps: [
            _cap('c1', {'cap_kind': null}),
          ],
          extra: {'accrual_rounding': null},
        ),
      );
      expect(card.isV2Shaped, isFalse);
    });

    test(
      'every contract scenario card parses cleanly; v2 unless it pins v1',
      () {
        final fixture =
            jsonDecode(
                  File(
                    '../../db/fixtures/reward_v2_scenarios/00_contract.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        for (final s
            in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
          final card = CardProductJson.fromJson(
            s['card'] as Map<String, dynamic>,
          );
          expect(card.parseWarnings, isEmpty, reason: s['name'] as String);
          // Scenarios with an "assert" list pin the v1 path (D10, e.g. L1).
          expect(
            card.isV2Shaped,
            s['assert'] == null,
            reason: s['name'] as String,
          );
        }
      },
    );
  });

  group('tolerant v2 parsing', () {
    test('an unknown rule_role skips that rule only, with a warning', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('good', {'rule_role': 'earn'}),
            _rule('bad', {'rule_role': 'mystery', 'rate': 9}),
          ],
        ),
      );
      expect(card.rewardRules.map((r) => r.id), ['good']);
      expect(card.parseWarnings.single, contains('bad'));
      expect(card.parseWarnings.single, contains('rule_role'));
    });

    test('a skipped v2 rule still marks the card v2', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('bad', {'rule_role': 'mystery'}),
          ],
        ),
      );
      expect(card.rewardRules, isEmpty);
      expect(card.isV2Shaped, isTrue);
    });

    test('malformed v2 list values skip the rule', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('a', {'rule_role': 'earn', 'platform_slugs': 'phonepe'}),
            _rule('b', {
              'rule_role': 'earn',
              'mcc_include': [5411],
            }),
          ],
        ),
      );
      expect(card.rewardRules.map((r) => r.id), ['b']);
      expect(card.rewardRules.single.mccInclude, ['5411']);
      expect(card.parseWarnings, hasLength(1));
    });

    test('a rule needing a newer engine is skipped', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('future', {'rule_role': 'earn', 'min_engine_version': 3}),
            _rule('now', {'rule_role': 'earn', 'min_engine_version': 2}),
          ],
        ),
      );
      expect(card.rewardRules.map((r) => r.id), ['now']);
      expect(card.parseWarnings.single, contains('engine'));
    });

    for (final entry in {
      'cap_kind': 'bonus_miles',
      'scope': 'issuer',
      'post_cap_behavior': 'half_rate',
    }.entries) {
      test('an unknown cap ${entry.key} skips that cap only', () {
        final card = CardProductJson.fromJson(
          _card(
            caps: [
              _cap('good', {'cap_kind': 'total_points', 'cap_amount': 100}),
              _cap('bad', {
                'cap_kind': 'bonus_points',
                'cap_amount': 50,
                entry.key: entry.value,
              }),
            ],
          ),
        );
        expect(card.capRules.map((c) => c.id), ['good']);
        expect(card.parseWarnings.single, contains(entry.key));
        // D12d: the engine reports it as cap_skipped:<id>:<reason>.
        expect(card.skippedCaps, {'bad': 'unsupported_${entry.key}'});
      });
    }

    test('an unknown cap anchor reads as null and keeps the cap', () {
      final card = CardProductJson.fromJson(
        _card(
          caps: [
            _cap('c1', {
              'cap_kind': 'bonus_points',
              'cap_amount': 50,
              'anchor': 'birthday',
            }),
          ],
        ),
      );
      expect(card.capRules.single.anchor, isNull);
      expect(card.skippedCaps, isEmpty);
    });

    test('a bad cap_amount skips the cap', () {
      final card = CardProductJson.fromJson(
        _card(
          caps: [
            _cap('bad', {'cap_kind': 'bonus_points', 'cap_amount': 'lots'}),
          ],
        ),
      );
      expect(card.capRules, isEmpty);
      expect(card.isV2Shaped, isTrue);
    });

    test('an unknown milestone reward_kind skips that milestone', () {
      final card = CardProductJson.fromJson(
        _card(
          extra: {
            'milestone_rules': [
              {
                'id': 'm1',
                'label': 'Spend 1L',
                'threshold_spend_inr': '100000.00',
                'reward_value_inr': '1000.00',
                'reward_kind': 'gold_bar',
              },
              {
                'id': 'm2',
                'label': 'Spend 2L',
                'threshold_spend_inr': '200000.00',
                'reward_value_inr': '2000.00',
                'reward_kind': 'points',
                'reward_points': 8000,
              },
            ],
          },
        ),
      );
      expect(card.milestoneRules.map((m) => m.id), ['m2']);
      expect(card.milestoneRules.single.rewardPoints, 8000);
    });

    test('unknown milestone period/anchor read as null, not a skip', () {
      final card = CardProductJson.fromJson(
        _card(
          extra: {
            'milestone_rules': [
              {
                'id': 'm1',
                'label': 'Spend 1L',
                'threshold_spend_inr': 100000,
                'reward_value_inr': 1000,
                'period': 'fortnight',
                'anchor': 'birthday',
              },
            ],
          },
        ),
      );
      expect(card.milestoneRules.single.period, isNull);
      expect(card.milestoneRules.single.anchor, isNull);
    });

    test('a bad unlock rule or redemption option is skipped, not the card', () {
      final card = CardProductJson.fromJson(
        _card(
          extra: {
            'unlock_rules': [
              {
                'id': 'u1',
                'kind': 'lounge_domestic',
                'label': '2 visits / quarter',
                'spend_threshold_inr': 50000,
                'spend_window': 'previous_calendar_quarter',
                'unlocks_quota': 2,
                'unlocks_period': 'quarter',
              },
              {
                'id': 'u2',
                'kind': 'spa',
                'label': 'Spa',
                'spend_threshold_inr': 1,
                'spend_window': 'calendar_month',
              },
              {'id': 'u3', 'kind': 'tier'},
            ],
            'redemption_options': [
              {
                'program_name': 'Statement credit',
                'method': 'statement_credit',
                'value_per_point_inr': '0.2500',
                'min_points': null,
              },
              {'program_name': 'Broken'},
            ],
          },
        ),
      );
      expect(card.unlockRules.map((u) => u.id), ['u1']);
      expect(card.unlockRules.single.spendThreshold, Money.fromRupees(50000));
      expect(card.unlockRules.single.unlocksPeriod, CapPeriod.quarter);
      expect(card.redemptionOptions.single.valuePerPointInr, 0.25);
      expect(card.parseWarnings, hasLength(3));
    });

    test('card-level v2 values degrade to defaults with a warning', () {
      final card = CardProductJson.fromJson(
        _card(
          extra: {
            'accrual_rounding': 'ceil',
            'model_status': 'gold',
            'points_expiry_months': 'never',
            'model_coverage': 'n/a',
          },
        ),
      );
      expect(card.accrualRounding, AccrualRounding.floor);
      expect(card.isV2Shaped, isTrue);
      expect(card.modelStatus, isNull);
      expect(card.pointsExpiryMonths, isNull);
      expect(card.modelCoverage, isEmpty);
      expect(card.parseWarnings, hasLength(4));
    });
  });

  group('round trip', () {
    test('every v2 field survives toJson -> jsonEncode -> fromJson', () {
      final wire = _card(
        rules: [
          _rule('r1', {
            'rule_role': 'earn',
            'merchant_slugs': ['swiggy', 'zomato'],
            'platform_slugs': ['phonepe_app'],
            'mcc_include': ['5812'],
            'mcc_exclude': ['5813'],
            'block_inr': 150,
            'min_engine_version': 2,
            'source_local_id': 'food-10x',
            'display_note': '10 pts/₹150 on food apps',
          }),
          _rule('r2', {'rule_role': 'exclusion', 'rate': 0}),
          _rule('r3', {'rule_role': 'info', 'rate': 20}),
          _rule('r4', {'rule_role': 'base', 'rate': 1}),
        ],
        caps: [
          _cap('c1', {
            'cap_kind': 'bonus_points',
            'cap_amount': 1500,
            'scope': 'targets',
            'targets': ['r1'],
            'parent_cap_id': 'c2',
            'post_cap_behavior': 'custom_rate',
            'post_cap_unit': 'points_per_100',
            'post_cap_rate': 2,
            'anchor': 'card_anniversary',
            'min_engine_version': 2,
            'source_local_id': 'food-cap',
          }),
          _cap('c2', {
            'cap_kind': 'total_points',
            'cap_amount': '5000.00',
            'scope': 'card',
          }),
        ],
        extra: {
          'accrual_block_inr': 150,
          'accrual_rounding': 'none',
          'cashback_rounding': 'rupee_half_up',
          'points_expiry_months': 24,
          'model_status': 'partial',
          'model_coverage': {
            'rules_total': 4,
            'flags': [
              {'code': 'unrestricted_accelerator'},
            ],
          },
          'milestone_rules': [
            {
              'id': 'm1',
              'label': 'Welcome',
              'threshold_spend_inr': 15000,
              'reward_value_inr': 500,
              'is_repeatable': false,
              'period': 'annual',
              'anchor': 'card_anniversary',
              'reward_points': 2000,
              'reward_kind': 'points',
              'excluded_category_ids': ['cat-fuel'],
              'window_days': 90,
              'source_local_id': 'welcome',
            },
          ],
          'unlock_rules': [
            {
              'id': 'u1',
              'card_benefit_id': 'b1',
              'kind': 'tier',
              'label': 'Gold tier',
              'spend_threshold_inr': 750000,
              'spend_window': 'card_year',
              'window_days': null,
              'unlocks_quota': null,
              'unlocks_period': null,
              'tier_label': 'Gold',
              'excluded_category_ids': ['cat-rent'],
              'notes': 'Tier upgrade',
              'source_local_id': 'tier-gold',
            },
          ],
          'redemption_options': [
            {
              'id': 'ro1',
              'program_name': 'Air miles',
              'method': 'airmiles_transfer',
              'value_per_point_inr': 0.5,
              'min_points': 1000,
            },
          ],
        },
      );
      final first = CardProductJson.fromJson(wire);
      expect(first.parseWarnings, isEmpty);
      final second = CardProductJson.fromJson(
        jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>,
      );

      expect(second.isV2Shaped, isTrue);
      expect(second.accrualBlockInr, 150);
      expect(second.accrualRounding, AccrualRounding.none);
      expect(second.cashbackRounding, CashbackRounding.rupeeHalfUp);
      expect(second.pointsExpiryMonths, 24);
      expect(second.modelStatus, ModelStatus.partial);
      expect(second.modelCoverage['rules_total'], 4);
      expect(second.modelCoverage['flags'], [
        {'code': 'unrestricted_accelerator'},
      ]);

      final r1 = second.rewardRules.firstWhere((r) => r.id == 'r1');
      expect(r1.role, RuleRole.earn);
      expect(r1.merchantSlugs, ['swiggy', 'zomato']);
      expect(r1.platformSlugs, ['phonepe_app']);
      expect(r1.mccInclude, ['5812']);
      expect(r1.mccExclude, ['5813']);
      expect(r1.blockInr, 150);
      expect(r1.minEngineVersion, 2);
      expect(r1.sourceLocalId, 'food-10x');
      expect(r1.displayNote, '10 pts/₹150 on food apps');
      expect(second.rewardRules.map((r) => r.role), [
        RuleRole.earn,
        RuleRole.exclusion,
        RuleRole.info,
        RuleRole.base,
      ]);

      final c1 = second.capRules.firstWhere((c) => c.id == 'c1');
      expect(c1.capKind, CapKind.bonusPoints);
      expect(c1.capAmount, 1500);
      expect(c1.scope, CapScope.targets);
      expect(c1.targets, ['r1']);
      expect(c1.parentCapId, 'c2');
      expect(c1.postCapBehavior, PostCapBehavior.customRate);
      expect(c1.anchor, PeriodAnchor.cardAnniversary);
      expect(c1.minEngineVersion, 2);
      expect(c1.sourceLocalId, 'food-cap');
      final c2 = second.capRules.firstWhere((c) => c.id == 'c2');
      expect(c2.capKind, CapKind.totalPoints);
      expect(c2.capAmount, 5000);
      expect(c2.scope, CapScope.card);

      final m1 = second.milestoneRules.single;
      expect(m1.period, CapPeriod.annual);
      expect(m1.anchor, PeriodAnchor.cardAnniversary);
      expect(m1.rewardPoints, 2000);
      expect(m1.rewardKind, MilestoneRewardKind.points);
      expect(m1.excludedCategoryIds, ['cat-fuel']);
      expect(m1.windowDays, 90);
      expect(m1.sourceLocalId, 'welcome');

      final u1 = second.unlockRules.single;
      expect(u1.cardBenefitId, 'b1');
      expect(u1.kind, UnlockKind.tier);
      expect(u1.spendThreshold, Money.fromRupees(750000));
      expect(u1.spendWindow, UnlockSpendWindow.cardYear);
      expect(u1.tierLabel, 'Gold');
      expect(u1.excludedCategoryIds, ['cat-rent']);
      expect(u1.notes, 'Tier upgrade');
      expect(u1.sourceLocalId, 'tier-gold');

      final ro = second.redemptionOptions.single;
      expect(ro.id, 'ro1');
      expect(ro.programName, 'Air miles');
      expect(ro.method, 'airmiles_transfer');
      expect(ro.valuePerPointInr, 0.5);
      expect(ro.minPoints, 1000);

      // A second round trip is a fixed point.
      expect(jsonEncode(second.toJson()), jsonEncode(first.toJson()));
    });
  });

  group('C8/D1 identity keys', () {
    const v1Rule = RewardRule(
      id: 'r1',
      categoryId: 'c1',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
      priority: 10,
    );

    test('a v1 rule, cap and milestone keep their pre-v2 keys', () {
      expect(rewardRuleIdentityKey(v1Rule), 'c1|||cashbackPercent|5.0||||||10');
      final cap = CapRule(
        id: 'k1',
        rewardRuleId: 'r1',
        label: 'Monthly',
        capValue: Money.fromRupees(500),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
      );
      expect(
        capRuleIdentityKey(cap),
        'r1||monthly|spendAmount|calendarMonth|50000||',
      );
      final milestone = MilestoneRule(
        id: 'm1',
        label: 'Spend 1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      expect(
        milestoneRuleIdentityKey(milestone),
        'spend 1l|10000000|100000|false',
      );
    });

    test('source_local_id and display_note are not identity', () {
      const a = RewardRule(
        id: 'a',
        unit: RewardUnit.pointsPer100,
        rate: 10,
        role: RuleRole.earn,
        platformSlugs: ['phonepe_app'],
        sourceLocalId: 'x',
        displayNote: 'one',
      );
      const b = RewardRule(
        id: 'b',
        unit: RewardUnit.pointsPer100,
        rate: 10,
        role: RuleRole.earn,
        platformSlugs: ['phonepe_app'],
        sourceLocalId: 'y',
        displayNote: 'two',
      );
      expect(uniqueRewardRules([a, b]).map((r) => r.id), ['a']);
    });

    test('two v2 rules that differ only in merchant_slugs both survive', () {
      final card = CardProductJson.fromJson(
        _card(
          rules: [
            _rule('swiggy-10', {
              'rule_role': 'earn',
              'merchant_slugs': ['swiggy'],
            }),
            _rule('zomato-10', {
              'rule_role': 'earn',
              'merchant_slugs': ['zomato'],
            }),
          ],
        ),
      );
      expect(card.rewardRules.map((r) => r.id), ['swiggy-10', 'zomato-10']);
    });

    test('rules differing only in another v2 identity field all survive', () {
      final rules = [
        const RewardRule(id: 'base', unit: RewardUnit.pointsPer100, rate: 5),
        const RewardRule(
          id: 'role',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          role: RuleRole.info,
        ),
        const RewardRule(
          id: 'platform',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          platformSlugs: ['phonepe_app'],
        ),
        const RewardRule(
          id: 'mccIn',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          mccInclude: ['5411'],
        ),
        const RewardRule(
          id: 'mccOut',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          mccExclude: ['5411'],
        ),
        const RewardRule(
          id: 'block',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          blockInr: 150,
        ),
        const RewardRule(
          id: 'engine',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          minEngineVersion: 2,
        ),
      ];
      expect(uniqueRewardRules(rules), hasLength(rules.length));
    });

    test('caps differing only in a v2 identity field all survive', () {
      CapRule cap(
        String id, {
        CapKind? kind,
        double? amount,
        CapScope scope = CapScope.targets,
        List<String> targets = const [],
        String? parent,
        PostCapBehavior? post,
        PeriodAnchor? anchor,
        int engine = 1,
      }) => CapRule(
        id: id,
        label: 'Same label',
        capValue: Money.fromRupees(375),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.calendarMonth,
        capKind: kind,
        capAmount: amount,
        scope: scope,
        targets: targets,
        parentCapId: parent,
        postCapBehavior: post,
        anchor: anchor,
        minEngineVersion: engine,
      );
      final caps = [
        cap('legacy'),
        cap('bonus', kind: CapKind.bonusPoints, amount: 1500),
        cap('total', kind: CapKind.totalPoints, amount: 1500),
        cap('amount', kind: CapKind.bonusPoints, amount: 1000),
        cap(
          'scope',
          kind: CapKind.bonusPoints,
          amount: 1500,
          scope: CapScope.card,
        ),
        cap(
          'targetsA',
          kind: CapKind.bonusPoints,
          amount: 1500,
          targets: ['a'],
        ),
        cap(
          'targetsB',
          kind: CapKind.bonusPoints,
          amount: 1500,
          targets: ['b'],
        ),
        cap('parent', kind: CapKind.bonusPoints, amount: 1500, parent: 'x'),
        cap('post', post: PostCapBehavior.zero),
        cap('anchor', anchor: PeriodAnchor.calendarYear),
        cap('engine', engine: 2),
      ];
      expect(uniqueCapRules(caps), hasLength(caps.length));
    });

    test('cap targets are compared as a set', () {
      CapRule cap(String id, List<String> targets) => CapRule(
        id: id,
        label: 'L',
        capValue: Money.fromRupees(1),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.calendarMonth,
        capKind: CapKind.bonusPoints,
        capAmount: 4,
        targets: targets,
      );
      expect(
        uniqueCapRules([
          cap('a', ['r1', 'r2']),
          cap('b', ['r2', 'r1']),
        ]),
        hasLength(1),
      );
    });

    test('milestones differing only in a v2 identity field all survive', () {
      MilestoneRule m(
        String id, {
        double? points,
        MilestoneRewardKind? kind,
        int? window,
        List<String> excluded = const [],
      }) => MilestoneRule(
        id: id,
        label: 'Spend 1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
        rewardPoints: points,
        rewardKind: kind,
        windowDays: window,
        excludedCategoryIds: excluded,
      );
      final ms = [
        m('plain'),
        m('points', points: 4000),
        m('kind', kind: MilestoneRewardKind.voucher),
        m('window', window: 90),
        m('excluded', excluded: ['cat-fuel']),
      ];
      expect(uniqueMilestoneRules(ms), hasLength(ms.length));
    });
  });
}
