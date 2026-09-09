import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/benefit_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

void main() {
  testWidgets('renders all details for a direct benefit', (tester) async {
    final product = CardProduct(
      id: 'prod_1',
      name: 'Tata Neu Plus HDFC Bank Credit Card',
      issuerName: 'HDFC Bank',
      network: CardNetwork.rupay,
      benefits: [
        CardBenefit(
          id: 'b1',
          kind: BenefitKind.loungeDomestic,
          label:
              '1 complimentary domestic lounge voucher per qualifying calendar quarter, up to 4 per calendar year',
          description: 'Sponsor: HDFC Bank',
          quotaCount: 1,
          quotaPeriod: CapPeriod.quarter,
          networkProgram: 'visa_or_rupay_domestic_lounge_program',
          valueEstimate: Money.fromRupees(2000),
        ),
      ],
    );

    const userCard = UserCard(
      id: 'uc_1',
      cardProductId: 'prod_1',
      cardName: 'Tata Neu Plus HDFC Bank Credit Card',
      nickname: 'My Daily Tata Neu',
      isDefault: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          loungeUsageProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          home: BenefitDetailScreen(
            userCard: userCard,
            product: product,
            benefit: product.benefits.first,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Benefit details'), findsOneWidget);
    expect(find.text('Domestic lounge access'), findsOneWidget);
    expect(
      find.text(
        '1 complimentary domestic lounge voucher per qualifying calendar quarter, up to 4 per calendar year',
      ),
      findsOneWidget,
    );
    expect(find.text('My Daily Tata Neu'), findsOneWidget);
    expect(find.text('HDFC Bank · RUPAY'), findsOneWidget);
    expect(find.text('1 per quarter'), findsOneWidget);
    expect(find.text('visa_or_rupay_domestic_lounge_program'), findsOneWidget);
    expect(find.text('LOUNGE TRACKING'), findsOneWidget);
    expect(find.text('View All Lounge Access'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('HOW TO ACCESS THE LOUNGE'), 200);
    expect(find.text('HOW TO ACCESS THE LOUNGE'), findsOneWidget);
    expect(find.text('Present physical or digital card'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Sponsor: HDFC Bank'), 200);
    expect(find.text('Sponsor: HDFC Bank'), findsOneWidget);
  });

  testWidgets('renders non-lounge benefit (dining)', (tester) async {
    final product = CardProduct(
      id: 'prod_2',
      name: 'Axis Bank Cashback Credit Card',
      issuerName: 'Axis Bank',
      network: CardNetwork.visa,
      benefits: const [
        CardBenefit(
          id: 'b2',
          kind: BenefitKind.diningProgram,
          label: 'Dining Delights program',
          description: 'Sponsor: Axis Bank',
          quotaCount: 1,
          quotaPeriod: CapPeriod.calendarMonth,
          networkProgram: 'axis_dining_delights',
        ),
      ],
    );

    const userCard = UserCard(
      id: 'uc_2',
      cardProductId: 'prod_2',
      cardName: 'Axis Bank Cashback Credit Card',
      isDefault: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BenefitDetailScreen(
            userCard: userCard,
            product: product,
            benefit: product.benefits.first,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Dining'), findsOneWidget);
    expect(find.text('Dining Delights program'), findsOneWidget);
    expect(find.text('Axis Bank Cashback Credit Card'), findsOneWidget);
    expect(find.text('Axis Bank · VISA'), findsOneWidget);
    expect(find.text('1 per month'), findsOneWidget);
    expect(find.text('axis_dining_delights'), findsOneWidget);
    // Lounge tracking should not be present
    expect(find.text('LOUNGE TRACKING'), findsNothing);
  });

  testWidgets('resolves benefit from provider when given benefitId', (tester) async {
    final product = CardProduct(
      id: 'prod_3',
      name: 'Warranty Card',
      network: CardNetwork.mastercard,
      benefits: const [
        CardBenefit(
          id: 'b3',
          kind: BenefitKind.extendedWarranty,
          label: '1 Year Extended Warranty',
        ),
      ],
    );

    const userCard = UserCard(
      id: 'uc_3',
      cardProductId: 'prod_3',
      cardName: 'Warranty Card',
      isDefault: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([product])),
          userCardsProvider.overrideWith((ref) async => [userCard]),
        ],
        child: const MaterialApp(
          home: BenefitDetailScreen(
            benefitId: 'b3',
            userCardId: 'uc_3',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Extended warranty'), findsOneWidget);
    expect(find.text('1 Year Extended Warranty'), findsOneWidget);
    expect(find.text('Warranty Card'), findsOneWidget);
  });
}
