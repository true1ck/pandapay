/// Scoring for the private labeled sample.
///
/// Pure functions only: no file or private-data access. `tool/score_private.dart`
/// reads the private folder and calls these. Every reading is derived from the
/// fact (and the family of the rule that produced it), never from a hard-coded
/// rule id, so new rules read correctly without scorer edits.
///
/// Definitions (see tools/sms_rules_cli/README.md):
///  - weight of a row = family_population / rows of that family in the scored
///    subset, so a subset estimates the whole inbox, not the sample.
///  - totals-changing effects are spending, money_in, refund and the two
///    investment effects; `none` and `transfer` never change spend, income or
///    investment totals.
library;

import 'package:pandapay_domain/sms_v2.dart';

/// Reading names that are not financial.
const nonFinancialReadings = {
  'otp',
  'promo',
  'service_notice',
  'not_financial',
};

/// Effects that do not change spend, income or investment totals.
const totalsNeutralEffects = {'none', 'transfer'};

/// Product features measured for event fidelity, by expected reading.
const featureReadings = <String, Set<String>>{
  'ipo': {
    'ipo_hold',
    'ipo_release',
    'ipo_application_notice',
    'ipo_notice',
    'ipo_mandate_approved',
    'ipo_allotment_shares',
    'ipo_partial_allotment',
  },
  'investment': {
    'investment_topup',
    'investment_withdrawal',
    'broker_balance_report',
    'broker_notice',
    'demat_movement',
  },
  'subscription': {
    'mandate_created',
    'mandate_modified',
    'mandate_paused',
    'mandate_resumed',
    'mandate_revoked',
    'mandate_expired',
    'mandate_failed',
    'upcoming_charge',
    'subscription_charge',
  },
  'refund': {'refund_credited', 'refund_initiated'},
};

/// Event types that may carry the expected effect of a feature row.
const _featureEventTypes = <String, Map<String, Set<String>>>{
  'ipo': {
    'investment_invested': {'ipo_application'},
  },
  'investment': {
    'investment_invested': {'investment'},
    'investment_withdrawn': {'investment_withdrawal'},
  },
  'subscription': {
    'spending': {'subscription_charge'},
  },
  'refund': {
    'refund': {'refund'},
  },
};

final _rechargeRule = RegExp(r'(^|-)RCH-');
final _usdText = RegExp(r'\b(?:USD|US\$)|\$\s?\d', caseSensitive: false);

/// The reading of a fact. [ruleFamily] is the family of the rule that emitted
/// it, when known.
String reading(Fact fact, {String? ruleFamily}) => switch (fact) {
  // A biller's or app's receipt: evidence only, never a movement.
  MovementFact f
      when f.evidenceOnly == true &&
          (ruleFamily == 'bill_receipt' ||
              f.purpose == MovementPurpose.billPayment) =>
    _rechargeRule.hasMatch(f.provenance.ruleId) ? 'recharge' : 'bill_receipt',
  MovementFact f => switch (f.purpose) {
    MovementPurpose.cardPayment =>
      f.direction == Direction.credit
          ? 'card_payment_received'
          : 'card_bill_payment',
    MovementPurpose.investment =>
      f.direction == Direction.credit
          ? 'investment_withdrawal'
          : 'investment_topup',
    MovementPurpose.refund || MovementPurpose.reversal => 'refund_credited',
    MovementPurpose.walletTopup || MovementPurpose.cashback => 'wallet_credit',
    MovementPurpose.salary => 'salary',
    _ when f.direction == Direction.credit => 'money_in',
    _ when f.rail == Rail.wallet => 'wallet_spend',
    _ when f.rail == Rail.card => 'card_spend',
    _ when f.rail == Rail.upi => 'upi_spend',
    _ => 'movement',
  },
  HoldFact f => switch ((f.purpose, f.phase)) {
    (HoldPurpose.ipoAsba, HoldPhase.released) => 'ipo_release',
    (HoldPurpose.ipoAsba, _) => 'ipo_hold',
    (_, HoldPhase.released) => 'hold_release',
    _ => 'hold',
  },
  // A pending debit with no stated purpose is a collect request from someone.
  AttemptFact f
      when f.status == AttemptStatus.pending &&
          f.direction == Direction.debit &&
          f.purpose == MovementPurpose.unknown =>
    'payment_request',
  AttemptFact f =>
    f.status == AttemptStatus.scheduled ? 'upcoming_charge' : 'failed_attempt',
  BillDueFact _ => ruleFamily == 'card_statement' ? 'statement' : 'bill_due',
  MandateFact f => 'mandate_${f.phase.wire}',
  LimitChangeFact _ => 'limit_change',
  RewardFact _ => 'reward_points',
  BalanceSnapshotFact f when f.instrument?.kind == InstrumentKind.broker =>
    'broker_balance_report',
  BalanceSnapshotFact _ => 'balance_snapshot',
  InfoFact _ when ruleFamily == 'ipo_notice' => 'ipo_application_notice',
  InfoFact f => switch (f.category) {
    InfoCategory.otp => 'otp',
    InfoCategory.promotion => 'promo',
    _ => 'service_notice',
  },
  _ => fact.factType.wire,
};

/// Whether a produced reading satisfies an expected one. Equal readings agree;
/// an expected `not_financial` agrees with any non-financial reading; an IPO
/// notice agrees with the application notice reading.
bool readingsAgree(Object? expected, Object? got) {
  if (expected == got) return true;
  if (expected == 'not_financial') return nonFinancialReadings.contains(got);
  if (const {'ipo_notice', 'ipo_application_notice'}.contains(expected)) {
    return const {'ipo_notice', 'ipo_application_notice'}.contains(got);
  }
  return false;
}

String moneyEffect(Fact? fact) {
  if (fact is! MovementFact || fact.evidenceOnly == true) return 'none';
  return switch (fact.purpose) {
    MovementPurpose.cardPayment =>
      fact.direction == Direction.debit ? 'transfer' : 'none',
    MovementPurpose.investment =>
      fact.direction == Direction.debit
          ? 'investment_invested'
          : 'investment_withdrawn',
    MovementPurpose.refund || MovementPurpose.reversal => 'refund',
    MovementPurpose.walletTopup =>
      fact.instrument?.issuerSlug == 'amazon_pay' ? 'spending' : 'transfer',
    MovementPurpose.transfer => 'transfer',
    MovementPurpose.cashback => 'none',
    _ => fact.direction == Direction.debit ? 'spending' : 'money_in',
  };
}

/// Ledger effect, money and event types of one message in a phone replay.
class LedgerOutcome {
  const LedgerOutcome(this.effect, this.amountMinor, this.eventTypes);
  final String effect;

  /// Sum of distinct contributing ledger rows, or null when there are none.
  final int? amountMinor;
  final Set<String> eventTypes;
}

/// Attribute a ledger effect only to a contributing leg. A receipt or
/// duplicate notice can be linked to a payment without being another payment.
LedgerOutcome ledgerOutcome(List events) {
  final effects = <String>{};
  final types = <String>{};
  final seen = <Object?>{};
  var total = 0;
  var any = false;
  for (final event in events.cast<Map>()) {
    final role = event['role'];
    final type = event['type'];
    if (!const {
      'debit_leg',
      'credit_leg',
      'reversal',
      'charge',
    }.contains(role)) {
      continue;
    }
    if (type == 'card_bill_payment' && role != 'debit_leg') continue;
    for (final row in (event['ledger'] as List).cast<Map>()) {
      String? effect;
      if (type == 'refund') {
        effect = 'refund';
      } else if (row['isSpend'] == true) {
        effect = 'spending';
      } else if (row['isIncome'] == true) {
        effect = 'money_in';
      } else if (row['isInvestment'] == true) {
        effect = type == 'investment_withdrawal'
            ? 'investment_withdrawn'
            : 'investment_invested';
      } else if (const {
        'card_bill_payment',
        'own_transfer',
        'wallet_topup',
      }.contains(type)) {
        effect = 'transfer';
      }
      if (effect == null) continue;
      effects.add(effect);
      types.add('$type');
      final key = row['entryId'] ?? '${event['eventId']}:${row.hashCode}';
      if (seen.add(key) && row['amountMinor'] is num) {
        total += (row['amountMinor'] as num).toInt();
        any = true;
      }
    }
  }
  return LedgerOutcome(
    effects.isEmpty ? 'none' : (effects.toList()..sort()).join('+'),
    any ? total : null,
    types,
  );
}

String ledgerEffect(List events) => ledgerOutcome(events).effect;

bool isFinancial(Map expected) =>
    !nonFinancialReadings.contains(expected['reading']);

/// The unit a label's amount is in: the label's own, points for rewards, USD
/// when the body prints USD, US$ or a dollar sign, otherwise INR.
String expectedUnit(Map expected, String body) =>
    (expected['currency'] ??
            expected['unit'] ??
            (expected['reading'] == 'reward_points'
                ? 'POINTS'
                : _usdText.hasMatch(body)
                ? 'USD'
                : 'INR'))
        as String;

/// The printed amount of a fact: its first amount, or an info fact's
/// informational `amountMinor`. The second kind is never money.
({int? minor, String? unit, bool informational}) printedAmount(Fact? fact) {
  final amount = fact?.amounts.firstOrNull;
  if (amount != null) {
    return (minor: amount.minor, unit: amount.unit, informational: false);
  }
  if (fact is InfoFact && fact.amountMinor != null) {
    return (minor: fact.amountMinor, unit: 'INR', informational: true);
  }
  return (minor: null, unit: null, informational: false);
}

bool _amountMatches(num expected, String unit, int? minor, String? gotUnit) =>
    (expected * (unit == 'POINTS' ? 1 : 100)).round() == minor &&
    gotUnit == unit;

/// Scores one labeled row.
///
/// [result] is the engine result for the message, [phoneRow] the optional
/// replay outcome (`decision`, `events`), [ruleFamilies] maps rule id to
/// family.
Map<String, Object?> scoreRow({
  required int index,
  required Map row,
  required InterpretResult result,
  Map? phoneRow,
  Map<String, String> ruleFamilies = const {},
}) {
  final raw = row['message'] as Map;
  final expected = row['expected'] as Map;
  final body = raw['body'] as String;
  final fact = result.facts.firstOrNull;
  final family = result.ruleId == null ? null : ruleFamilies[result.ruleId];
  final printed = printedAmount(fact);
  final ledger = phoneRow == null
      ? null
      : ledgerOutcome(phoneRow['events'] as List);
  final gotEffect = ledger?.effect ?? moneyEffect(fact);
  // The amount that reaches totals: the ledger rows of a replay, else the
  // movement amount. An informational amount never reaches totals.
  final totalsMinor = ledger != null
      ? ledger.amountMinor
      : (gotEffect == 'none' || printed.informational ? null : printed.minor);
  final got = {
    'reading': fact == null ? 'unknown' : reading(fact, ruleFamily: family),
    'countsAs': gotEffect,
    if (phoneRow != null) 'phoneDecision': phoneRow['decision'],
    'amountMinor': printed.minor,
    if (printed.informational) 'amountInformational': true,
    'unit': printed.unit,
    'instrumentKind': fact?.instrument?.kind?.wire,
    'instrumentMask': fact?.instrument?.maskDigits,
    'outcome': result.outcome.name,
    'ruleId': result.ruleId,
    'ruleFamily': ?family,
    if (ledger != null) 'eventTypes': ledger.eventTypes.toList()..sort(),
  };
  final unit = expectedUnit(expected, body);
  final readingOk = readingsAgree(expected['reading'], got['reading']);
  final effectOk = expected['countsAs'] == gotEffect;
  final expectedAmount = expected['amount'];
  final amountOk = expectedAmount is! num
      ? true
      : _amountMatches(expectedAmount, unit, printed.minor, printed.unit);
  final totalsAmountOk = expectedAmount is! num
      ? true
      : unit != 'POINTS' &&
            totalsMinor != null &&
            (expectedAmount * 100).round() == totalsMinor;
  final mismatches = [
    if (!readingOk) 'reading',
    if (!effectOk) 'countsAs',
    if (!amountOk) 'amount',
    for (final key in ['instrumentKind', 'instrumentMask'])
      if (expected[key] != null && '${expected[key]}' != got[key]) key,
  ];
  final expectedEffect = '${expected['countsAs']}';
  final String totals;
  if (!totalsNeutralEffects.contains(expectedEffect)) {
    totals = gotEffect == expectedEffect
        ? (totalsAmountOk ? 'change_ok' : 'change_amount')
        : totalsNeutralEffects.contains(gotEffect)
        ? 'change_missed'
        : 'change_wrong_effect';
  } else {
    totals = totalsNeutralEffects.contains(gotEffect)
        ? 'neutral_ok'
        : 'false_count';
  }
  // Event fidelity applies only to feature rows with a replay.
  String? feature;
  for (final entry in featureReadings.entries) {
    if (entry.value.contains(expected['reading'])) feature = entry.key;
  }
  bool? eventOk;
  if (feature != null && ledger != null) {
    final wanted = _featureEventTypes[feature]?[expectedEffect];
    eventOk = wanted == null
        ? ledger.effect == expectedEffect
        : ledger.eventTypes.intersection(wanted).isNotEmpty;
  }
  return {
    'index': index,
    'family': row['sampling_family'],
    'familyPopulation': row['family_population'],
    'familySample': row['family_sample'],
    'confidence': expected['confidence'],
    'financial': isFinancial(expected),
    'unknown': phoneRow == null
        ? result.outcome == InterpretOutcome.unknown
        : phoneRow['decision'] == null || phoneRow['decision'] == 'unknown',
    'ignored': phoneRow == null
        ? result.outcome == InterpretOutcome.ignored
        : phoneRow['decision'] == 'ignored',
    'ok': mismatches.isEmpty,
    'readingOk': readingOk,
    'effectOk': effectOk,
    'amountOk': amountOk,
    'totals': totals,
    'feature': feature,
    'eventOk': eventOk,
    'mismatches': mismatches,
    'expected': expected,
    'got': got,
    'totalsMinor': totalsMinor,
  };
}

double? _ratio(num numerator, num denominator) =>
    denominator == 0 ? null : numerator / denominator;

/// Weights for [subset]: each row weighs family_population divided by the
/// subset's rows in that family, so the weights of a family sum to the
/// family's population. Rows without a population weigh 1.
List<double> rowWeights(List<Map<String, Object?>> subset) {
  final inFamily = <Object?, int>{};
  for (final r in subset) {
    inFamily[r['family']] = (inFamily[r['family']] ?? 0) + 1;
  }
  return [
    for (final r in subset)
      switch (r['familyPopulation']) {
        final num pop when pop > 0 => pop / inFamily[r['family']]!,
        _ => 1.0,
      },
  ];
}

double _sum(Iterable<double> values) =>
    values.fold(0.0, (total, value) => total + value);

/// Summary of one subset of scored rows, unweighted and weighted.
Map<String, Object?> summarize(
  Iterable<Map<String, Object?>> rows, {
  bool deep = false,
}) {
  final subset = rows.toList();
  final w = rowWeights(subset);
  double weigh(bool Function(Map<String, Object?>) test) => _sum([
    for (var i = 0; i < subset.length; i++)
      if (test(subset[i])) w[i],
  ]);
  int count(bool Function(Map<String, Object?>) test) =>
      subset.where(test).length;
  bool financial(Map<String, Object?> r) => r['financial'] == true;
  bool ok(Map<String, Object?> r) => r['ok'] == true;
  bool unknown(Map<String, Object?> r) => financial(r) && r['unknown'] == true;
  final totalWeight = _sum(w);
  final financialWeight = weigh(financial);
  final out = <String, Object?>{
    'rows': subset.length,
    'correct': count(ok),
    'accuracy': _ratio(count(ok), subset.length),
    'weightedPopulation': totalWeight,
    'weightedAccuracy': _ratio(weigh(ok), totalWeight),
    'financialRows': count(financial),
    'financialUnknown': count(unknown),
    'financialIgnored': count((r) => financial(r) && r['ignored'] == true),
    'financialUnknownRate': _ratio(count(unknown), count(financial)),
    'weightedFinancialUnknownRate': _ratio(weigh(unknown), financialWeight),
  };
  if (!deep) return out;

  Map<String, Object?> totalsBlock() {
    bool shouldChange(Map<String, Object?> r) =>
        !totalsNeutralEffects.contains('${(r['expected'] as Map)['countsAs']}');
    bool mustNot(Map<String, Object?> r) => !shouldChange(r);
    bool cls(Map<String, Object?> r, String c) => r['totals'] == c;
    final change = count(shouldChange);
    final changeOk = count((r) => cls(r, 'change_ok'));
    final must = count(mustNot);
    final falseCount = count((r) => cls(r, 'false_count'));
    final falseRows = [
      for (var i = 0; i < subset.length; i++)
        if (cls(subset[i], 'false_count')) (subset[i], w[i]),
    ];
    final byEffect = <String, Object?>{};
    for (final effect in {
      for (final r in subset.where(shouldChange))
        '${(r['expected'] as Map)['countsAs']}',
    }) {
      bool inEffect(Map<String, Object?> r) =>
          shouldChange(r) && '${(r['expected'] as Map)['countsAs']}' == effect;
      byEffect[effect] = {
        'rows': count(inEffect),
        'correct': count((r) => inEffect(r) && cls(r, 'change_ok')),
      };
    }
    return {
      'shouldChangeRows': change,
      'shouldChangeCorrect': changeOk,
      'totalsCorrectRate': _ratio(changeOk, change),
      'weightedTotalsCorrectRate': _ratio(
        weigh((r) => cls(r, 'change_ok')),
        weigh(shouldChange),
      ),
      'shouldChangeMissed': count((r) => cls(r, 'change_missed')),
      'shouldChangeWrongEffect': count((r) => cls(r, 'change_wrong_effect')),
      'shouldChangeWrongAmount': count((r) => cls(r, 'change_amount')),
      'shouldChangeByEffect': byEffect,
      'mustNotChangeRows': must,
      'falseCounts': falseCount,
      'falseCountRate': _ratio(falseCount, must),
      'weightedFalseCountRate': _ratio(
        weigh((r) => cls(r, 'false_count')),
        weigh(mustNot),
      ),
      'weightedFalseCounts': weigh((r) => cls(r, 'false_count')),
      'falseCountsByEffect': {
        for (final effect in {
          for (final (r, _) in falseRows) '${(r['got'] as Map)['countsAs']}',
        })
          effect: falseRows
              .where((p) => '${(p.$1['got'] as Map)['countsAs']}' == effect)
              .length,
      },
      'falseCountMinor': falseRows.fold<int>(
        0,
        (t, p) => t + ((p.$1['totalsMinor'] as int?) ?? 0),
      ),
      'weightedFalseCountMinor': _sum([
        for (final (r, weight) in falseRows)
          ((r['totalsMinor'] as int?) ?? 0) * weight,
      ]),
    };
  }

  Map<String, Object?> featureBlock() {
    final result = <String, Object?>{};
    for (final feature in featureReadings.keys) {
      bool inFeature(Map<String, Object?> r) => r['feature'] == feature;
      bool fidelity(Map<String, Object?> r) =>
          inFeature(r) && r['ok'] == true && r['eventOk'] != false;
      final rowsIn = count(inFeature);
      result[feature] = {
        'rows': rowsIn,
        'readingOk': count((r) => inFeature(r) && r['readingOk'] == true),
        'effectOk': count((r) => inFeature(r) && r['effectOk'] == true),
        'amountOk': count((r) => inFeature(r) && r['amountOk'] == true),
        'eventTypeOk': count((r) => inFeature(r) && r['eventOk'] == true),
        'eventTypeMeasured': count((r) => inFeature(r) && r['eventOk'] != null),
        'fidelity': count(fidelity),
        'fidelityRate': _ratio(count(fidelity), rowsIn),
        'weightedFidelityRate': _ratio(weigh(fidelity), weigh(inFeature)),
      };
    }
    return result;
  }

  return {...out, 'totals': totalsBlock(), 'eventFidelity': featureBlock()};
}

/// The full summary for scored rows.
Map<String, Object?> buildSummary(
  List<Map<String, Object?>> scored, {
  required bool phone,
}) {
  final sure = scored.where((r) => r['confidence'] == 'sure').toList();
  final all = summarize(scored, deep: true);
  final sureSummary = summarize(sure, deep: true);
  Map<String, Object?> head(Map<String, Object?> s) {
    final totals = s['totals'] as Map;
    return {
      'accuracy': s['accuracy'],
      'weightedAccuracy': s['weightedAccuracy'],
      'weightedFinancialUnknownRate': s['weightedFinancialUnknownRate'],
      'totalsCorrectRate': totals['totalsCorrectRate'],
      'weightedTotalsCorrectRate': totals['weightedTotalsCorrectRate'],
      'falseCountRate': totals['falseCountRate'],
      'weightedFalseCountRate': totals['weightedFalseCountRate'],
    };
  }

  return {
    'measurement': phone
        ? 'engine reading plus phone ledger effect; unprocessed financial rows count as unknown'
        : 'single-message engine with inferred countsAs',
    'headline': {'sure': head(sureSummary), 'all': head(all)},
    'all': all,
    'sure': sureSummary,
    'unsure': summarize(scored.where((r) => r['confidence'] == 'unsure')),
    'sureByFamily': {
      for (final family in sure.map((r) => r['family']).toSet())
        '$family': summarize(sure.where((r) => r['family'] == family)),
    },
  };
}

/// Severity for ordering a review export: a false count first, then a missed
/// or wrong count, then any other disagreement.
int disagreementSeverity(Map<String, Object?> row) => switch (row['totals']) {
  'false_count' => 0,
  'change_wrong_effect' || 'change_amount' => 1,
  'change_missed' => 2,
  _ => 3,
};

/// Disagreements for human review, most consequential and heaviest first. Each
/// carries the message so a reviewer can judge the label; it belongs only in
/// the private folder.
List<Map<String, Object?>> disagreementExport(
  List<Map<String, Object?>> scored,
  List<Map> messages,
) {
  final weights = rowWeights(scored);
  final rows = [
    for (var i = 0; i < scored.length; i++)
      if (scored[i]['ok'] != true)
        {
          'index': scored[i]['index'],
          'family': scored[i]['family'],
          'confidence': scored[i]['confidence'],
          'weight': weights[i],
          'severity': disagreementSeverity(scored[i]),
          'totals': scored[i]['totals'],
          'mismatches': scored[i]['mismatches'],
          'expected': scored[i]['expected'],
          'got': scored[i]['got'],
          'message': messages[i],
        },
  ];
  rows.sort((a, b) {
    final bySeverity = (a['severity'] as int).compareTo(b['severity'] as int);
    return bySeverity != 0
        ? bySeverity
        : (b['weight'] as double).compareTo(a['weight'] as double);
  });
  return rows;
}

/// A plain-text review sheet for [disagreementExport] rows.
String reviewSheet(List<Map<String, Object?>> disagreements) {
  final out = StringBuffer(
    'Disagreements, most consequential first. Labels are drafts, not ground truth.\n',
  );
  for (final d in disagreements) {
    final expected = d['expected'] as Map;
    final got = d['got'] as Map;
    final message = d['message'] as Map;
    out
      ..writeln(
        '\n#${d['index']} family=${d['family']} weight=${(d['weight'] as double).toStringAsFixed(1)} '
        'severity=${d['severity']} totals=${d['totals']} confidence=${d['confidence']}',
      )
      ..writeln('  mismatches: ${(d['mismatches'] as List).join(', ')}')
      ..writeln(
        '  expected: reading=${expected['reading']} countsAs=${expected['countsAs']} amount=${expected['amount']} '
        'instrument=${expected['instrumentKind']}/${expected['instrumentMask']}',
      )
      ..writeln(
        '  got:      reading=${got['reading']} countsAs=${got['countsAs']} amountMinor=${got['amountMinor']} '
        'instrument=${got['instrumentKind']}/${got['instrumentMask']} rule=${got['ruleId']}',
      )
      ..writeln('  sender: ${message['sender']} at ${message['observedAt']}')
      ..writeln('  body: ${message['body']}');
  }
  return out.toString();
}
