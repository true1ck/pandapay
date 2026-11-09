import 'package:pandapay_domain/pandapay_domain.dart';
import '../spend_reports_repository.dart';
import 'command_outbox.dart';

/// Command kinds that change what the Budgets and Subscriptions screens show.
abstract final class OverlayCommand {
  static const budgetDelete = 'budget_delete';
  static const budgetSave = 'budget_save';
  static const recurringDismiss = 'recurring_dismiss';
  static const recurringUpdate = 'recurring_update';

  static const budgetKinds = {budgetDelete, budgetSave};
  static const recurringKinds = {recurringDismiss, recurringUpdate};
}

/// Shows queued budget changes on top of the last list from the server, so a
/// delete or an amount change appears at once and survives a restart.
///
/// Only changes whose result is certain are applied. Removing a budget is. Changing
/// the amount of an existing budget is too: what was spent does not change, so
/// the share used is recomputed from it. A brand-new budget is not queued at
/// all, because its spend-so-far can only come from the server.
List<BudgetStatus> overlayBudgets(
  List<BudgetStatus> base,
  List<PendingCommand> pending,
) {
  var rows = List<BudgetStatus>.of(base);
  for (final command in pending) {
    switch (command.kind) {
      case OverlayCommand.budgetDelete:
        rows = [
          for (final b in rows)
            if (b.id != command.payload['id']) b,
        ];
      case OverlayCommand.budgetSave:
        final amount = (command.payload['amountInr'] as num?)?.toDouble();
        if (amount == null || amount <= 0) break;
        rows = [
          for (final b in rows)
            if (_sameBudget(b, command.payload)) _withAmount(b, amount) else b,
        ];
    }
  }
  return rows;
}

bool _sameBudget(BudgetStatus b, Map<String, Object?> p) =>
    b.scope.wireValue == p['scope'] &&
    (b.scopeRefId ?? '') == ((p['scopeRefId'] as String?) ?? '') &&
    b.period.wireValue == p['period'];

BudgetStatus _withAmount(BudgetStatus b, double amountRupees) {
  final amount = Money.fromRupees(amountRupees);
  return BudgetStatus(
    id: b.id,
    scope: b.scope,
    scopeRefId: b.scopeRefId,
    label: b.label,
    period: b.period,
    amount: amount,
    spent: b.spent,
    txnCount: b.txnCount,
    periodStart: b.periodStart,
    periodEnd: b.periodEnd,
    consumedFraction: amount.paise == 0 ? 0 : b.spent.paise / amount.paise,
    elapsedFraction: b.elapsedFraction,
    projected: b.projected,
  );
}

/// Shows queued subscription changes (hidden, edited) on top of the last report.
RecurringReport overlayRecurring(
  RecurringReport base,
  List<PendingCommand> pending,
) {
  var series = List<RecurringSeries>.of(base.series);
  var annualPaise = base.totalAnnual.paise;
  for (final command in pending) {
    final id = command.payload['id'];
    switch (command.kind) {
      case OverlayCommand.recurringDismiss:
        final hidden = series.where((s) => s.id == id);
        for (final s in hidden) {
          annualPaise -= s.annualCost.paise;
        }
        series = [
          for (final s in series)
            if (s.id != id) s,
        ];
      case OverlayCommand.recurringUpdate:
        series = [
          for (final s in series)
            if (s.id == id) _edited(s, command.payload) else s,
        ];
        // Keep the headline total in step with the edited rows.
        annualPaise = series.fold<int>(0, (sum, s) => sum + s.annualCost.paise);
    }
  }
  return RecurringReport(
    series: series,
    totalAnnual: series.length == base.series.length &&
            !pending.any((c) => c.kind == OverlayCommand.recurringUpdate)
        ? base.totalAnnual
        : Money.fromPaise(annualPaise),
  );
}

RecurringSeries _edited(RecurringSeries s, Map<String, Object?> p) {
  final amount = Money.fromRupees((p['amountInr'] as num).toDouble());
  final cadence = (p['cadenceDays'] as num).toInt();
  final next = DateTime.tryParse('${p['nextExpectedOn']}');
  return s.copyWith(
    displayName: p['displayName'] as String?,
    typicalAmount: amount,
    amountKnown: true,
    cadenceDays: cadence,
    annualCost: cadence <= 0
        ? s.annualCost
        : Money.fromPaise((amount.paise * 365 / cadence).round()),
    nextExpectedOn: next,
    autopayStatus: p['autopayStatus'] as String?,
    isUserEdited: true,
  );
}
