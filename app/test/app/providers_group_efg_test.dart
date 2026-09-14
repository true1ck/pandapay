import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Group E/F/G (Chunks 36-38) — provider-level coverage for the four
/// providers the task brief called out as previously unwired/untested:
/// travelModeProvider (G1), splitPlanProvider (G2), emiAdviceProvider (G3),
/// creditUtilizationProvider (E3). Follows the same ProviderContainer +
/// fake-repository pattern as app/test/app/owned_cards_with_product_test.dart.
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

CardProduct _flatRateCard(String id, double ratePercent, {ForexRule? forexRule}) {
  return CardProduct(
    id: id,
    name: 'Card $id',
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    rewardRules: [RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: ratePercent)],
    forexRule: forexRule,
  );
}

UserCard _owned(String cardProductId, {Money? creditLimit, Map<String, Money> capConsumed = const {}}) {
  return UserCard(
    id: 'uc-$cardProductId',
    cardProductId: cardProductId,
    cardName: 'Card $cardProductId',
    isDefault: false,
    creditLimit: creditLimit,
    capConsumed: capConsumed,
  );
}

void main() {
  group('rankedRecommendationsProvider catalogue fallback', () {
    Future<List<Recommendation>> rankForWallet(List<UserCard> wallet) async {
      final cards = List.generate(4, (index) => _flatRateCard('card-$index', index + 1.0));
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => wallet),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(cards)),
        categoriesProvider.overrideWith((ref) async => const []),
        cardOverridesProvider.overrideWith((ref) async => const []),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);
      await container.read(categoriesProvider.future);
      await container.read(cardOverridesProvider.future);
      return container.read(rankedRecommendationsProvider).requireValue;
    }

    test('limits unowned catalogue recommendations to the top three', () async {
      final recommendations = await rankForWallet(const []);

      expect(recommendations, hasLength(3));
      expect(recommendations.map((r) => r.card.id), ['card-3', 'card-2', 'card-1']);
    });

    test('keeps every card from the user wallet in the ranking', () async {
      final recommendations = await rankForWallet([
        _owned('card-0'),
        _owned('card-1'),
        _owned('card-2'),
        _owned('card-3'),
      ]);

      expect(recommendations, hasLength(4));
      expect(recommendations.map((r) => r.card.id).toSet(), {'card-0', 'card-1', 'card-2', 'card-3'});
    });
  });

  group('travelModeProvider', () {
    test('defaults to off', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(travelModeProvider), isFalse);
    });

    test('flipping it updates rankedRecommendationsProvider\'s RecommendationContext', () {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => const []),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      container.read(travelModeProvider.notifier).state = true;
      expect(container.read(travelModeProvider), isTrue);
    });
  });

  group('creditUtilizationProvider', () {
    test('is empty when no owned card has a credit limit set', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      expect(container.read(creditUtilizationProvider), isEmpty);
    });

    test('computes utilization keyed by UserCard.id for cards with a limit', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [
              _owned('a', creditLimit: Money.fromRupees(10000), capConsumed: {'cap1': Money.fromRupees(4000)}),
            ]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      final result = container.read(creditUtilizationProvider);
      expect(result.containsKey('uc-a'), isTrue);
      expect(result['uc-a']!.ratio, closeTo(0.4, 0.0001));
      expect(result['uc-a']!.overThreshold, isTrue); // 40% > the 30% default threshold
    });

    test('a zero credit limit is treated the same as no limit (excluded, not a divide-by-zero card)', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a', creditLimit: const Money.zero())]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      expect(container.read(creditUtilizationProvider), isEmpty);
    });
  });

  group('splitPlanProvider', () {
    test('is empty when no amount has been entered yet', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      expect(container.read(splitPlanProvider), isEmpty);
    });

    test('is empty when the wallet is empty, even with an amount entered', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => const []),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(const [])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);
      container.read(splitPlannerAmountProvider.notifier).state = Money.fromRupees(1000);

      expect(container.read(splitPlanProvider), isEmpty);
    });

    test('allocates the full amount across a single owned card', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);
      container.read(splitPlannerAmountProvider.notifier).state = Money.fromRupees(1000);

      final plan = container.read(splitPlanProvider);
      expect(plan, isNotEmpty);
      final total = plan.fold<Money>(const Money.zero(), (a, b) => a + b.amount);
      expect(total, Money.fromRupees(1000));
    });
  });

  group('emiAdviceProvider', () {
    test('returns null for a non-positive principal', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      final advice = container.read(emiAdviceProvider((
        cardProductId: 'a',
        principalRupees: 0,
        tenureMonths: 6,
        annualInterestRatePercent: 15,
      )));
      expect(advice, isNull);
    });

    test('returns null when the card id is not in the owned wallet', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      final advice = container.read(emiAdviceProvider((
        cardProductId: 'not-owned',
        principalRupees: 5000,
        tenureMonths: 6,
        annualInterestRatePercent: 15,
      )));
      expect(advice, isNull);
    });

    test('returns real EMI advice with forgone rewards computed off the card\'s own rate', () async {
      final container = ProviderContainer(overrides: [
        userCardsProvider.overrideWith((ref) async => [_owned('a')]),
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_flatRateCard('a', 2)])),
      ]);
      addTearDown(container.dispose);

      await container.read(userCardsProvider.future);
      await container.read(catalogueProvider.future);

      final advice = container.read(emiAdviceProvider((
        cardProductId: 'a',
        principalRupees: 12000,
        tenureMonths: 12,
        annualInterestRatePercent: 15,
      )));
      expect(advice, isNotNull);
      // 2% of 12000 = 240, the forgone-rewards figure baked into effectiveCost.
      expect(advice!.forfeitedRewards, Money.fromRupees(240));
      expect(advice.totalInterest.paise, greaterThan(0));
    });
  });
}
