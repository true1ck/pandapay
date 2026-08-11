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

/// Inverse of [_camelFromSnake] — used only by the offline-cache toJson
/// methods below (docs/superpowers/plans/2026-08-08-offline-first-local-cache.md)
/// to serialize an enum's .name back to the snake_case shape fromJson
/// expects, so a cached blob decodes through the SAME unmodified fromJson
/// parsers used for a live fetch.
String _snakeFromCamel(String camel) {
  final buffer = StringBuffer();
  for (final rune in camel.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == ch.toUpperCase() && ch != ch.toLowerCase()) {
      buffer
        ..write('_')
        ..write(ch.toLowerCase());
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'category_id': categoryId,
        'merchant_pattern': merchantPattern,
        'rail': rail == null ? null : _snakeFromCamel(rail!.name),
        'unit': _snakeFromCamel(unit.name),
        'rate': rate,
        'min_txn_inr': minTxn?.rupees,
        'max_txn_inr': maxTxn?.rupees,
        'priority': priority,
      };
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'reward_rule_id': rewardRuleId,
        'category_id': categoryId,
        'label': label,
        'cap_value': capValue.rupees,
        'measure': _snakeFromCamel(measure.name),
        'post_cap_unit': postCapUnit == null ? null : _snakeFromCamel(postCapUnit!.name),
        'post_cap_rate': postCapRate,
        'period': _snakeFromCamel(period.name),
      };
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'threshold_spend_inr': thresholdSpend.rupees,
        'reward_value_inr': rewardValue.rupees,
        'is_repeatable': isRepeatable,
      };
}

extension ForexRuleJson on ForexRule {
  static ForexRule fromJson(Map<String, dynamic> json) {
    return ForexRule(
      markupPercent: _num(json['markup_percent']),
      gstOnMarkup: json['gst_on_markup'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'markup_percent': markupPercent,
        'gst_on_markup': gstOnMarkup,
      };
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

  Map<String, dynamic> toJson() => {
        'surcharge_percent': surchargePercent,
        'waiver_percent': waiverPercent,
        'min_txn_inr': minTxn?.rupees,
        'max_txn_inr': maxTxn?.rupees,
      };
}

/// Mirrors `benefit_kind` (database.sql) — Postgres enum values are already
/// snake_case, same `_camelFromSnake` bridge every other enum here uses.
BenefitKind _parseBenefitKind(String value) =>
    BenefitKind.values.firstWhere((k) => k.name == _camelFromSnake(value), orElse: () => BenefitKind.other);

extension FeeWaiverRuleJson on FeeWaiverRule {
  static FeeWaiverRule fromJson(Map<String, dynamic> json) {
    return FeeWaiverRule(
      id: json['id'] as String,
      thresholdSpend: _moneyFromRupees(json['threshold_spend_inr']),
      period: _parseCapPeriod(json['period'] as String),
      waivesFee: _moneyFromRupees(json['waives_fee_inr']),
      excludedCategoryIds: ((json['excluded_categories'] as List?) ?? const []).cast<String>(),
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'threshold_spend_inr': thresholdSpend.rupees,
        'period': _snakeFromCamel(period.name),
        'waives_fee_inr': waivesFee.rupees,
        'excluded_categories': excludedCategoryIds,
        'notes': notes,
      };
}

extension CardBenefitJson on CardBenefit {
  static CardBenefit fromJson(Map<String, dynamic> json) {
    return CardBenefit(
      id: json['id'] as String,
      kind: _parseBenefitKind(json['kind'] as String),
      label: json['label'] as String,
      description: json['description'] as String?,
      quotaCount: (json['quota_count'] as num?)?.toInt(),
      quotaPeriod: json['quota_period'] != null ? _parseCapPeriod(json['quota_period'] as String) : null,
      networkProgram: json['network_program'] as String?,
      valueEstimate: _moneyOrNull(json['value_estimate_inr']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': _snakeFromCamel(kind.name),
        'label': label,
        'description': description,
        'quota_count': quotaCount,
        'quota_period': quotaPeriod == null ? null : _snakeFromCamel(quotaPeriod!.name),
        'network_program': networkProgram,
        'value_estimate_inr': valueEstimate?.rupees,
      };
}

extension CardProductJson on CardProduct {
  static CardProduct fromJson(Map<String, dynamic> json) {
    return CardProduct(
      id: json['id'] as String,
      name: json['name'] as String,
      network: _parseNetwork(json['network'] as String),
      isUpiLinkable: json['is_upi_linkable'] as bool? ?? false,
      pointValueInr: _numOrNull(json['point_value_inr']) ?? 0,
      // The catalogue's everything-else rate. Both halves must be present
      // for it to mean anything — a rate with no unit isn't a rate.
      baseRewardUnit: json['base_reward_unit'] == null
          ? null
          : _parseRewardUnit(json['base_reward_unit'] as String),
      baseRewardRate: _numOrNull(json['base_reward_rate']),
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
      feeWaiverRules: ((json['fee_waiver_rules'] as List?) ?? const [])
          .map((e) => FeeWaiverRuleJson.fromJson(e as Map<String, dynamic>))
          .toList(),
      benefits: ((json['benefits'] as List?) ?? const [])
          .map((e) => CardBenefitJson.fromJson(e as Map<String, dynamic>))
          .toList(),
      annualFeeInr: _moneyOrNull(json['annual_fee_inr']),
      joiningFeeInr: _moneyOrNull(json['joining_fee_inr']),
      verifiedAt: json['verified_at'] == null ? null : DateTime.parse(json['verified_at'] as String),
      issuerName: json['issuer_name'] as String?,
      artAssetUrl: json['art_asset'] as String?,
      artPrimaryColor: json['art_primary_color'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'network': network.name,
        'is_upi_linkable': isUpiLinkable,
        'point_value_inr': pointValueInr,
        'base_reward_unit': baseRewardUnit == null ? null : _snakeFromCamel(baseRewardUnit!.name),
        'base_reward_rate': baseRewardRate,
        'reward_rules': rewardRules.map((r) => r.toJson()).toList(),
        'cap_rules': capRules.map((r) => r.toJson()).toList(),
        'milestone_rules': milestoneRules.map((r) => r.toJson()).toList(),
        'forex': forexRule?.toJson(),
        'fuel': fuelRule?.toJson(),
        'fee_waiver_rules': feeWaiverRules.map((r) => r.toJson()).toList(),
        'benefits': benefits.map((b) => b.toJson()).toList(),
        'annual_fee_inr': annualFeeInr?.rupees,
        'joining_fee_inr': joiningFeeInr?.rupees,
        'verified_at': verifiedAt?.toIso8601String(),
        'issuer_name': issuerName,
        'art_asset': artAssetUrl,
        'art_primary_color': artPrimaryColor,
      };
}
