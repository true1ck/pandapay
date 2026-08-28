import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/local_user_cards_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/find_cards_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeLocalUserCardsRepository implements LocalUserCardsRepository {
  final List<String> addedCards = [];

  @override
  Future<List<UserCard>> fetchUserCards({
    bool includeArchived = false,
    required List<CardProduct> catalogue,
  }) async => [];

  @override
  Future<String> addCard(String cardProductId, {String? nickname}) async {
    addedCards.add(cardProductId);
    return 'local_$cardProductId';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const catalogue = [
    CardProduct(
      id: 'hdfc_millennia',
      name: 'HDFC Millennia',
      issuerName: 'HDFC Bank',
      network: CardNetwork.visa,
      isUpiLinkable: false,
      pointValueInr: 1.0,
      rewardRules: [],
      capRules: [],
      milestoneRules: [],
      feeWaiverRules: [],
      benefits: [],
    ),
  ];

  Future<void> pumpFindCardsScreen(
    WidgetTester tester, {
    List<String> smsBodies = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
          localUserCardsRepositoryProvider.overrideWith((ref) async => _FakeLocalUserCardsRepository()),
          userCardsRepositoryProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: FindCardsScreen(smsBodies: smsBodies),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows empty state with 1-tap options when no messages are scanned', (tester) async {
    await pumpFindCardsScreen(tester, smsBodies: const []);

    expect(find.text('Find my cards'), findsOneWidget);
    expect(find.text('Auto-detect your cards'), findsOneWidget);
    expect(find.text('Connect Gmail (1-Tap Auto Find)'), findsOneWidget);
    expect(find.text('Search & pick from catalogue'), findsOneWidget);
    expect(find.text('PDF Statement · SMS Backup · Email Forwarding'), findsOneWidget);
  });

  testWidgets('shows discovered card suggestion and allows adding to wallet', (tester) async {
    await pumpFindCardsScreen(
      tester,
      smsBodies: const ['Rs. 500 spent on your HDFC Millennia card at Amazon'],
    );

    expect(find.text('HDFC Millennia'), findsOneWidget);
    expect(find.text('Yes, I have HDFC Millennia'), findsOneWidget);

    await tester.tap(find.text('Yes, I have HDFC Millennia'));
    await tester.pumpAndSettle();

    expect(find.text('Added to your wallet'), findsOneWidget);
  });

  testWidgets('opens other ways to import bottom sheet', (tester) async {
    await pumpFindCardsScreen(tester, smsBodies: const []);

    await tester.tap(find.text('PDF Statement · SMS Backup · Email Forwarding'));
    await tester.pumpAndSettle();

    expect(find.text('Other ways to import'), findsOneWidget);
    expect(find.text('Import bank statement PDF'), findsOneWidget);
    expect(find.text('Import SMS backup file'), findsOneWidget);
    expect(find.text('Set up email forwarding'), findsOneWidget);
  });
}
