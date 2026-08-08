import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/milestones_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 10 (E4 Milestones).
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

Future<void> _pump(WidgetTester tester, {required List<CardProduct> catalogue, required List<UserCard> owned}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
      ],
      child: const MaterialApp(home: Scaffold(body: MilestonesScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when no card has any milestones', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No milestones to chase'), findsOneWidget);
  });

  testWidgets('shows progress and remaining amount for an unreached milestone', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      milestoneRules: const [
        MilestoneRule(
          id: 'm1',
          label: '₹1L annual spend bonus',
          thresholdSpend: Money.fromPaise(10000000), // ₹1,00,000
          rewardValue: Money.fromPaise(500000), // ₹5,000
          isRepeatable: false,
        ),
      ],
    );
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      milestoneQualifiedSpend: const {'m1': Money.fromPaise(3000000)}, // ₹30,000 of ₹1,00,000
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('₹1L annual spend bonus'), findsOneWidget);
    expect(find.textContaining('to go'), findsOneWidget);
    expect(find.text('REACHED'), findsNothing);
  });

  testWidgets('shows a REACHED badge once qualified spend meets the threshold', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      milestoneRules: const [
        MilestoneRule(
          id: 'm1',
          label: 'Welcome bonus',
          thresholdSpend: Money.fromPaise(1000000),
          rewardValue: Money.fromPaise(200000),
          isRepeatable: false,
        ),
      ],
    );
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      milestoneQualifiedSpend: const {'m1': Money.fromPaise(1500000)}, // over threshold
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('REACHED'), findsOneWidget);
    expect(find.text('Milestone reached'), findsOneWidget);
  });
}
