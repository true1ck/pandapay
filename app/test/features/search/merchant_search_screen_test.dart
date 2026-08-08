import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/features/search/merchant_search_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

CardProduct _card(String id, {double rate = 0.02}) => CardProduct(
      id: id,
      name: id,
      network: CardNetwork.visa,
      isUpiLinkable: true,
      rewardRules: [
        RewardRule(id: '$id-rule', priority: 1, unit: RewardUnit.cashbackPercent, rate: rate),
      ],
    );

class _FakeMerchantSearchRepository implements MerchantSearchRepository {
  final Map<String, List<NearbyMerchantCandidate>> results;
  _FakeMerchantSearchRepository(this.results);

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    return results[query] ?? const [];
  }
}

class _ThrowingMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    throw ApiException('GET /merchants/search failed: 500 {}');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a matching search shows a ranked recommendation via bestCardForMerchantProvider', (tester) async {
    final repo = _FakeMerchantSearchRepository({
      'dmart': [
        const NearbyMerchantCandidate(
          merchantId: 'm1',
          displayName: 'DMart Powai',
          categoryId: 'groceries-id',
          location: GeoPoint(lat: 19.1, lng: 72.9),
        ),
      ],
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantSearchRepositoryProvider.overrideWithValue(repo),
          catalogueProvider.overrideWith((ref) async => [_card('groceries-card', rate: 0.05)]),
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: MerchantSearchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'dmart');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('DMart Powai'), findsOneWidget);
    expect(find.text('Use groceries-card'), findsOneWidget);
  });

  testWidgets('a no-match search falls back to category selection, not a dead end', (tester) async {
    final repo = _FakeMerchantSearchRepository(const {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantSearchRepositoryProvider.overrideWithValue(repo),
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith(
            (ref) async => const [SpendCategory(id: 'groceries-id', slug: 'groceries', name: 'Groceries')],
          ),
        ],
        child: const MaterialApp(home: MerchantSearchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nonexistent merchant xyz');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('No merchant found for'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Groceries'), findsOneWidget);
  });

  testWidgets('picking a category from the fallback sets selectedCategoryProvider', (tester) async {
    final repo = _FakeMerchantSearchRepository(const {});
    late final ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantSearchRepositoryProvider.overrideWithValue(repo),
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith(
            (ref) async => const [SpendCategory(id: 'fuel-id', slug: 'fuel', name: 'Fuel')],
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: MerchantSearchScreen());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'no match');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ActionChip, 'Fuel'));
    await tester.pumpAndSettle();

    expect(container.read(selectedCategoryProvider), 'fuel');
  });

  testWidgets('recent searches are persisted to SharedPreferences and survive a fresh read', (tester) async {
    final repo = _FakeMerchantSearchRepository({
      'dmart': [
        const NearbyMerchantCandidate(
          merchantId: 'm1',
          displayName: 'DMart Powai',
          categoryId: null,
          location: GeoPoint(lat: 19.1, lng: 72.9),
        ),
      ],
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantSearchRepositoryProvider.overrideWithValue(repo),
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: MerchantSearchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'dmart');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // A fresh SharedPreferences.getInstance() read (not the same in-memory
    // provider state) must see the persisted query — proves this isn't
    // just in-memory widget state.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('pandapay_app.merchant_recent_searches_v1'), ['dmart']);
  });

  testWidgets('a failed search shows an error state with retry, not a crash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantSearchRepositoryProvider.overrideWithValue(_ThrowingMerchantSearchRepository()),
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: MerchantSearchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'dmart');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
  });
}
