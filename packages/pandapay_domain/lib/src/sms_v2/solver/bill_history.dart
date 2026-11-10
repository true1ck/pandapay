/// Completes a bill reminder that prints an amount but no due date, from the
/// statement the same account already received.
///
/// The rule is deliberately strict: the reminder borrows a date only when exactly
/// ONE earlier statement could be the one it nags about. Anything ambiguous is
/// left alone, so the message stays in review and nothing is guessed. The
/// completed fact is a copy of the statement's own identity (same instrument,
/// same due date, same biller) carrying an amount that equals one of the
/// statement's own amounts, so it can never change a bill that already exists.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../contract/enums.dart';
import '../contract/fact.dart';
import '../contract/json_util.dart';
import 'evidence_solver.dart';

/// The one earlier statement a reminder belongs to.
final class BillHistoryMatch {
  const BillHistoryMatch({
    required this.statement,
    required this.role,
  });

  /// The earlier bill the reminder was matched to.
  final BillDueFact statement;

  /// Which of the statement's amounts the reminder repeats.
  final AmountRole role;
}

/// How long a statement stays a candidate for a reminder.
const Duration kBillHistoryWindow = Duration(days: 75);

/// A reminder this far past a statement's due date is not about that statement.
const Duration kBillOverdueGrace = Duration(days: 20);

String _digits(String? s) => (s ?? '').replaceAll(RegExp(r'\D'), '');

int? _amountOf(Fact f, AmountRole role) {
  for (final a in f.amounts) {
    if (a.role == role) return a.minor;
  }
  return null;
}

String _group(BillDueFact f) {
  final i = f.instrument;
  return '${i?.issuerSlug ?? ''}|${i?.maskDigits ?? ''}|${f.billerName ?? ''}|${f.dueDate}';
}

/// The earlier statement of [history] that a reminder for [minor] rupees-minor
/// on [at] belongs to, or null when there is not exactly one.
///
/// [mask] is the account digits the reminder printed, when it printed any;
/// [issuerSlug] and [billerName] describe who sent it.
BillHistoryMatch? matchEarlierBill({
  required int minor,
  required DateTime at,
  required Iterable<BillDueFact> history,
  String? mask,
  String? issuerSlug,
  String? billerName,
}) {
  final wantMask = _digits(mask);
  final matches = <BillDueFact, AmountRole>{};
  for (final f in history) {
    final seen = f.effectiveAt;
    if (seen.isAfter(at) || at.difference(seen) > kBillHistoryWindow) continue;
    final due = DateTime.tryParse('${f.dueDate}T00:00:00Z');
    if (due == null || at.isAfter(due.add(kBillOverdueGrace))) continue;
    final inst = f.instrument;
    // Same sender: the issuer when both know it, else the biller's name.
    if (issuerSlug != null && inst?.issuerSlug != null) {
      if (issuerSlug != inst!.issuerSlug) continue;
    } else if (billerName != null && f.billerName != null) {
      if (billerName.toLowerCase() != f.billerName!.toLowerCase()) continue;
    } else {
      continue;
    }
    // Same account when the reminder names one.
    if (wantMask.isNotEmpty) {
      final have = _digits(inst?.maskDigits);
      if (have.isEmpty || !(have.endsWith(wantMask) || wantMask.endsWith(have))) {
        continue;
      }
    }
    // The reminder must repeat one of the statement's own amounts.
    AmountRole? role;
    if (_amountOf(f, AmountRole.dueTotal) == minor) {
      role = AmountRole.dueTotal;
    } else if (_amountOf(f, AmountRole.dueMinimum) == minor) {
      role = AmountRole.dueMinimum;
    }
    if (role == null) continue;
    matches[f] = role;
  }
  if (matches.isEmpty) return null;
  // Exactly one statement (cycle): the same cycle seen twice is still one.
  final cycles = {for (final f in matches.keys) _group(f)};
  if (cycles.length != 1) return null;
  final latest = matches.keys.reduce(
    (a, b) => a.effectiveAt.isAfter(b.effectiveAt) ? a : b,
  );
  return BillHistoryMatch(statement: latest, role: matches[latest]!);
}

/// Confidence of a bill completed from history: below the review threshold, so
/// the message is shown to the person as an inference they can confirm.
const double kBillInferredConfidence = 0.6;

/// The bill fact for a date-less reminder, completed from [match]. Null when it
/// cannot be written as a valid fact.
Fact? completeBillFromHistory(
  SolverDecision d,
  BillHistoryMatch match, {
  required String sourceKey,
  required DateTime observedAt,
  required int packVersion,
  required int bundleVersion,
  required String engineVersion,
  required String appVersion,
}) {
  final minor = d.minor;
  if (minor == null || d.unit != 'INR') return null;
  final s = match.statement;
  final json = <String, Object?>{
    'contractVersion': Fact.contractVersion,
    'factId': sha256
        .convert(utf8.encode('$sourceKey|SOLVER-BILL-DUE-INFERRED|0'))
        .toString(),
    'sourceKey': sourceKey,
    'factType': 'bill_due',
    'observedAt': formatUtc(observedAt),
    'occurredAt': null,
    'instrument': s.instrument?.toJson(),
    'counterparty': null,
    'amounts': [
      {
        'role': match.role == AmountRole.dueMinimum ? 'due_minimum' : 'due_total',
        'minor': minor,
        'unit': 'INR',
      },
    ],
    'references': <String, String>{},
    'attrs': {
      'dueDate': s.dueDate,
      if (s.statementDate != null) 'statementDate': s.statementDate,
      if (s.billerName != null) 'billerName': s.billerName,
    },
    'provenance': {
      'engine': 'rules',
      'ruleId': 'SOLVER-BILL-DUE-INFERRED',
      'ruleVersion': packVersion,
      'bundleVersion': bundleVersion,
      'engineVersion': engineVersion,
      'appVersion': appVersion,
    },
    'evidence': <Object?>[],
    'confidence': kBillInferredConfidence,
  };
  try {
    return Fact.fromJson(json);
  } on Object {
    return null;
  }
}
