import 'card_rules.dart';
import '../money/money.dart';

/// Deserializers matching the exact shape of `v_card_catalogue_export`
/// (db/supabase/migrations/0010_functions_and_views.sql) — the device sync
/// contract. Verified against a live `GET /catalogue` response from api/
/// during development, not written from the view definition alone.
///
/// Postgres/pg returns `numeric` columns as JSON strings (e.g. "499.00")
/// but plain `int`/enum-backed columns as native JSON numbers/strings —
/// [_num] and [_moneyFromRupees] handle both shapes defensively.
double _num(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.parse(v as String);
}

double? _numOrNull(dynamic v) => v == null ? null : _num(v);

Money _moneyFromRupees(dynamic v) => Money.fromRupees(_num(v));

Money? _moneyOrNull(dynamic v) => v == null ? null : _moneyFromRupees(v);

RewardUnit _parseRewardUnit(String value) {
  return RewardUnit.values.firstWhere(
    (u) => u.name == _camelFromSnake(value),
    orElse: () => throw FormatException('Unknown reward unit: $value'),
  );
}

CardNetwork _parseNetwork(String value) => CardNetwork.values.byName(value);

TxnRail? _parseRailOrNull(String? value) {
  if (value == null) return null;
  return TxnRail.values.firstWhere(
    (r) => r.name == _camelFromSnake(value),
    orElse: () => TxnRail.unknown,
  );
}

CapPeriod _parseCapPeriod(String value) =>
    CapPeriod.values.firstWhere((p) => p.name == _camelFromSnake(value));

CapMeasure _parseCapMeasure(String value) =>
    CapMeasure.values.firstWhere((m) => m.name == _camelFromSnake(value));

String _camelFromSnake(String snake) {
  final parts = snake.split('_');
  return parts.first + parts.skip(1).map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join();
}

extension RewardRuleJson on RewardRule {
  static RewardRule fromJson(Map<String, dynamic> json) {
    return RewardRule(
      id: json['id'] as String,
      categoryId: json['category_id'] as String?,
      merchantPattern: json['merchant_pattern'] as String?,
      rail: _parseRailOrNull(json['rail'] as String?),
      unit: _parseRewardUnit(json['unit'] as String),
      rate: _num(json['rate']),
      minTxn: _moneyOrNull(json['min_txn_inr']),
      maxTxn: _moneyOrNull(json['max_txn_inr']),
      priority: (json['priority'] as num?)?.toInt() ?? 100,
    );
  }
}

extension CapRuleJson on CapRule {
  static CapRule fromJson(Map<String, dynamic> json) {
    return CapRule(
      id: json['id'] as String,
      rewardRuleId: json['reward_rule_id'] as String?,
      categoryId: json['category_id'] as String?,
      label: json['label'] as String,
      // cap_value is a plain numeric column regardless of measure — for
      // spend_amount/reward_value it's rupees, for txn_count it's a raw
      // transaction count encoded the same way (no separate DB type per
      // measure). _moneyFromRupees is just the numeric parse; engine.dart
      // reads .paise back out as a count when measure == txnCount rather
      // than treating it as currency.
      capValue: _moneyFromRupees(json['cap_value']),
      measure: _parseCapMeasure(json['measure'] as String),
      postCapUnit: json['post_cap_unit'] != null ? _parseRewardUnit(json['post_cap_unit'] as String) : null,
      postCapRate: _num(json['post_cap_rate']),
      period: _parseCapPeriod(json['period'] as String),
    );
  }
}

extension MilestoneRuleJson on MilestoneRule {
  static MilestoneRule fromJson(Map<String, dynamic> json) {
    return MilestoneRule(
      id: json['id'] as String,
      label: json['label'] as String,
      thresholdSpend: _moneyFromRupees(json['threshold_spend_inr']),
      rewardValue: _moneyFromRupees(json['reward_value_inr']),
      isRepeatable: json['is_repeatable'] as bool? ?? false,
    );
  }
}

extension ForexRuleJson on ForexRule {
  static ForexRule fromJson(Map<String, dynamic> json) {
    return ForexRule(
      markupPercent: _num(json['markup_percent']),
      gstOnMarkup: json['gst_on_markup'] as bool? ?? true,
    );
  }
}

extension FuelSurchargeRuleJson on FuelSurchargeRule {
  static FuelSurchargeRule fromJson(Map<String, dynamic> json) {
    return FuelSurchargeRule(
      surchargePercent: _num(json['surcharge_percent']),
      waiverPercent: _num(json['waiver_percent']),
      minTxn: _moneyOrNull(json['min_txn_inr']),
      maxTxn: _moneyOrNull(json['max_txn_inr']),
    );
  }
}

extension CardProductJson on CardProduct {
  static CardProduct fromJson(Map<String, dynamic> json) {
    return CardProduct(
      id: json['id'] as String,
      name: json['name'] as String,
      network: _parseNetwork(json['network'] as String),
      isUpiLinkable: json['is_upi_linkable'] as bool? ?? false,
      pointValueInr: _numOrNull(json['point_value_inr']) ?? 0,
      rewardRules: ((json['reward_rules'] as List?) ?? const [])
          .map((e) => RewardRuleJson.fromJson(e as Map<String, dynamic>))
          .toList(),
      capRules: ((json['cap_rules'] as List?) ?? const [])
          .map((e) => CapRuleJson.fromJson(e as Map<String, dynamic>))
          .toList(),
      milestoneRules: ((json['milestone_rules'] as List?) ?? const [])
          .map((e) => MilestoneRuleJson.fromJson(e as Map<String, dynamic>))
          .toList(),
      forexRule: json['forex'] != null ? ForexRuleJson.fromJson(json['forex'] as Map<String, dynamic>) : null,
      fuelRule: json['fuel'] != null ? FuelSurchargeRuleJson.fromJson(json['fuel'] as Map<String, dynamic>) : null,
    );
  }
}
