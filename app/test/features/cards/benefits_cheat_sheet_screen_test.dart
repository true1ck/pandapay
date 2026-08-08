import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/benefits_cheat_sheet_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task C-0/C5: BenefitsCheatSheetScreen renders purely off
/// ownedCardsWithProductProvider (userCardsProvider x catalogueProvider) —
/// same fake-repository pattern insights screens already use, no real
/// network in a test.
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
      child: const MaterialApp(home: BenefitsCheatSheetScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when no owned card has any benefits', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No benefits to show yet'), findsOneWidget);
  });

  testWidgets('groups benefits by kind, across two different owned cards', (tester) async {
    final loungeCard = CardProduct(
      id: 'p1',
      name: 'Lounge Card',
      network: CardNetwork.rupay,
      benefits: const [
        CardBenefit(
          id: 'b1',
          kind: BenefitKind.loungeDomestic,
          label: '8 domestic lounge visits/year',
          quotaCount: 8,
          quotaPeriod: CapPeriod.annual,
          networkProgram: 'Priority Pass',
        ),
      ],
    );
    final warrantyCard = CardProduct(
      id: 'p2',
      name: 'Warranty Card',
      network: CardNetwork.visa,
      benefits: [
        CardBenefit(
          id: 'b2',
          kind: BenefitKind.extendedWarranty,
          label: '1 year extended warranty on electronics',
          valueEstimate: Money.fromRupees(2000),
        ),
      ],
    );
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Lounge Card', isDefault: false),
      const UserCard(id: 'uc2', cardProductId: 'p2', cardName: 'Warranty Card', isDefault: false),
    ];

    await _pump(tester, catalogue: [loungeCard, warrantyCard], owned: owned);

    expect(find.text('Domestic lounge access'), findsOneWidget);
    expect(find.text('8 domestic lounge visits/year'), findsOneWidget);
    expect(find.text('Priority Pass'), findsOneWidget);
    expect(find.text('Extended warranty'), findsOneWidget);
    expect(find.text('1 year extended warranty on electronics'), findsOneWidget);
  });

  testWidgets('two benefits of the same kind on the same card both show, not collapsed', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Dual Lounge Card',
      network: CardNetwork.rupay,
      benefits: const [
        CardBenefit(id: 'b1', kind: BenefitKind.loungeDomestic, label: '8 domestic visits'),
        CardBenefit(id: 'b2', kind: BenefitKind.loungeInternational, label: '4 international visits'),
      ],
    );
    final owned = [const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Dual Lounge Card', isDefault: false)];

    await _pump(tester, catalogue: [product], owned: owned);

    expect(find.text('8 domestic visits'), findsOneWidget);
    expect(find.text('4 international visits'), findsOneWidget);
  });
}
