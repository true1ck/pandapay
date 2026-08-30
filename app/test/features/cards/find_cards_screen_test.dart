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

_FakeLocalUserCardsRepository? _lastLocalRepo;

class _FakeLocalUserCardsRepository implements LocalUserCardsRepository {
  _FakeLocalUserCardsRepository() {
    _lastLocalRepo = this;
  }
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
    List<CardProduct> catalogueOverride = catalogue,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogueOverride)),
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
      // SMS discovery now requires a masked card number in the same message
      // (a promo that merely names a card is not enough) — see
      // LocalCardDiscoveryEngine.discoverAcrossMessages.
      smsBodies: const ['Rs. 500 spent on your HDFC Millennia card ending 4567 at Amazon'],
    );

    expect(find.text('HDFC Millennia'), findsOneWidget);
    expect(find.text('Yes, I have HDFC Millennia'), findsOneWidget);

    await tester.tap(find.text('Yes, I have HDFC Millennia'));
    await tester.pumpAndSettle();

    expect(find.text('Added to your wallet'), findsOneWidget);
  });

  testWidgets('offers a network chooser when the matched card has sibling rows', (tester) async {
    const flipkartVariants = [
      CardProduct(
        id: 'axis_flipkart_rupay',
        name: 'Axis Flipkart Card',
        issuerName: 'Axis Bank',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        pointValueInr: 1.0,
        rewardRules: [],
        capRules: [],
        milestoneRules: [],
        feeWaiverRules: [],
        benefits: [],
      ),
      CardProduct(
        id: 'axis_flipkart_mastercard',
        name: 'Axis Flipkart Card',
        issuerName: 'Axis Bank',
        network: CardNetwork.mastercard,
        isUpiLinkable: false,
        pointValueInr: 1.0,
        rewardRules: [],
        capRules: [],
        milestoneRules: [],
        feeWaiverRules: [],
        benefits: [],
      ),
    ];

    await pumpFindCardsScreen(
      tester,
      catalogueOverride: flipkartVariants,
      smsBodies: const ['Rs. 500 spent on your Axis Flipkart Card ending 4567 at Flipkart'],
    );

    // One suggestion, not one per network row.
    expect(find.text('Axis Flipkart Card'), findsOneWidget);
    expect(find.text('RuPay'), findsOneWidget);
    expect(find.text('Mastercard'), findsOneWidget);
    expect(find.text('Yes, I have this card'), findsOneWidget);

    // The SMS never stated a network, so nothing is preselected and the
    // confirm button is disabled until the user picks.
    expect(find.text('Pick a network above to continue'), findsOneWidget);
    final buttonBefore = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Yes, I have this card'),
    );
    expect(buttonBefore.onPressed, isNull);

    await tester.tap(find.text('Mastercard'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a network above to continue'), findsNothing);

    await tester.tap(find.text('Yes, I have this card'));
    await tester.pumpAndSettle();

    expect(_lastLocalRepo!.addedCards, ['axis_flipkart_mastercard']);
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
