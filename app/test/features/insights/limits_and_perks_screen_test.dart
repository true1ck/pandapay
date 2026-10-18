import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/insights/limits_and_perks_screen.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('card expands to its categories without duplicate headers', (
    tester,
  ) async {
    final product = CardProduct(
      id: 'p',
      name: 'Test card',
      network: CardNetwork.visa,
      capRules: const [
        CapRule(
          id: 'cap',
          label: 'Monthly reward cap',
          capValue: Money.fromPaise(50000),
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
        ),
      ],
    );
    final card = UserCard(
      id: 'c',
      cardProductId: 'p',
      cardName: 'Test card',
      isDefault: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownedCardsWithProductProvider.overrideWithValue(
            AsyncData([(card, product)]),
          ),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: LimitsAndPerksScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Test card'), findsOneWidget);
    expect(find.text('SPEND & REWARD CAPS'), findsNothing);
    await tester.tap(find.text('Test card'));
    await tester.pumpAndSettle();
    expect(find.text('SPEND & REWARD CAPS'), findsOneWidget);
    expect(find.text('Monthly reward cap'), findsOneWidget);
    expect(find.text('Test card'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
