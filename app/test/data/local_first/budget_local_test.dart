import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_first/budget_local.dart';

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/budget_spent_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final now = DateTime.parse(fixture['now'] as String);
  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('golden: ${c['name']}', () {
      final result = computeBudgetSpend(
        BudgetDef.fromJson(c['budget'] as Map<String, dynamic>),
        [
          for (final t in (c['txns'] as List).cast<Map<String, dynamic>>())
            BudgetTxn.fromJson(t),
        ],
        now,
      );
      final want = c['expected'] as Map<String, dynamic>;
      expect(result.spentPaise, want['spentPaise']);
      expect(result.txnCount, want['txnCount']);
      expect(result.start, DateTime.parse(want['start'] as String));
      expect(result.end, DateTime.parse(want['end'] as String));
    });
  }

  test('elapsed fraction is 0..1 across the period', () {
    const def = BudgetDef(scope: 'overall', period: 'monthly');
    final mid = computeBudgetSpend(def, const [], DateTime(2026, 11, 16));
    expect(mid.elapsedFraction, closeTo(15 / 30, 1e-9));
  });
}
