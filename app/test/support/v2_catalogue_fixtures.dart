import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Wire-shaped catalogue and wallet fixtures for the Card Rewards WP9 tests.
/// All values are synthetic: no real card, merchant or person.

/// A v1 card: no v2 field anywhere, one v1 cap (₹ reward value).
Map<String, dynamic> v1CardJson(
  String id, {
  String name = 'Plain Card',
  bool withCap = false,
}) => {
  'id': id,
  'name': name,
  'network': 'visa',
  'point_value_inr': 0.25,
  'base_reward_unit': 'points_per_100',
  'base_reward_rate': 1,
  'reward_rules': <Map<String, dynamic>>[],
  'cap_rules': [
    if (withCap)
      {
        'id': '$id-cap',
        'reward_rule_id': null,
        'category_id': null,
        'label': 'Monthly cap',
        'measure': 'reward_value',
        'period': 'calendar_month',
        'cap_value': 500,
        'post_cap_unit': null,
        'post_cap_rate': null,
      },
  ],
};

/// A v2 card: `accrual_rounding` set, one bonus-points cap (1,500 points a
/// month) on one dining rule, `model_status` as given.
Map<String, dynamic> v2CardJson(
  String id, {
  String name = 'Rewards Card',
  String modelStatus = 'partial',
  String capKind = 'bonus_points',
  num capAmount = 1500,
  Map<String, dynamic> capExtra = const {},
  String? categoryId,
}) => {
  'id': id,
  'name': name,
  'network': 'visa',
  'is_upi_linkable': true,
  'point_value_inr': 0.25,
  'base_reward_unit': 'points_per_100',
  'base_reward_rate': 1,
  'accrual_rounding': 'floor',
  'model_status': modelStatus,
  'reward_rules': [
    {
      'id': '$id-rule',
      'category_id': categoryId,
      'merchant_pattern': null,
      'rail': null,
      'unit': 'points_per_100',
      'rate': 5,
      'priority': 10,
      'rule_role': 'earn',
      'merchant_slugs': <String>[],
      'platform_slugs': <String>[],
      'mcc_include': <String>[],
      'mcc_exclude': <String>[],
      'min_engine_version': 2,
    },
  ],
  'cap_rules': [
    {
      'id': '$id-cap',
      'reward_rule_id': null,
      'category_id': categoryId,
      'label': 'Dining bonus cap',
      'measure': 'reward_value',
      'period': 'calendar_month',
      'cap_value': 375,
      'post_cap_unit': null,
      'post_cap_rate': null,
      'cap_kind': capKind,
      'cap_amount': capAmount,
      'scope': 'targets',
      'targets': ['$id-rule'],
      'min_engine_version': 2,
      ...capExtra,
    },
  ],
};

/// A card that cannot parse (an unknown v1 reward unit is strict).
Map<String, dynamic> badCardJson(String id, {String name = 'Secret Name'}) => {
  'id': id,
  'name': name,
  'network': 'visa',
  'base_reward_unit': 'not_a_unit',
  'base_reward_rate': 1,
};

Map<String, dynamic> v2Body(
  List<Map<String, dynamic>> cards, {
  List<Map<String, dynamic>>? merchants,
  List<Map<String, dynamic>>? platforms,
}) => {
  'schema': 2,
  'cards': cards,
  'merchants':
      merchants ??
      [
        {
          'slug': 'swiggy',
          'name': 'Swiggy',
          'parent_slug': null,
          'category_slug': 'dining',
          'aliases': ['swiggy'],
          'vpa_prefixes': ['swiggy'],
          'mcc': ['5814', '5812'],
        },
      ],
  'platforms':
      platforms ??
      [
        {
          'slug': 'phonepe_app',
          'name': 'PhonePe app',
          'kind': 'payment_app',
          'aliases': ['phonepe'],
        },
      ],
};

Map<String, dynamic> v1Body(List<Map<String, dynamic>> cards) => {
  'cards': cards,
};

/// A `GET /user-cards` `cap_states` row as WP8 serves it.
Map<String, dynamic> capStateRowJson(
  String capRuleId, {
  Object? consumed = 0,
  Object? consumedNative,
  String? capKind,
  Object? capAmount,
  Object? periodStart,
  Object? periodEnd,
  bool approximate = false,
}) => {
  'cap_rule_id': capRuleId,
  'consumed': consumed,
  'consumed_native': consumedNative,
  'cap_kind': capKind,
  'cap_amount': capAmount,
  'period_start': periodStart,
  'period_end': periodEnd,
  'approximate_window': approximate,
};

/// A `GET /user-cards` row.
Map<String, dynamic> userCardJson(
  String id,
  String productId, {
  List<Map<String, dynamic>> capStates = const [],
  String? nickname,
}) => {
  'id': id,
  'card_product_id': productId,
  'card_name': 'Wallet Card',
  'nickname': nickname,
  'is_default': false,
  'cap_states': capStates,
  'milestone_states': <Map<String, dynamic>>[],
  'fee_waiver_states': <Map<String, dynamic>>[],
};

CardProduct parseCard(Map<String, dynamic> json) =>
    CardProductJson.fromJson(json);

UserCard parseUserCard(Map<String, dynamic> json) => UserCard.fromJson(json);
