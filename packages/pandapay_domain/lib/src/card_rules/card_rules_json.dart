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

/// `effective_from`/`effective_to` are Postgres `date` columns, which pg
/// serializes as 'YYYY-MM-DD' — [DateTime.parse] handles that shape as well
/// as the full ISO-8601 timestamps other columns use. Unparseable values
/// resolve to null (= "no bound") rather than throwing: a malformed date in
/// one catalogue row must not take down the whole catalogue decode, and
/// "no bound" is the same behaviour as before these fields existed.
DateTime? _dateOrNull(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse(v as String);
}

/// Round-trips through the offline cache as a plain 'YYYY-MM-DD' date, the
/// same shape [_dateOrNull] reads from the wire.
String? _dateToJson(DateTime? v) => v == null
    ? null
    : '${v.year.toString().padLeft(4, '0')}-'
          '${v.month.toString().padLeft(2, '0')}-'
          '${v.day.toString().padLeft(2, '0')}';

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
  return parts.first +
      parts
          .skip(1)
          .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1))
          .join();
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

// ---------------------------------------------------------------------------
// v2 fields (plan C1/C2). Parsed TOLERANTLY: a bad value in a v2-only field
// throws [CatalogueV2FieldException], which [CardProductJson.fromJson]
// catches to skip just that rule/cap/milestone (with a warning) — never the
// card. v1 fields keep their original strict parsers.
// ---------------------------------------------------------------------------

/// A v2-only catalogue field held a value this package doesn't understand
/// (an unknown enum value, a wrong type, or a newer `min_engine_version`).
/// A [FormatException], so callers that already catch those keep working.
class CatalogueV2FieldException extends FormatException {
  final String field;
  final Object? value;

  CatalogueV2FieldException(this.field, this.value, [String? detail])
    : super(detail ?? 'Unsupported value for v2 field $field: $value');
}

T _v2Enum<T extends Enum>(List<T> values, Object? raw, String field) {
  if (raw is String) {
    final name = _camelFromSnake(raw);
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  throw CatalogueV2FieldException(field, raw);
}

T? _v2EnumOrNull<T extends Enum>(List<T> values, Object? raw, String field) =>
    raw == null ? null : _v2Enum(values, raw, field);

String _v2EnumToJson(Enum value) => _snakeFromCamel(value.name);

/// A text[] column. Null/absent is the empty default. Elements are taken
/// as strings (an MCC sent as a JSON number still reads as its digits).
List<String> _v2StringList(Object? raw, String field) {
  if (raw == null) return const [];
  if (raw is! List) throw CatalogueV2FieldException(field, raw);
  return [
    for (final e in raw)
      if (e == null)
        throw CatalogueV2FieldException(field, raw)
      else
        e is String ? e : e.toString(),
  ];
}

double? _v2NumOrNull(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null) return parsed;
  }
  throw CatalogueV2FieldException(field, raw);
}

int? _v2IntOrNull(Object? raw, String field) {
  final value = _v2NumOrNull(raw, field);
  if (value == null) return null;
  if (value != value.roundToDouble()) {
    throw CatalogueV2FieldException(field, raw);
  }
  return value.toInt();
}

String? _v2StringOrNull(Object? raw, String field) {
  if (raw == null || raw is String) return raw as String?;
  throw CatalogueV2FieldException(field, raw);
}

int _v2EngineVersion(Object? raw) {
  final version = _v2IntOrNull(raw, 'min_engine_version') ?? 1;
  if (version > kRewardEngineVersion) {
    throw CatalogueV2FieldException(
      'min_engine_version',
      raw,
      'Needs reward engine v$version; this build supports v$kRewardEngineVersion',
    );
  }
  return version;
}

/// Tolerant parse of a v1 enum that is optional on the wire (milestone
/// `period`/`anchor`): an unrecognised value reads as null, as before these
/// fields were modelled at all.
T? _enumOrNullLenient<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  final name = _camelFromSnake(raw);
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
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
      excludedCategoryIds: ((json['excluded_categories'] as List?) ?? const [])
          .cast<String>(),
      effectiveFrom: _dateOrNull(json['effective_from']),
      effectiveTo: _dateOrNull(json['effective_to']),
      priority: (json['priority'] as num?)?.toInt() ?? 100,
      role: _v2EnumOrNull(RuleRole.values, json['rule_role'], 'rule_role'),
      merchantSlugs: _v2StringList(json['merchant_slugs'], 'merchant_slugs'),
      platformSlugs: _v2StringList(json['platform_slugs'], 'platform_slugs'),
      mccInclude: _v2StringList(json['mcc_include'], 'mcc_include'),
      mccExclude: _v2StringList(json['mcc_exclude'], 'mcc_exclude'),
      blockInr: _v2IntOrNull(json['block_inr'], 'block_inr'),
      minEngineVersion: _v2EngineVersion(json['min_engine_version']),
      sourceLocalId: _v2StringOrNull(
        json['source_local_id'],
        'source_local_id',
      ),
      displayNote: _v2StringOrNull(json['display_note'], 'display_note'),
    );
  }

  /// v2 keys are written only when they differ from their v1 default, so a
  /// v1 rule serializes exactly as it did before v2.
  Map<String, dynamic> toJson() => {
    'id': id,
    'category_id': categoryId,
    'merchant_pattern': merchantPattern,
    'rail': rail == null ? null : _snakeFromCamel(rail!.name),
    'unit': _snakeFromCamel(unit.name),
    'rate': rate,
    'min_txn_inr': minTxn?.rupees,
    'max_txn_inr': maxTxn?.rupees,
    'excluded_categories': excludedCategoryIds,
    'effective_from': _dateToJson(effectiveFrom),
    'effective_to': _dateToJson(effectiveTo),
    'priority': priority,
    if (role != null) 'rule_role': _v2EnumToJson(role!),
    if (merchantSlugs.isNotEmpty) 'merchant_slugs': merchantSlugs,
    if (platformSlugs.isNotEmpty) 'platform_slugs': platformSlugs,
    if (mccInclude.isNotEmpty) 'mcc_include': mccInclude,
    if (mccExclude.isNotEmpty) 'mcc_exclude': mccExclude,
    if (blockInr != null) 'block_inr': blockInr,
    if (minEngineVersion != 1) 'min_engine_version': minEngineVersion,
    if (sourceLocalId != null) 'source_local_id': sourceLocalId,
    if (displayNote != null) 'display_note': displayNote,
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
      postCapUnit: json['post_cap_unit'] != null
          ? _parseRewardUnit(json['post_cap_unit'] as String)
          : null,
      // _numOrNull, not _num: null must survive as null so the engine can
      // tell "catalogue doesn't say, fall back to the card's base rate"
      // from an explicit "this card pays nothing past the cap". See
      // CapRule.postCapRate.
      postCapRate: _numOrNull(json['post_cap_rate']),
      period: _parseCapPeriod(json['period'] as String),
      capKind: _v2EnumOrNull(CapKind.values, json['cap_kind'], 'cap_kind'),
      capAmount: _v2NumOrNull(json['cap_amount'], 'cap_amount'),
      scope:
          _v2EnumOrNull(CapScope.values, json['scope'], 'scope') ??
          CapScope.targets,
      targets: _v2StringList(json['targets'], 'targets'),
      parentCapId: _v2StringOrNull(json['parent_cap_id'], 'parent_cap_id'),
      postCapBehavior: _v2EnumOrNull(
        PostCapBehavior.values,
        json['post_cap_behavior'],
        'post_cap_behavior',
      ),
      anchor: _v2EnumOrNull(PeriodAnchor.values, json['anchor'], 'anchor'),
      minEngineVersion: _v2EngineVersion(json['min_engine_version']),
      sourceLocalId: _v2StringOrNull(
        json['source_local_id'],
        'source_local_id',
      ),
    );
  }

  /// v2 keys are written only when they differ from their v1 default.
  Map<String, dynamic> toJson() => {
    'id': id,
    'reward_rule_id': rewardRuleId,
    'category_id': categoryId,
    'label': label,
    'cap_value': capValue.rupees,
    'measure': _snakeFromCamel(measure.name),
    'post_cap_unit': postCapUnit == null
        ? null
        : _snakeFromCamel(postCapUnit!.name),
    'post_cap_rate': postCapRate,
    'period': _snakeFromCamel(period.name),
    if (capKind != null) 'cap_kind': _v2EnumToJson(capKind!),
    if (capAmount != null) 'cap_amount': capAmount,
    if (scope != CapScope.targets) 'scope': _v2EnumToJson(scope),
    if (targets.isNotEmpty) 'targets': targets,
    if (parentCapId != null) 'parent_cap_id': parentCapId,
    if (postCapBehavior != null)
      'post_cap_behavior': _v2EnumToJson(postCapBehavior!),
    if (anchor != null) 'anchor': _v2EnumToJson(anchor!),
    if (minEngineVersion != 1) 'min_engine_version': minEngineVersion,
    if (sourceLocalId != null) 'source_local_id': sourceLocalId,
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
      period: _enumOrNullLenient(CapPeriod.values, json['period']),
      anchor: _enumOrNullLenient(PeriodAnchor.values, json['anchor']),
      rewardPoints: _v2NumOrNull(json['reward_points'], 'reward_points'),
      rewardKind: _v2EnumOrNull(
        MilestoneRewardKind.values,
        json['reward_kind'],
        'reward_kind',
      ),
      excludedCategoryIds: _v2StringList(
        json['excluded_category_ids'],
        'excluded_category_ids',
      ),
      windowDays: _v2IntOrNull(json['window_days'], 'window_days'),
      sourceLocalId: _v2StringOrNull(
        json['source_local_id'],
        'source_local_id',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'threshold_spend_inr': thresholdSpend.rupees,
    'reward_value_inr': rewardValue.rupees,
    'is_repeatable': isRepeatable,
    if (period != null) 'period': _v2EnumToJson(period!),
    if (anchor != null) 'anchor': _v2EnumToJson(anchor!),
    if (rewardPoints != null) 'reward_points': rewardPoints,
    if (rewardKind != null) 'reward_kind': _v2EnumToJson(rewardKind!),
    if (excludedCategoryIds.isNotEmpty)
      'excluded_category_ids': excludedCategoryIds,
    if (windowDays != null) 'window_days': windowDays,
    if (sourceLocalId != null) 'source_local_id': sourceLocalId,
  };
}

extension BenefitUnlockRuleJson on BenefitUnlockRule {
  /// Unlock rules are v2-only, so every field here is parsed tolerantly:
  /// anything malformed throws [CatalogueV2FieldException] and the card
  /// parser skips just this row.
  static BenefitUnlockRule fromJson(Map<String, dynamic> json) {
    final id = _v2StringOrNull(json['id'], 'unlock_rules.id');
    final label = _v2StringOrNull(json['label'], 'unlock_rules.label');
    final threshold = _v2NumOrNull(
      json['spend_threshold_inr'],
      'spend_threshold_inr',
    );
    if (id == null) throw CatalogueV2FieldException('unlock_rules.id', null);
    if (label == null) {
      throw CatalogueV2FieldException('unlock_rules.label', null);
    }
    if (threshold == null) {
      throw CatalogueV2FieldException('spend_threshold_inr', null);
    }
    return BenefitUnlockRule(
      id: id,
      cardBenefitId: _v2StringOrNull(
        json['card_benefit_id'],
        'card_benefit_id',
      ),
      kind: _v2Enum(UnlockKind.values, json['kind'], 'unlock_rules.kind'),
      label: label,
      spendThreshold: Money.fromRupees(threshold),
      spendWindow: _v2Enum(
        UnlockSpendWindow.values,
        json['spend_window'],
        'spend_window',
      ),
      windowDays: _v2IntOrNull(json['window_days'], 'window_days'),
      unlocksQuota: _v2IntOrNull(json['unlocks_quota'], 'unlocks_quota'),
      unlocksPeriod: _v2EnumOrNull(
        CapPeriod.values,
        json['unlocks_period'],
        'unlocks_period',
      ),
      tierLabel: _v2StringOrNull(json['tier_label'], 'tier_label'),
      excludedCategoryIds: _v2StringList(
        json['excluded_category_ids'],
        'excluded_category_ids',
      ),
      notes: _v2StringOrNull(json['notes'], 'notes'),
      sourceLocalId: _v2StringOrNull(
        json['source_local_id'],
        'source_local_id',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'card_benefit_id': cardBenefitId,
    'kind': _v2EnumToJson(kind),
    'label': label,
    'spend_threshold_inr': spendThreshold.rupees,
    'spend_window': _v2EnumToJson(spendWindow),
    'window_days': windowDays,
    'unlocks_quota': unlocksQuota,
    'unlocks_period': unlocksPeriod == null
        ? null
        : _v2EnumToJson(unlocksPeriod!),
    'tier_label': tierLabel,
    'excluded_category_ids': excludedCategoryIds,
    'notes': notes,
    'source_local_id': sourceLocalId,
  };
}

extension RedemptionOptionJson on RedemptionOption {
  /// Tolerant like [BenefitUnlockRuleJson.fromJson]; `method` is free text.
  static RedemptionOption fromJson(Map<String, dynamic> json) {
    final program = _v2StringOrNull(json['program_name'], 'program_name');
    final method = _v2StringOrNull(json['method'], 'method');
    final value = _v2NumOrNull(
      json['value_per_point_inr'],
      'value_per_point_inr',
    );
    if (program == null) throw CatalogueV2FieldException('program_name', null);
    if (method == null) throw CatalogueV2FieldException('method', null);
    if (value == null) {
      throw CatalogueV2FieldException('value_per_point_inr', null);
    }
    return RedemptionOption(
      id: _v2StringOrNull(json['id'], 'redemption_options.id'),
      programName: program,
      method: method,
      valuePerPointInr: value,
      minPoints: _v2IntOrNull(json['min_points'], 'min_points'),
      notes: _v2StringOrNull(json['notes'], 'notes'),
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'program_name': programName,
    'method': method,
    'value_per_point_inr': valuePerPointInr,
    'min_points': minPoints,
    if (notes != null) 'notes': notes,
  };
}

/// Parses each row with [parse]; a row whose v2 fields are unsupported is
/// skipped and described in [warnings]. Any other error propagates (v1
/// fields stay strict). [onV2Marker] is told when a skipped row carried a
/// C3.2 v2 marker, so the card is still treated as v2-shaped.
List<T> _parseRowsTolerantly<T>(
  Object? raw,
  String table,
  T Function(Map<String, dynamic>) parse,
  List<String> warnings, {
  bool Function(Map<String, dynamic>)? isV2Marker,
  void Function()? onV2Marker,
  bool skipAnyFormatError = false,
}) {
  final rows = (raw as List?) ?? const [];
  final out = <T>[];
  for (final row in rows) {
    final json = row as Map<String, dynamic>;
    try {
      out.add(parse(json));
    } on FormatException catch (e) {
      if (e is! CatalogueV2FieldException && !skipAnyFormatError) rethrow;
      warnings.add('$table ${json['id'] ?? '?'} skipped: ${e.message}');
      if (isV2Marker != null && isV2Marker(json)) onV2Marker?.call();
    } on TypeError catch (e) {
      if (!skipAnyFormatError) rethrow;
      warnings.add('$table ${json['id'] ?? '?'} skipped: $e');
    }
  }
  return out;
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
BenefitKind _parseBenefitKind(String value) => BenefitKind.values.firstWhere(
  (k) => k.name == _camelFromSnake(value),
  orElse: () => BenefitKind.other,
);

extension FeeWaiverRuleJson on FeeWaiverRule {
  static FeeWaiverRule fromJson(Map<String, dynamic> json) {
    return FeeWaiverRule(
      id: json['id'] as String,
      thresholdSpend: _moneyFromRupees(json['threshold_spend_inr']),
      period: _parseCapPeriod(json['period'] as String),
      waivesFee: _moneyFromRupees(json['waives_fee_inr']),
      excludedCategoryIds: ((json['excluded_categories'] as List?) ?? const [])
          .cast<String>(),
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
      quotaPeriod: json['quota_period'] != null
          ? _parseCapPeriod(json['quota_period'] as String)
          : null,
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
    'quota_period': quotaPeriod == null
        ? null
        : _snakeFromCamel(quotaPeriod!.name),
    'network_program': networkProgram,
    'value_estimate_inr': valueEstimate?.rupees,
  };
}

extension CardProductJson on CardProduct {
  /// Parses one card from either feed (plan C2).
  ///
  /// v1 fields are as strict as ever. v2 fields are tolerant: a rule, cap or
  /// milestone with an unsupported v2 value is skipped, an unlock rule or
  /// redemption option that doesn't parse is skipped, and an unsupported
  /// card-level v2 value falls back to its default — each recorded in
  /// [CardProduct.parseWarnings]. A v2 problem never fails the card.
  static CardProduct fromJson(Map<String, dynamic> json) {
    final warnings = <String>[];
    var wireV2 = false;
    void markV2() => wireV2 = true;

    final rewardRules = _parseRowsTolerantly(
      json['reward_rules'],
      'reward_rule',
      RewardRuleJson.fromJson,
      warnings,
      isV2Marker: (r) => r['rule_role'] != null,
      onV2Marker: markV2,
    );
    final capRules = _parseRowsTolerantly(
      json['cap_rules'],
      'cap_rule',
      CapRuleJson.fromJson,
      warnings,
      isV2Marker: (c) => c['cap_kind'] != null,
      onV2Marker: markV2,
    );
    final milestoneRules = _parseRowsTolerantly(
      json['milestone_rules'],
      'milestone_rule',
      MilestoneRuleJson.fromJson,
      warnings,
    );
    final unlockRules = _parseRowsTolerantly(
      json['unlock_rules'],
      'unlock_rule',
      BenefitUnlockRuleJson.fromJson,
      warnings,
      skipAnyFormatError: true,
    );
    final redemptionOptions = _parseRowsTolerantly(
      json['redemption_options'],
      'redemption_option',
      RedemptionOptionJson.fromJson,
      warnings,
      skipAnyFormatError: true,
    );

    T? cardField<T>(String key, T? Function() parse, {T? fallback}) {
      try {
        return parse();
      } on CatalogueV2FieldException catch (e) {
        warnings.add('card $key defaulted: ${e.message}');
        return fallback;
      }
    }

    // An unsupported rounding mode still marks the card v2 and falls back
    // to floor, the v2 default and the mode that never over-states points.
    final accrualRounding = cardField(
      'accrual_rounding',
      () => _v2EnumOrNull(
        AccrualRounding.values,
        json['accrual_rounding'],
        'accrual_rounding',
      ),
      fallback: AccrualRounding.floor,
    );
    final coverageRaw = json['model_coverage'];
    final modelCoverage = coverageRaw is Map<String, dynamic>
        ? coverageRaw
        : const <String, dynamic>{};
    if (coverageRaw != null && coverageRaw is! Map<String, dynamic>) {
      warnings.add('card model_coverage ignored: not an object');
    }

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
      excludedCategoryIds: ((json['excluded_categories'] as List?) ?? const [])
          .cast<String>(),
      rewardRules: uniqueRewardRules(rewardRules),
      capRules: uniqueCapRules(capRules),
      milestoneRules: uniqueMilestoneRules(milestoneRules),
      forexRule: json['forex'] != null
          ? ForexRuleJson.fromJson(json['forex'] as Map<String, dynamic>)
          : null,
      fuelRule: json['fuel'] != null
          ? FuelSurchargeRuleJson.fromJson(json['fuel'] as Map<String, dynamic>)
          : null,
      feeWaiverRules: uniqueFeeWaiverRules(
        ((json['fee_waiver_rules'] as List?) ?? const []).map(
          (e) => FeeWaiverRuleJson.fromJson(e as Map<String, dynamic>),
        ),
      ),
      benefits: uniqueCardBenefits(
        ((json['benefits'] as List?) ?? const []).map(
          (e) => CardBenefitJson.fromJson(e as Map<String, dynamic>),
        ),
      ),
      annualFeeInr: _moneyOrNull(json['annual_fee_inr']),
      joiningFeeInr: _moneyOrNull(json['joining_fee_inr']),
      verifiedAt: json['verified_at'] == null
          ? null
          : DateTime.parse(json['verified_at'] as String),
      issuerName: json['issuer_name'] as String?,
      cardType: json['card_type'] as String?,
      artAssetUrl: json['art_asset'] as String?,
      artPrimaryColor: json['art_primary_color'] as String?,
      hasApplyUrl: json['has_apply_url'] == true,
      accrualBlockInr: cardField(
        'accrual_block_inr',
        () => _v2IntOrNull(json['accrual_block_inr'], 'accrual_block_inr'),
      ),
      accrualRounding: accrualRounding,
      pointsExpiryMonths: cardField(
        'points_expiry_months',
        () =>
            _v2IntOrNull(json['points_expiry_months'], 'points_expiry_months'),
      ),
      modelStatus: cardField(
        'model_status',
        () => _v2EnumOrNull(
          ModelStatus.values,
          json['model_status'],
          'model_status',
        ),
      ),
      modelCoverage: modelCoverage,
      unlockRules: unlockRules,
      redemptionOptions: redemptionOptions,
      parseWarnings: List.unmodifiable(warnings),
      wireV2Shaped: wireV2,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'network': network.name,
    'is_upi_linkable': isUpiLinkable,
    'point_value_inr': pointValueInr,
    'base_reward_unit': baseRewardUnit == null
        ? null
        : _snakeFromCamel(baseRewardUnit!.name),
    'base_reward_rate': baseRewardRate,
    'excluded_categories': excludedCategoryIds,
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
    'card_type': cardType,
    'art_asset': artAssetUrl,
    'art_primary_color': artPrimaryColor,
    'has_apply_url': hasApplyUrl,
    // v2 keys only when set, so a v1 card's cache blob is unchanged.
    if (accrualBlockInr != null) 'accrual_block_inr': accrualBlockInr,
    if (accrualRounding != null)
      'accrual_rounding': _v2EnumToJson(accrualRounding!),
    if (pointsExpiryMonths != null) 'points_expiry_months': pointsExpiryMonths,
    if (modelStatus != null) 'model_status': _v2EnumToJson(modelStatus!),
    if (modelCoverage.isNotEmpty) 'model_coverage': modelCoverage,
    if (unlockRules.isNotEmpty)
      'unlock_rules': unlockRules.map((u) => u.toJson()).toList(),
    if (redemptionOptions.isNotEmpty)
      'redemption_options': redemptionOptions.map((o) => o.toJson()).toList(),
  };
}
