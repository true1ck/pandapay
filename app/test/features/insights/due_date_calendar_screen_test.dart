import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/due_date_calendar_screen.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('previous month uses its observed bill due date', (tester) async {
    const card = UserCard(
      id: 'moneyback',
      cardProductId: 'p1',
      cardName: 'MoneyBack+ Credit Card',
      isDefault: false,
      dueDay: 16,
    );
    final product = CardProduct(
      id: 'p1',
      name: 'MoneyBack+ Credit Card',
      network: CardNetwork.visa,
    );
    final pastBill = CardBill(
      statementDate: DateTime(2026, 8, 20),
      dueDate: DateTime(2026, 9, 8),
      amountDue: Money.fromRupees(4150),
      minimumDue: null,
      paidToward: Money.zero(),
      lastPaymentAt: null,
      confidence: 0.95,
      statementDateExplicit: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(TestClock(DateTime(2026, 10, 26))),
          ownedCardsWithProductProvider.overrideWithValue(
            AsyncData([(card, product)]),
          ),
          paymentsDueProvider.overrideWith((ref) async => const []),
          cardBillLedgerProvider.overrideWith(
            (ref) async => {'moneyback': CardBillLedger(history: [pastBill])},
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DueDateCalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('16/10/2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.textContaining('8/9/2026'), findsOneWidget);
    expect(find.textContaining('16/9/2026'), findsNothing);
  });

  testWidgets('does not present an inferred anchor as a statement date', (
    tester,
  ) async {
    const card = UserCard(
      id: 'moneyback',
      cardProductId: 'p1',
      cardName: 'MoneyBack+ Credit Card',
      isDefault: false,
      dueDay: 8,
    );
    final product = CardProduct(
      id: 'p1',
      name: 'MoneyBack+ Credit Card',
      network: CardNetwork.visa,
    );
    final dueOn = DateTime(2026, 11, 8);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownedCardsWithProductProvider.overrideWithValue(
            AsyncData([(card, product)]),
          ),
          paymentsDueProvider.overrideWith(
            (ref) async => [
              DuePayment(
                card: card,
                dueOn: dueOn,
                daysUntilDue: 13,
                loggedThisCycle: Money.zero(),
                bill: CardBill(
                  statementDate: DateTime(2026, 10, 19),
                  dueDate: dueOn,
                  amountDue: Money.fromRupees(8331),
                  minimumDue: null,
                  paidToward: Money.zero(),
                  lastPaymentAt: null,
                  confidence: 0.95,
                  statementDateVerified: true,
                  statementDateExplicit: false,
                ),
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DueDateCalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Payment due'), findsOneWidget);
    expect(find.textContaining('Statement cuts'), findsNothing);
  });

  testWidgets('tapping a card date tile opens that card detail page', (
    tester,
  ) async {
    final card = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      statementDay: 11,
      dueDay: 16,
    );
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.visa,
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: DueDateCalendarScreen()),
        ),
        GoRoute(
          path: '/cards/:id',
          builder: (context, state) => Text(
            'card detail ${state.pathParameters['id']} tab=${state.uri.queryParameters['tab']}',
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownedCardsWithProductProvider.overrideWithValue(
            AsyncData([(card, product)]),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Card'), findsOneWidget);
    await tester.tap(find.textContaining('Payment due'));
    await tester.pumpAndSettle();

    expect(find.text('card detail uc1 tab=statement'), findsOneWidget);
  });

  testWidgets('renders card rows when cards are present', (
    tester,
  ) async {
    final card = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      statementDay: 11,
      dueDay: 16,
    );
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.visa,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownedCardsWithProductProvider.overrideWithValue(
            AsyncData([(card, product)]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DueDateCalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Card'), findsOneWidget);
  });

  testWidgets('shows the no-cards empty state when no cards are owned', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownedCardsWithProductProvider.overrideWithValue(
            const AsyncData([]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DueDateCalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No cards yet'), findsOneWidget);
  });
}
