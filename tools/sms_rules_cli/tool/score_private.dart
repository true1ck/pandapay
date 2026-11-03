// Local draft-label comparison. Pass private inputs and output under /tmp.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

String reading(Fact fact) => switch (fact) {
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
  AttemptFact f
      when const {
        'WAL-KIWI-COLLECT-PENDING',
        'WAL-PHONEPE-COLLECT-PENDING',
      }.contains(f.provenance.ruleId) =>
    'payment_request',
  AttemptFact f =>
    f.status == AttemptStatus.scheduled ? 'upcoming_charge' : 'failed_attempt',
  BillDueFact _ => 'bill_due',
  MandateFact f => 'mandate_${f.phase.wire}',
  LimitChangeFact _ => 'limit_change',
  RewardFact _ => 'reward_points',
  BalanceSnapshotFact f when f.instrument?.kind == InstrumentKind.broker =>
    'broker_balance_report',
  BalanceSnapshotFact _ => 'balance_snapshot',
  InfoFact f when f.provenance.ruleId == 'INV-IPO-NSE-COLLECT-NOTICE' =>
    'ipo_application_notice',
  InfoFact f => switch (f.attrsJson['category']) {
    'otp' => 'otp',
    'promotion' => 'promo',
    _ => 'service_notice',
  },
  _ => fact.factType.wire,
};

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

/// Attribute a ledger effect only to a contributing leg. A receipt or
/// duplicate notice can be linked to a payment without being another payment.
String ledgerEffect(List events) {
  final effects = <String>{};
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
      if (type == 'refund') {
        effects.add('refund');
      } else if (row['isSpend'] == true) {
        effects.add('spending');
      } else if (row['isIncome'] == true) {
        effects.add('money_in');
      } else if (row['isInvestment'] == true) {
        effects.add(
          type == 'investment_withdrawal'
              ? 'investment_withdrawn'
              : 'investment_invested',
        );
      } else if (const {
        'card_bill_payment',
        'own_transfer',
        'wallet_topup',
      }.contains(type)) {
        effects.add('transfer');
      }
    }
  }
  return effects.isEmpty ? 'none' : (effects.toList()..sort()).join('+');
}

bool isFinancial(Map expected) => !const {
  'otp',
  'promo',
  'service_notice',
  'not_financial',
}.contains(expected['reading']);

bool isTemporaryPath(String path) {
  final file = File(path);
  final parent = file.parent.resolveSymbolicLinksSync();
  final tmp = Directory('/tmp').resolveSymbolicLinksSync();
  if (parent != tmp && !parent.startsWith('$tmp/')) return false;
  return FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.link;
}

void main(List<String> args) {
  if ((args.length != 3 && args.length != 4) ||
      args.skip(1).any((path) => !isTemporaryPath(path))) {
    stderr.writeln(
      'Usage: score_private.dart BUNDLE /tmp/LABELS /tmp/REPORT [/tmp/PHONE_OUTCOMES]',
    );
    exitCode = 64;
    return;
  }
  final bundle = RuleBundle.fromJson(
    (jsonDecode(File(args[0]).readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );
  final rows = File(args[1]).readAsLinesSync();
  final phone = args.length == 4
      ? (jsonDecode(File(args[3]).readAsStringSync()) as Map)['outcomes']
            as List
      : null;
  if (phone != null && phone.length != rows.length) {
    throw FormatException('Phone outcome count must equal the label count');
  }
  final engine = RuleEngine();
  final scored = <Map<String, Object?>>[];
  for (var index = 0; index < rows.length; index++) {
    final row = jsonDecode(rows[index]) as Map;
    final raw = row['message'] as Map;
    final expected = row['expected'] as Map;
    if (!const {'sure', 'unsure'}.contains(expected['confidence'])) {
      throw FormatException('Invalid label confidence at index $index');
    }
    final outcome = engine.interpretDetailed(
      SmsMessage(
        sender: raw['sender'] as String,
        body: raw['body'] as String,
        sourceKey: 'private-sample:$index',
        observedAt: DateTime.parse(raw['observedAt'] as String).toUtc(),
        iosFilter: raw['iosFilter'] as String?,
      ),
      bundle,
      appVersion: '2.0.0',
    );
    final facts = outcome.result.facts;
    final fact = facts.firstOrNull;
    final amount = fact?.amounts.firstOrNull;
    final phoneRow = phone?[index] as Map?;
    if (phoneRow != null && phoneRow['index'] != index) {
      throw FormatException(
        'Phone outcomes must follow zero-based sample order',
      );
    }
    final got = {
      'reading': fact == null ? 'unknown' : reading(fact),
      'countsAs': phoneRow == null
          ? moneyEffect(fact)
          : ledgerEffect(phoneRow['events'] as List),
      if (phoneRow != null) 'phoneDecision': phoneRow['decision'],
      'amountMinor': amount?.minor,
      'unit': amount?.unit,
      'instrumentKind': fact?.instrument?.kind?.wire,
      'instrumentMask': fact?.instrument?.maskDigits,
      'outcome': outcome.result.outcome.name,
      'ruleId': outcome.result.ruleId,
    };
    final unit =
        expected['currency'] ??
        expected['unit'] ??
        (expected['reading'] == 'reward_points'
            ? 'POINTS'
            : RegExp(
                r'\b(?:USD|US\$)',
                caseSensitive: false,
              ).hasMatch(raw['body'] as String)
            ? 'USD'
            : 'INR');
    final mismatches = [
      for (final key in ['reading', 'countsAs'])
        if (expected[key] != got[key]) key,
      if (expected['amount'] case final num value)
        if ((value * (unit == 'POINTS' ? 1 : 100)).round() != amount?.minor ||
            amount?.unit != unit)
          'amount',
      for (final key in ['instrumentKind', 'instrumentMask'])
        if (expected[key] != null && '${expected[key]}' != got[key]) key,
    ];
    scored.add({
      'index': index,
      'family': row['sampling_family'],
      'confidence': expected['confidence'],
      'financial': isFinancial(expected),
      'unknown': phoneRow == null
          ? outcome.result.outcome == InterpretOutcome.unknown
          : phoneRow['decision'] == null || phoneRow['decision'] == 'unknown',
      'ignored': phoneRow == null
          ? outcome.result.outcome == InterpretOutcome.ignored
          : phoneRow['decision'] == 'ignored',
      'ok': mismatches.isEmpty,
      'mismatches': mismatches,
      'expected': expected,
      'got': got,
    });
  }
  Map<String, Object?> summarize(Iterable<Map<String, Object?>> subset) {
    final financial = subset.where((r) => r['financial'] == true);
    final correct = subset.where((r) => r['ok'] == true).length;
    final unknown = financial.where((r) => r['unknown'] == true).length;
    return {
      'rows': subset.length,
      'correct': correct,
      'accuracy': subset.isEmpty ? null : correct / subset.length,
      'financialRows': financial.length,
      'financialUnknown': unknown,
      'financialIgnored': financial.where((r) => r['ignored'] == true).length,
      'financialUnknownRate': financial.isEmpty
          ? null
          : unknown / financial.length,
    };
  }

  final sure = scored.where((r) => r['confidence'] == 'sure');
  final summary = {
    'measurement': phone == null
        ? 'single-message engine with inferred countsAs'
        : 'engine reading plus phone ledger effect; unprocessed financial rows count as unknown',
    'all': summarize(scored),
    'sure': summarize(sure),
    'unsure': summarize(scored.where((r) => r['confidence'] == 'unsure')),
    'sureByFamily': {
      for (final family in sure.map((r) => r['family']).toSet())
        '$family': summarize(sure.where((r) => r['family'] == family)),
    },
  };
  final report = File(args[2]);
  if (!report.existsSync()) {
    report.createSync(exclusive: true);
  }
  if (Process.runSync('chmod', ['600', report.path]).exitCode != 0) {
    throw StateError('Could not restrict the private report permissions');
  }
  report.writeAsStringSync(
    jsonEncode({
      ...summary,
      'disagreements': scored.where((r) => r['ok'] != true).toList(),
    }),
  );
  stdout.writeln(jsonEncode(summary));
}
