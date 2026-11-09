import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

BudgetStatus _budget(String id, {double amount = 1000, double spent = 400}) =>
    BudgetStatus(
      id: id,
      scope: BudgetScope.overall,
      scopeRefId: null,
      label: 'Overall',
      period: BudgetPeriod.monthly,
      amount: Money.fromRupees(amount),
      spent: Money.fromRupees(spent),
      txnCount: 3,
      periodStart: DateTime(2026, 11, 1),
      periodEnd: DateTime(2026, 11, 30),
      consumedFraction: spent / amount,
      elapsedFraction: 0.3,
    );

PendingCommand _cmd(String kind, Map<String, Object?> payload) =>
    PendingCommand(kind: kind, target: '${payload['id'] ?? 'x'}', payload: payload);

RecurringSeries _series(String id, double amount, int cadence) => RecurringSeries(
  id: id,
  displayName: 'Show $id',
  typicalAmount: Money.fromRupees(amount),
  amountKnown: true,
  cadenceDays: cadence,
  occurrenceCount: 4,
  annualCost: Money.fromPaise((Money.fromRupees(amount).paise * 365 / cadence).round()),
  detectionSource: 'detected',
  isMandate: false,
  isUserEdited: false,
  lifecycleStatus: 'active',
  autopayStatus: 'unknown',
  cadenceConfirmed: true,
  setupConfirmed: false,
  reviewCandidate: false,
);

void main() {
  group('budgets', () {
    test('a queued delete removes the budget at once', () {
      final rows = overlayBudgets(
        [_budget('a'), _budget('b')],
        [_cmd(OverlayCommand.budgetDelete, {'id': 'a'})],
      );
      expect(rows.map((b) => b.id), ['b']);
    });

    test('a queued amount change keeps what was spent and recomputes the share', () {
      final rows = overlayBudgets(
        [_budget('a')],
        [
          _cmd(OverlayCommand.budgetSave, {
            'scope': 'overall',
            'scopeRefId': null,
            'period': 'monthly',
            'amountInr': 2000.0,
          }),
        ],
      );
      expect(rows.single.amount, Money.fromRupees(2000));
      expect(rows.single.spent, Money.fromRupees(400));
      expect(rows.single.consumedFraction, closeTo(0.2, 1e-9));
    });

    test('with nothing queued the list is unchanged', () {
      final base = [_budget('a')];
      expect(overlayBudgets(base, const []), base);
    });
  });

  group('subscriptions', () {
    test('a queued dismiss hides the subscription and lowers the total', () {
      final a = _series('a', 100, 30);
      final b = _series('b', 200, 30);
      final report = RecurringReport(
        series: [a, b],
        totalAnnual: Money.fromPaise(a.annualCost.paise + b.annualCost.paise),
      );

      final out = overlayRecurring(report, [
        _cmd(OverlayCommand.recurringDismiss, {'id': 'a'}),
      ]);

      expect(out.series.map((s) => s.id), ['b']);
      expect(out.totalAnnual, b.annualCost);
    });

    test('a queued edit changes the row and its yearly cost', () {
      final a = _series('a', 100, 30);
      final report = RecurringReport(series: [a], totalAnnual: a.annualCost);

      final out = overlayRecurring(report, [
        _cmd(OverlayCommand.recurringUpdate, {
          'id': 'a',
          'displayName': 'Renamed',
          'amountInr': 300.0,
          'cadenceDays': 30,
          'nextExpectedOn': '2026-12-01',
          'autopayStatus': 'active',
        }),
      ]);

      expect(out.series.single.displayName, 'Renamed');
      expect(out.series.single.typicalAmount, Money.fromRupees(300));
      expect(out.series.single.isUserEdited, isTrue);
      expect(out.totalAnnual, out.series.single.annualCost);
      expect(out.totalAnnual.paise, greaterThan(a.annualCost.paise));
    });
  });
}
