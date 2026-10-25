import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/cards/discover_new_cards_screen.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  const diningId = 'cat-dining';
  const onlineId = 'cat-online';
  const groceriesId = 'cat-groceries';

  final categories = [
    const SpendCategory(id: diningId, slug: 'dining', name: 'Dining'),
    const SpendCategory(id: onlineId, slug: 'online', name: 'Online'),
    const SpendCategory(id: groceriesId, slug: 'groceries', name: 'Groceries'),
  ];

  final swiggyCard = CardProduct(
    id: 'hdfc-swiggy',
    name: 'HDFC Swiggy Card',
    network: CardNetwork.rupay,
    annualFeeInr: Money.fromRupees(500),
    rewardRules: const [
      RewardRule(
        id: 'swiggy-brand-rule',
        categoryId: diningId,
        merchantPattern: 'swiggy',
        unit: RewardUnit.cashbackPercent,
        rate: 10.0,
        priority: 10,
      ),
      RewardRule(
        id: 'dining-general-rule',
        categoryId: diningId,
        unit: RewardUnit.cashbackPercent,
        rate: 5.0,
        priority: 50,
      ),
      RewardRule(
        id: 'swiggy-base-rule',
        unit: RewardUnit.cashbackPercent,
        rate: 1.0,
        priority: 200,
      ),
    ],
  );

  final amazonCard = CardProduct(
    id: 'icici-amazon',
    name: 'Amazon Pay ICICI',
    network: CardNetwork.visa,
    annualFeeInr: const Money.zero(),
    rewardRules: const [
      RewardRule(
        id: 'amazon-brand-rule',
        categoryId: onlineId,
        merchantPattern: 'amazon',
        unit: RewardUnit.cashbackPercent,
        rate: 5.0,
        priority: 10,
      ),
      RewardRule(
        id: 'amazon-base-rule',
        unit: RewardUnit.cashbackPercent,
        rate: 1.0,
        priority: 200,
      ),
    ],
  );

  final genericCard = CardProduct(
    id: 'generic-card',
    name: 'Generic 2% Card',
    network: CardNetwork.visa,
    annualFeeInr: const Money.zero(),
    rewardRules: const [
      RewardRule(
        id: 'generic-base-rule',
        unit: RewardUnit.cashbackPercent,
        rate: 2.0,
        priority: 100,
      ),
    ],
  );

  group('Starter Profile & Acquisition Recommender', () {
    testWidgets(
      'empty spend history uses starter profile, computes positive uplift, and displays starter badge',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            categoriesProvider.overrideWith((ref) async => categories),
            catalogueProvider.overrideWith((ref) async => [swiggyCard, genericCard]),
            userCardsProvider.overrideWith((ref) async => const []),
            categorySpendProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
        );
        addTearDown(container.dispose);

        // Pump DiscoverNewCardsScreen and settle futures
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: DiscoverNewCardsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Verify acquisitionCandidatesProvider uses starter profile
        final candidatesAsync = container.read(acquisitionCandidatesProvider);
        expect(candidatesAsync.hasValue, isTrue);
        final candidates = candidatesAsync.requireValue;
        expect(candidates, isNotEmpty);
        expect(candidates.every((c) => c.isStarterProfile), isTrue);

        // Swiggy card should have positive uplift and be worthwhile
        final swiggy = candidates.firstWhere((c) => c.card.id == 'hdfc-swiggy');
        expect(swiggy.isWorthwhile, isTrue);
        expect(swiggy.uplift.paise, greaterThan(0));

        // DiscoverNewCardsScreen should show the candidate and the starter banner
        expect(find.text('HDFC Swiggy Card'), findsOneWidget);
        expect(
          find.textContaining('Based on a starter spend profile'),
          findsOneWidget,
        );
      },
    );
  });

  group('Home & Merchant Brand Accelerators', () {
    testWidgets(
      'bestCardForMerchantProvider triggers brand accelerator with MerchantRecommendationQuery',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            categoriesProvider.overrideWith((ref) async => categories),
            catalogueProvider.overrideWith((ref) async => [amazonCard, genericCard]),
            userCardsProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
        );
        addTearDown(container.dispose);

        // Await providers to resolve
        await container.read(categoriesProvider.future);
        await container.read(catalogueProvider.future);
        await container.read(userCardsProvider.future);
        await container.read(cardOverridesProvider.future);

        // Query for Amazon Pay
        final amazonRecAsync = container.read(
          bestCardForMerchantProvider(
            const MerchantRecommendationQuery(
              categoryId: onlineId,
              merchantName: 'Amazon Pay',
            ),
          ),
        );
        expect(amazonRecAsync.hasValue, isTrue);
        final amazonRec = amazonRecAsync.requireValue;
        expect(amazonRec, isNotNull);
        expect(amazonRec!.card.id, 'icici-amazon');
        expect(amazonRec.effectiveRatePerRupee, 0.05);

        // Query for a non-Amazon merchant in online
        final genericRecAsync = container.read(
          bestCardForMerchantProvider(
            const MerchantRecommendationQuery(
              categoryId: onlineId,
              merchantName: 'Flipkart',
            ),
          ),
        );
        expect(genericRecAsync.hasValue, isTrue);
        final genericRec = genericRecAsync.requireValue;
        expect(genericRec, isNotNull);
        expect(genericRec!.card.id, 'generic-card');
        expect(genericRec.effectiveRatePerRupee, 0.02);
      },
    );

    testWidgets(
      'rankedRecommendationsProvider on Home picks Swiggy card when nearby merchant is Swiggy',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            categoriesProvider.overrideWith((ref) async => categories),
            catalogueProvider.overrideWith((ref) async => [swiggyCard, genericCard]),
            userCardsProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
            selectedCategoryProvider.overrideWith((ref) => 'dining'),
            enteredAmountProvider.overrideWith((ref) => Money.fromRupees(1000)),
            homeNearbyContextProvider.overrideWith(
              (ref) => NearbyContextSnapshot(
                resolvedAt: DateTime.now(),
                origin: const GeoPoint(lat: 19.1, lng: 72.9),
                match: const NearbyMerchantMatch(
                  candidate: NearbyMerchantCandidate(
                    merchantId: 'm-swiggy',
                    displayName: 'Swiggy',
                    categoryId: diningId,
                    location: GeoPoint(lat: 19.1, lng: 72.9),
                  ),
                  distanceMeters: 50,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Await providers to resolve
        await container.read(categoriesProvider.future);
        await container.read(catalogueProvider.future);
        await container.read(userCardsProvider.future);
        await container.read(cardOverridesProvider.future);

        final recsAsync = container.read(rankedRecommendationsProvider);
        expect(recsAsync.hasValue, isTrue);
        final recs = recsAsync.requireValue;
        expect(recs, isNotEmpty);
        // Swiggy card should rank first with 10% rate on Swiggy
        expect(recs.first.card.id, 'hdfc-swiggy');
        expect(recs.first.effectiveRatePerRupee, 0.10);
        expect(recs.first.expectedValue, Money.fromRupees(100)); // 10% of 1000
      },
    );
  });
}
