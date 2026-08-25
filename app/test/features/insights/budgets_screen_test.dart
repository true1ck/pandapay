import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/budgets_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Budgets are advisory and pace-aware. The distinction this suite exists
/// to protect: "over budget" and "spending faster than the period is
/// passing" are different states, and only the second is early enough to
/// act on.
BudgetStatus _budget({
  double amount = 20000,
  double spent = 10000,
  double elapsed = 0.5,
  String label = 'Groceries',
}) => BudgetStatus(
  id: 'b1',
  scope: BudgetScope.category,
  scopeRefId: 'cat-groceries',
  label: label,
  period: BudgetPeriod.monthly,
  amount: Money.fromRupees(amount),
  spent: Money.fromRupees(spent),
  txnCount: 8,
  periodStart: DateTime(2026, 8, 1),
  periodEnd: DateTime(2026, 9, 1),
  consumedFraction: spent / amount,
  elapsedFraction: elapsed,
  projected: Money.fromRupees(elapsed > 0 ? spent / elapsed : 0),
);

Future<void> _pump(WidgetTester tester, List<BudgetStatus> budgets, {bool signedIn = true}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (!signedIn)
          spendReportsRepositoryProvider.overrideWithValue(null)
        else
          spendReportsRepositoryProvider.overrideWithValue(
            SpendReportsRepository(apiBaseUrl: 'http://test', accessToken: 't'),
          ),
        budgetsProvider.overrideWith((ref) async => budgets),
      ],
      child: const MaterialApp(home: BudgetsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a budget on track shows what is left', (tester) async {
    // Half spent, half the month gone — nothing to warn about.
    await _pump(tester, [_budget(amount: 20000, spent: 10000, elapsed: 0.5)]);

    expect(find.textContaining('left'), findsOneWidget);
    expect(find.textContaining('Over by'), findsNothing);
    expect(find.textContaining('Ahead of pace'), findsNothing);
  });

  testWidgets('spending faster than the period is passing reads as ahead of pace, not over', (tester) async {
    // 80% spent on day 6 of a month. Not over — but the whole value of a
    // budget is being told while there is still something to do about it.
    await _pump(tester, [_budget(amount: 20000, spent: 16000, elapsed: 0.2)]);

    expect(find.textContaining('Ahead of pace'), findsOneWidget);
    expect(find.textContaining('Over by'), findsNothing);
  });

  testWidgets('a small lead over pace is not treated as a warning', (tester) async {
    // 52% spent with 50% of the period gone is noise. A warning that fires
    // on noise is one people learn to dismiss without reading.
    await _pump(tester, [_budget(amount: 20000, spent: 10400, elapsed: 0.5)]);
    expect(find.textContaining('Ahead of pace'), findsNothing);
  });

  testWidgets('an exceeded budget says by how much', (tester) async {
    await _pump(tester, [_budget(amount: 20000, spent: 23000, elapsed: 0.9)]);
    expect(find.textContaining('Over by'), findsOneWidget);
  });

  testWidgets('the empty state promises advice, never a block', (tester) async {
    // The app must never imply it can decline a payment.
    await _pump(tester, const []);
    expect(find.textContaining('No budgets yet'), findsOneWidget);
    expect(find.textContaining('never blocks'), findsOneWidget);
  });

  testWidgets('guest mode explains why budgets need an account', (tester) async {
    await _pump(tester, const [], signedIn: false);
    expect(find.textContaining('Sign in to set a budget'), findsOneWidget);
  });

  testWidgets('removing a budget asks first and says transactions are untouched', (tester) async {
    await _pump(tester, [_budget()]);

    await tester.tap(find.byTooltip('Remove this budget'));
    await tester.pumpAndSettle();

    expect(find.text('Remove this budget?'), findsOneWidget);
    expect(find.textContaining('transactions are not affected'), findsOneWidget);

    // Cancelling leaves the budget in place.
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);
  });
}
