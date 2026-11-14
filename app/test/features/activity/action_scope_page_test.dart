import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_action_flow.dart';
import 'package:pandapay/features/activity/transaction_action_ui.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _txn(String id, double rupees, DateTime at, String last4) =>
    TransactionEntry(
      id: id,
      amount: Money.fromRupees(rupees),
      occurredAt: at,
      merchantName: 'AMAZON',
      categoryName: 'Shopping',
      tags: const [],
      userCardId: 'uc1',
      entryKind: TxnEntryKind.spend,
      instrument: TxnInstrument.creditCard,
      cardLast4: last4,
      source: 'sms',
      status: 'active',
      pipelineVersion: 2,
    );

void main() {
  testWidgets('other payments read like Activity rows and can be ticked', (
    tester,
  ) async {
    final source = _txn('s', 499, DateTime(2026, 9, 30, 10), '1111');
    final others = [
      _txn('a', 104, DateTime(2026, 9, 29, 9, 5), '1111'),
      _txn('b', 2004, DateTime(2026, 9, 28, 18, 40), '2222'),
    ];
    ActionScope? result;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showActionScopePage(
                context,
                entry: source,
                action: TxnAction.cardBill,
                candidates: others,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Each row says what it is, when, and on which card.
    expect(find.byKey(const ValueKey('scope-row-a')), findsOneWidget);
    expect(find.textContaining('29 Sep 2026'), findsOneWidget);
    expect(find.textContaining('Credit card ending 2222'), findsOneWidget);
    expect(find.text('AMAZON'), findsNWidgets(3)); // header + two rows

    await tester.tap(find.byKey(const ValueKey('scope-row-b')));
    await tester.pump();
    expect(find.text('Apply to 2'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('Apply to 3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('scope-confirm')));
    await tester.pumpAndSettle();
    expect(result!.others.map((e) => e.id), ['a', 'b']);
  });
}
