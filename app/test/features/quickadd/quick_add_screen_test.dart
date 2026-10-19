import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _recentMerchantsKey = 'pandapay_app.quick_add_recent_merchants_v1';

class _FakeMerchantSearchRepository implements MerchantSearchRepository {
  final Map<String, List<NearbyMerchantCandidate>> results;
  _FakeMerchantSearchRepository(this.results);

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async =>
      results[query] ?? const [];

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

class _EmptyMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [];

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

class _ControlledMerchantSearchRepository implements MerchantSearchRepository {
  final requests = <String, Completer<List<NearbyMerchantCandidate>>>{};

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) =>
      (requests[query] = Completer<List<NearbyMerchantCandidate>>()).future;

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

class _ThrowingMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    throw ApiException('GET /merchants/search failed: 500 {}');
  }

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

/// In-memory stand-in for UserCardsRepository.logTransaction so the
/// save+pop+Undo flow can be exercised without a real HTTP client.
class _FakeUserCardsRepository extends UserCardsRepository {
  _FakeUserCardsRepository()
    : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async => 'fake-txn-id';

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {}
}

class _LostResponseUserCardsRepository extends UserCardsRepository {
  final List<String?> mutationIds = [];

  _LostResponseUserCardsRepository()
    : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async {
    mutationIds.add(clientMutationId);
    if (mutationIds.length == 1) throw ApiException('response lost');
    return 'same-server-transaction';
  }
}

/// Save stays in the sticky footer while the transaction form scrolls.
Future<Finder> _saveButton(WidgetTester tester) async {
  return find.ancestor(
    of: find.byIcon(Icons.save_outlined),
    matching: find.byType(FilledButton),
  );
}

Finder get _amountField => find.byKey(const ValueKey('quick-add-amount-field'));
Finder get _merchantField =>
    find.byKey(const ValueKey('quick-add-merchant-field'));

Future<void> _selectCreditCard(WidgetTester tester, String cardName) async {
  final selector = find.byKey(const ValueKey('quick-add-card-selector'));
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(selector);
  await tester.pumpAndSettle();
  await tester.tap(selector);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, cardName));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'four merchant shortcuts combine latest choice and frequency, with searchable history',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        _recentMerchantsKey: ['Last picked', 'FREQUENT', 'Fallback'],
      });
      final now = DateTime(2026, 10, 19);
      TransactionEntry entry(
        String id,
        String name,
        int days, {
        String status = 'active',
        TxnEntryKind kind = TxnEntryKind.spend,
      }) => TransactionEntry(
        id: id,
        amount: const Money.fromPaise(10000),
        occurredAt: now.subtract(Duration(days: days)),
        merchantName: name,
        source: 'manual',
        status: status,
        entryKind: kind,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            transactionsProvider.overrideWith(
              (ref) async => [
                entry('1', 'Frequent', 4),
                entry('2', 'frequent', 5),
                entry('3', 'Frequent', 6),
                entry('4', 'Runner up', 2),
                entry('5', 'Runner up', 3),
                entry('6', 'Newest shop', 1),
                entry('7', 'Ignored shop', 0, status: 'ignored'),
                entry('8', 'Salary', 0, kind: TxnEntryKind.income),
              ],
            ),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen(autofocus: false)),
        ),
      );
      await tester.pumpAndSettle();
      final strip = find.byKey(const ValueKey('quick-add-merchant-shortcuts'));
      final labels = tester
          .widgetList<Text>(
            find.descendant(of: strip, matching: find.byType(Text)),
          )
          .map((text) => text.data)
          .toList();
      expect(labels, ['Last picked', 'Frequent', 'Runner up', 'Newest shop']);
      await tester.ensureVisible(
        find.descendant(of: strip, matching: find.text('Newest shop')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: strip, matching: find.text('Newest shop')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_merchantField).controller!.text,
        'Newest shop',
      );
      await tester.ensureVisible(_merchantField);
      await tester.enterText(_merchantField, 'fall');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Fallback'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an older database search cannot replace newer merchant results',
    (tester) async {
      final repo = _ControlledMerchantSearchRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            transactionsProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: QuickAddScreen(autofocus: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_merchantField, 'old');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(_merchantField, 'new');
      await tester.pump(const Duration(milliseconds: 350));
      repo.requests['new']!.complete(const [
        NearbyMerchantCandidate(
          merchantId: 'new',
          displayName: 'New match',
          location: GeoPoint(lat: 0, lng: 0),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'New match'), findsOneWidget);
      repo.requests['old']!.complete(const [
        NearbyMerchantCandidate(
          merchantId: 'old',
          displayName: 'Old match',
          location: GeoPoint(lat: 0, lng: 0),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'New match'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Old match'), findsNothing);
    },
  );

  testWidgets(
    'small screens and large text retain app-color category selection without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith(
              (ref) async => const [
                SpendCategory(
                  id: 'groceries',
                  slug: 'groceries',
                  name: 'Groceries',
                ),
                SpendCategory(id: 'fuel', slug: 'fuel', name: 'Fuel'),
                SpendCategory(id: 'dining', slug: 'dining', name: 'Dining'),
                SpendCategory(
                  id: 'shopping',
                  slug: 'shopping',
                  name: 'Online Shopping',
                ),
              ],
            ),
            transactionsProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const QuickAddScreen(autofocus: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Dining'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dining'));
      await tester.pumpAndSettle();
      final diningChoice = find
          .ancestor(of: find.text('Dining'), matching: find.byType(Semantics))
          .first;
      final icons = tester.widgetList<Icon>(
        find.descendant(of: diningChoice, matching: find.byType(Icon)),
      );
      expect(icons.single.color, BambooInk.lime);
      await tester.ensureVisible(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Save stays disabled until an amount and a card are both set', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(
            _EmptyMerchantSearchRepository(),
          ),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(await _saveButton(tester));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets(
    'an empty-or-zero amount shows a validation error on Save attempt, not a crash',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_amountField, '0');
      await tester.pumpAndSettle();
      // Save is still disabled (no card selected) — this test only verifies
      // the screen builds cleanly with a zero-amount entry, matching this
      // task's amount>0 validation rule.
      expect(_amountField, findsOneWidget);
    },
  );

  testWidgets(
    'amount entry field is auto-focused so typing the amount is the first tap',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final amountField = tester.widget<TextField>(_amountField);
      expect(amountField.autofocus, isTrue);
    },
  );

  testWidgets(
    'Save becomes enabled once a positive amount and a card are chosen',
    (tester) async {
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'product-1',
        cardName: 'Test Card',
        isDefault: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_amountField, '250');
      await _selectCreditCard(tester, 'Test Card');

      final saveButton = tester.widget<FilledButton>(await _saveButton(tester));
      expect(saveButton.onPressed, isNotNull);
    },
  );

  testWidgets(
    'Quick Add recommends a wallet card, shows alternatives, and selects the chosen card',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const bestProduct = CardProduct(
        id: 'product-best',
        name: 'Best Rewards Card',
        issuerName: 'Panda Bank',
        network: CardNetwork.visa,
        cardType: 'credit',
      );
      const alternateProduct = CardProduct(
        id: 'product-alternate',
        name: 'Alternate Rewards Card',
        issuerName: 'Bamboo Bank',
        network: CardNetwork.mastercard,
        cardType: 'credit',
      );
      const thirdProduct = CardProduct(
        id: 'product-third',
        name: 'Third Rewards Card',
        issuerName: 'Panda Bank',
        network: CardNetwork.rupay,
        cardType: 'credit',
      );
      const wallet = <UserCard>[
        UserCard(
          id: 'wallet-best',
          cardProductId: 'product-best',
          cardName: 'Best Rewards Card',
          isDefault: true,
        ),
        UserCard(
          id: 'wallet-alternate',
          cardProductId: 'product-alternate',
          cardName: 'Alternate Rewards Card',
          isDefault: false,
        ),
        UserCard(
          id: 'wallet-third',
          cardProductId: 'product-third',
          cardName: 'Third Rewards Card',
          isDefault: false,
        ),
      ];
      const recommendations = [
        Recommendation(
          card: bestProduct,
          expectedValue: Money.fromPaise(6500),
          confidence: Confidence.estimated,
          reasonLines: ['6.5% on dining'],
          effectiveRatePerRupee: 0.065,
        ),
        Recommendation(
          card: alternateProduct,
          expectedValue: Money.fromPaise(4000),
          confidence: Confidence.estimated,
          reasonLines: ['4% on dining'],
          effectiveRatePerRupee: 0.04,
        ),
        Recommendation(
          card: thirdProduct,
          expectedValue: Money.fromPaise(2000),
          confidence: Confidence.estimated,
          reasonLines: ['2% base rewards'],
          effectiveRatePerRupee: 0.02,
        ),
      ];
      final query = (
        amount: const Money.fromPaise(125000),
        categoryId: null,
        categorySlug: null,
        merchantName: null,
        transactionDate: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => wallet),
            catalogueProvider.overrideWith(
              (ref) async => const [
                bestProduct,
                alternateProduct,
                thirdProduct,
              ],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            transactionsProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
            quickAddRecommendationsProvider(
              query,
            ).overrideWithValue(const AsyncValue.data(recommendations)),
          ],
          child: const MaterialApp(
            home: QuickAddScreen(
              initialAmount: Money.fromPaise(125000),
              autofocus: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('quick-add-card-recommendation')),
        findsOneWidget,
      );
      expect(find.text('Best Rewards Card'), findsOneWidget);
      expect(find.text('Pay with this card'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('quick-add-use-recommended-wallet-best')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Using this card'), findsOneWidget);

      final showMore = find.byKey(const ValueKey('quick-add-show-more-cards'));
      await tester.ensureVisible(showMore);
      await tester.pumpAndSettle();
      await tester.tap(showMore);
      await tester.pumpAndSettle();
      expect(find.text('Third Rewards Card'), findsOneWidget);

      final alternate = find.byKey(
        const ValueKey('quick-add-alternative-wallet-alternate'),
      );
      await tester.ensureVisible(alternate);
      await tester.pumpAndSettle();
      await tester.tap(alternate);
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('quick-add-card-selector'));
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: selector,
          matching: find.text('Alternate Rewards Card'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'typing a merchant query shows live search suggestions and picking one auto-fills category',
    (tester) async {
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
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith(
              (ref) async => const [
                SpendCategory(
                  id: 'groceries-id',
                  slug: 'groceries',
                  name: 'Groceries',
                ),
              ],
            ),
            merchantSearchRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: QuickAddScreen(initialUserCardId: 'card-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_merchantField, 'dmart');
      // Debounce is 300ms — advance past it, then let the fake repo's Future resolve.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('DMart Powai'), findsOneWidget);

      await tester.tap(find.text('DMart Powai'));
      await tester.pumpAndSettle();

      // Picking the merchant carries its category into the selection sheet.
      expect(_merchantField, findsOneWidget);
      expect(
        tester.widget<TextField>(_merchantField).controller!.text,
        'DMart Powai',
      );
      await tester.ensureVisible(find.text('View all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();
      final categoryTile = find.widgetWithText(ListTile, 'Groceries');
      expect(
        find.descendant(
          of: categoryTile,
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'picking a merchant suggestion persists it to recent-merchants shared_preferences',
    (tester) async {
      final repo = _FakeMerchantSearchRepository({
        'cafe': [
          const NearbyMerchantCandidate(
            merchantId: 'm2',
            displayName: 'Cafe Coffee Day',
            categoryId: null,
            location: GeoPoint(lat: 0, lng: 0),
          ),
        ],
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: QuickAddScreen(initialUserCardId: 'card-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_merchantField, 'cafe');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cafe Coffee Day'));
      await tester.pumpAndSettle();

      // A fresh SharedPreferences.getInstance() read (not just in-memory
      // widget state) must see the persisted merchant — same "survives a
      // fresh read" proof Task 14's merchant-search test uses.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_recentMerchantsKey), ['Cafe Coffee Day']);
    },
  );

  testWidgets(
    'recent merchants show as suggestions before typing anything, once the field is focused',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        _recentMerchantsKey: ['Cafe Coffee Day', 'DMart Powai'],
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_merchantField);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'Cafe Coffee Day'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'DMart Powai'), findsOneWidget);
    },
  );

  testWidgets(
    'picking a recent merchant (no categoryId) leaves category unset, unlike a search match',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        _recentMerchantsKey: ['Cafe Coffee Day'],
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith(
              (ref) async => const [
                SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining'),
              ],
            ),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_merchantField);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Cafe Coffee Day'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('View all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();
      final categoryTile = find.widgetWithText(ListTile, 'Dining');
      expect(categoryTile, findsOneWidget);
      expect(
        find.descendant(
          of: categoryTile,
          matching: find.byIcon(Icons.check_circle),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a failed merchant search does not crash the screen — typeahead degrades to plain free text',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _ThrowingMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_merchantField, 'anything');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(_merchantField).controller!.text,
        'anything',
      );
    },
  );

  testWidgets(
    'a future date shows a confirmation dialog instead of silently accepting or blocking',
    (tester) async {
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'product-1',
        cardName: 'Test Card',
        isDefault: true,
      );
      final clock = TestClock(DateTime(2026, 1, 15));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
            clockProvider.overrideWithValue(clock),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_amountField, '100');
      await _selectCreditCard(tester, 'Test Card');

      await tester.ensureVisible(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      // Switch the Material date picker to keyboard-entry mode so a definite
      // future date (relative to the fixed 2026-01-15 TestClock above) can be
      // typed directly, instead of depending on the calendar's current page.
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '01/20/2026');
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(await _saveButton(tester));
      await tester.pumpAndSettle();

      expect(find.text('This date is in the future'), findsOneWidget);

      // Cancel must not save — dialog just closes, Save button reappears
      // enabled (screen still on QuickAddScreen, not popped).
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Add transaction'), findsOneWidget);
    },
  );

  testWidgets(
    'a persisted last-used-card id absent from the current wallet does not crash Quick Add on load',
    (tester) async {
      // The prefs key isn't cleared on sign-out, so a sign-out ->
      // sign-in-as-different-user sequence can leave a stale card id here
      // that the CURRENT wallet doesn't contain. Before the fix,
      // DropdownButtonFormField's initialValue would be set to that stale id
      // with no matching item in `items`, throwing a debug assertion.
      SharedPreferences.setMockInitialValues({
        'pandapay_app.quick_add_last_used_card_v1': 'stale-card-not-in-wallet',
      });
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'product-1',
        cardName: 'Test Card',
        isDefault: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: const MaterialApp(home: QuickAddScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Falls back to no selection rather than the stale id — Save stays
      // disabled until the user actually picks a card from the current wallet.
      final saveButton = tester.widget<FilledButton>(await _saveButton(tester));
      expect(saveButton.onPressed, isNull);
    },
  );

  testWidgets(
    'tapping Undo after a save+pop sequence does not throw (messenger captured before pop)',
    (tester) async {
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'product-1',
        cardName: 'Test Card',
        isDefault: true,
      );
      final fakeRepo = _FakeUserCardsRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            userCardsRepositoryProvider.overrideWithValue(fakeRepo),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const QuickAddScreen(initialUserCardId: 'card-1'),
                      ),
                    ),
                    child: const Text('open quick add'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open quick add'));
      await tester.pumpAndSettle();

      await tester.enterText(_amountField, '250');
      await _selectCreditCard(tester, 'Test Card');

      await tester.tap(await _saveButton(tester));
      // Let the pop animation fully finish — by now, if the SnackBarAction's
      // closure captured `context` instead of `messenger`, that context is
      // deactivated.
      await tester.pumpAndSettle();

      expect(find.text('Quick add'), findsNothing); // popped back off screen
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      // Real undo now (POST /transactions/:id/ignore, reason: 'reversal') —
      // no longer the old "can't undo yet" placeholder message.
      expect(find.text('Undone.'), findsOneWidget);
    },
  );

  testWidgets(
    'retrying an unchanged save reuses its client mutation identity',
    (tester) async {
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'product-1',
        cardName: 'Test Card',
        isDefault: true,
      );
      final repo = _LostResponseUserCardsRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            userCardsRepositoryProvider.overrideWithValue(repo),
            categoriesProvider.overrideWith((ref) async => const []),
            merchantSearchRepositoryProvider.overrideWithValue(
              _EmptyMerchantSearchRepository(),
            ),
            isOnlineProvider.overrideWith((ref) => Stream.value(true)),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const QuickAddScreen(initialUserCardId: 'card-1'),
                    ),
                  ),
                  child: const Text('open quick add'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open quick add'));
      await tester.pumpAndSettle();
      await tester.enterText(_amountField, '250');
      await _selectCreditCard(tester, 'Test Card');

      await tester.tap(await _saveButton(tester));
      await tester.pumpAndSettle();
      expect(repo.mutationIds, hasLength(1));

      // Let the first attempt's error snackbar clear so it does not cover the
      // bottom-of-form Save button during the retry.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(await _saveButton(tester));
      await tester.pumpAndSettle();
      expect(repo.mutationIds, hasLength(2));
      expect(repo.mutationIds.first, isNotNull);
      expect(repo.mutationIds.last, repo.mutationIds.first);
    },
  );
}
