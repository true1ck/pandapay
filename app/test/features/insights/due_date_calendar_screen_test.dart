import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/due_date_calendar_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
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
}
