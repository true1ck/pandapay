import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

// The real activityTransactionsProvider re-runs whenever the transactions store changes (a sync, an SMS re-read,
// an outbox send). That must refresh the rows in place and never send the person back to the top of a long list.
final _revisionStandIn = StateProvider<int>((_) => 0);

List<TransactionEntry> _rows(int n, {int paise = 100}) => [
  for (var i = 0; i < n; i++)
    TransactionEntry(
      id: 'v2:$i',
      amount: Money.fromPaise(paise + i),
      occurredAt: DateTime.now().subtract(Duration(minutes: i)),
      merchantName: 'Shop $i',
      userCardId: 'uc1',
      entryKind: TxnEntryKind.spend,
      source: 'sms',
      status: 'active',
    ),
];

void main() {
  testWidgets('a data update while scrolled down keeps the reader where they are', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (context, state) => const Scaffold(body: ActivityScreen()))],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          foreignPaymentsProvider.overrideWith((ref) async => const []),
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          sessionInitProvider.overrideWith((ref) async {}),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          activityTransactionsProvider.overrideWith((ref) async {
            ref.watch(_revisionStandIn); // what the real provider does on a store change
            return _rows(150);
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Shop 90'),
      600,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 300,
    );
    await tester.pumpAndSettle();
    expect(find.text('Shop 90'), findsOneWidget, reason: 'scrolled down to the row');

    final container = ProviderScope.containerOf(tester.element(find.byType(ActivityScreen)));
    for (var i = 0; i < 3; i++) {
      container.read(_revisionStandIn.notifier).state++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(find.text('Shop 90'), findsOneWidget, reason: 'still on the same row, not thrown back to the top');
    expect(find.text('Shop 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
