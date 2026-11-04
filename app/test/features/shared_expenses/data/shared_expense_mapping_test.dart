import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_expense_mapping.dart';

void main() {
  final accepted = <String, Object?>{
    'expenseId': 'expense',
    'title': 'Dinner',
    'totalMinor': '120000',
    'yourPaidMinor': '120000',
    'yourShareMinor': '60000',
    'bill': {
      'totalMinor': '140000',
      'contributions': [
        {'memberId': 'me', 'amountMinor': '140000'},
      ],
    },
  };
  test(
    'full bill and full own payment remain distinct from the shared ledger',
    () {
      final row = mapSharedExpenseRecord(accepted, 'me')!;
      expect(row.billTotal.paise, 140000);
      expect(row.yourPaid.paise, 140000);
      expect(row.yourShare.paise, 60000);
      expect(row.proposed, isFalse);
    },
  );
  test(
    'a first pending proposal stays visible with explicit proposed values',
    () {
      final row = mapSharedExpenseRecord({
        'expenseId': 'expense',
        'totalMinor': null,
        'pendingRevision': accepted,
      }, 'me')!;
      expect(row.proposed, isTrue);
      expect(row.billTotal.paise, 140000);
      expect(row.reviewLabel, contains('not included'));
    },
  );
  test('a proposed correction cannot replace accepted displayed amounts', () {
    final row = mapSharedExpenseRecord({
      ...accepted,
      'pendingRevision': {...accepted, 'totalMinor': '90000'},
    }, 'me')!;
    expect(row.proposed, isFalse);
    expect(row.yourShare.paise, 60000);
    expect(row.reviewLabel, contains('change'));
  });
  test('historical shared-only records never fabricate a full bill', () {
    final row = mapSharedExpenseRecord({...accepted, 'bill': null}, 'me')!;
    expect(row.totalLabel, 'Shared total');
    expect(row.paidLabel, 'Your shared contribution');
  });
}
