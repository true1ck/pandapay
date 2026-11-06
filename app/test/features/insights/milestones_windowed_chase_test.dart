import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/milestones_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// D35a in the app: the milestones screen's "Chasing this beats your base
/// rate" flag credits a milestone's reward against the spend still needed. For
/// a windowed (welcome) milestone the window may have closed (the server then
/// returns no row, so the screen reads "₹50,000 to go"), so the app must not
/// advise chasing it. Progress is still shown.
const _chasing = 'Chasing this beats your base rate';

CardProduct _card({int? windowDays}) => CardProduct(
  id: 'p1',
  name: 'Test Card',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: const [
    RewardRule(id: 'base', unit: RewardUnit.cashbackPercent, rate: 1),
  ],
  milestoneRules: [
    MilestoneRule(
      id: 'm1',
      label: 'Welcome gift',
      thresholdSpend: Money.fromRupees(50000),
      rewardValue: Money.fromRupees(60000), // far above 1% of the spend
      windowDays: windowDays,
    ),
  ],
);

Future<void> _pump(WidgetTester tester, CardProduct card) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueProvider.overrideWith((ref) async => [card]),
        userCardsProvider.overrideWith(
          (ref) async => [
            UserCard(
              id: 'uc1',
              cardProductId: 'p1',
              cardName: 'Test Card',
              isDefault: false,
            ),
          ],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: MilestonesScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an unwindowed milestone that beats the base rate says so', (
    tester,
  ) async {
    await _pump(tester, _card());
    expect(find.textContaining(_chasing), findsOneWidget);
  });

  testWidgets('a windowed milestone gets no "worth chasing" advice, but its '
      'progress still shows', (tester) async {
    await _pump(tester, _card(windowDays: 60));
    expect(find.textContaining(_chasing), findsNothing);
    expect(find.text('Welcome gift'), findsOneWidget);
    expect(find.textContaining('to go'), findsOneWidget);
  });
}
