import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/local_budgets.dart';

/// H3-7: create-versus-edit is decided from the phone's own rows and queue,
/// not only from a (possibly stale) cached list.
void main() {
  const row = {'scope': 'tag', 'scopeRefId': 't1', 'period': 'monthly', 'amountInr': 100};
  String? find(Map<String, Map<String, Object?>> rows, List<PendingCommand> q,
          {String? ref = 't1', BudgetPeriod period = BudgetPeriod.monthly}) =>
      findLocalBudgetId(rows, q,
          scope: BudgetScope.tag, scopeRefId: ref, period: period);

  test('a local row for the target is found', () {
    expect(find({'b1': row}, const []), 'b1');
  });
  test('a queued save for the target is found', () {
    expect(
      find({}, [
        const PendingCommand(kind: OverlayCommand.budgetSave, target: 'x', payload: {...row, 'id': 'b2'}),
      ]),
      'b2',
    );
  });
  test('another target or a queued delete does not count', () {
    expect(find({'b1': row}, const [], ref: 't2'), isNull);
    expect(find({'b1': row}, const [], period: BudgetPeriod.weekly), isNull);
    expect(
      find({}, [const PendingCommand(kind: OverlayCommand.budgetDelete, target: 'x', payload: {...row, 'id': 'b3'})]),
      isNull,
    );
  });
}
