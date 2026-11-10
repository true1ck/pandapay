import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:test/test.dart';

String _id(String s) => s.codeUnits.map((c) => c.toRadixString(16)).join().padRight(64, '0');

BillDueFact _bill(
  String id, {
  String due = '2026-11-20',
  String seen = '2026-11-01',
  int total = 2354000,
  int? minimum = 117700,
  String issuer = 'newbnk',
  String? mask = '4410',
}) => Fact.fromJson({
      'contractVersion': Fact.contractVersion,
      'factId': _id(id),
      'sourceKey': 'sms:$id',
      'factType': 'bill_due',
      'observedAt': '${seen}T06:00:00Z',
      'occurredAt': null,
      'instrument': {
        'kind': 'credit_card',
        'issuerSlug': issuer,
        'maskDigits': mask,
        'maskLength': null,
        'productName': null,
        'raw': null,
      },
      'counterparty': null,
      'amounts': [
        {'role': 'due_total', 'minor': total, 'unit': 'INR'},
        if (minimum != null) {'role': 'due_minimum', 'minor': minimum, 'unit': 'INR'},
      ],
      'references': <String, String>{},
      'attrs': {'dueDate': due, 'statementDate': seen},
      'provenance': {
        'engine': 'rules',
        'ruleId': 'T',
        'ruleVersion': 1,
        'bundleVersion': 1,
        'engineVersion': '2.4.0',
        'appVersion': '2.0.0',
      },
      'evidence': <Object?>[],
      'confidence': 0.9,
    }) as BillDueFact;

BillHistoryMatch? _match(
  int minor,
  List<BillDueFact> history, {
  String at = '2026-11-12',
  String? mask,
  String? issuer = 'newbnk',
  String? biller,
}) => matchEarlierBill(
  minor: minor,
  at: DateTime.parse('${at}T06:00:00Z'),
  history: history,
  mask: mask,
  issuerSlug: issuer,
  billerName: biller,
);

void main() {
  test('one statement of the same sender and amount matches', () {
    final m = _match(2354000, [_bill('a')], mask: '4410');
    expect(m?.statement.dueDate, '2026-11-20');
    expect(m?.role, AmountRole.dueTotal);
  });

  test('the minimum amount matches as the minimum', () {
    expect(_match(117700, [_bill('a')])?.role, AmountRole.dueMinimum);
  });

  test('a reminder that names no account still matches the only statement', () {
    expect(_match(2354000, [_bill('a')]), isNotNull);
  });

  test('every way it could be a different bill refuses', () {
    final a = _bill('a');
    expect(_match(555, [a]), isNull, reason: 'amount differs');
    expect(_match(2354000, [a], mask: '9999'), isNull, reason: 'other card');
    expect(_match(2354000, [a], issuer: 'otherbk'), isNull, reason: 'other sender');
    expect(_match(2354000, [a], issuer: null), isNull, reason: 'sender unknown');
    expect(_match(2354000, [a], at: '2026-10-30'), isNull, reason: 'reminder before the statement');
    expect(_match(2354000, [a], at: '2026-12-15'), isNull, reason: 'long after the due date');
    expect(_match(2354000, [_bill('a', seen: '2026-07-01', due: '2026-07-20')], at: '2026-11-12'), isNull, reason: 'stale statement');
    expect(_match(2354000, const []), isNull);
  });

  test('two cycles that both fit are ambiguous, the same cycle seen twice is not', () {
    final a = _bill('a');
    final other = _bill('b', due: '2026-12-20', seen: '2026-11-05');
    expect(_match(2354000, [a, other]), isNull);
    expect(_match(2354000, [a, _bill('a2', seen: '2026-11-03')]), isNotNull);
  });

  test('two cards with different digits are told apart by the digits', () {
    final a = _bill('a');
    final b = _bill('b', mask: '7788');
    expect(_match(2354000, [a, b]), isNull);
    expect(_match(2354000, [a, b], mask: '7788')?.statement.instrument?.maskDigits, '7788');
  });

  test('the completed fact copies the statement identity and is below the review bar', () {
    final a = _bill('a');
    final solver = EvidenceSolver(
      SolverPack.fromJson(
        jsonDecode(File('../../rules/sms/solver/pack.json').readAsStringSync())
            as Map<String, dynamic>,
      ),
    );
    final decision = solver.solve(
      'Reminder: your credit card bill of Rs 23,540 for card ending 4410 is due. Pay on or before the due date.',
      observedAt: DateTime.utc(2026, 11, 12),
      senderBrand: 'NEWBNK',
    );
    expect(decision.read, SolverRead.billDue);
    expect(decision.accepted, isFalse, reason: 'no due date is printed');
    expect(decision.mask, '4410');
    final fact = completeBillFromHistory(
      decision,
      BillHistoryMatch(statement: a, role: AmountRole.dueTotal),
      sourceKey: 'sms:r',
      observedAt: DateTime.utc(2026, 11, 12),
      packVersion: 2,
      bundleVersion: 1,
      engineVersion: '2.4.0',
      appVersion: '2.0.0',
    ) as BillDueFact;
    expect(fact.dueDate, '2026-11-20');
    expect(fact.instrument?.maskDigits, '4410');
    expect(fact.confidence, lessThan(0.7));
    expect(fact.provenance.ruleId, 'SOLVER-BILL-DUE-INFERRED');
  });
}
