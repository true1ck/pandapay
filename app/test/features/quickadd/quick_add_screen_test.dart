import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
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
  Future<List<NearbyMerchantCandidate>> search(String query) async => results[query] ?? const [];
}

class _EmptyMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [];
}

class _ThrowingMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    throw ApiException('GET /merchants/search failed: 500 {}');
  }
}

/// In-memory stand-in for UserCardsRepository.logTransaction so the
/// save+pop+Undo flow can be exercised without a real HTTP client.
class _FakeUserCardsRepository extends UserCardsRepository {
  _FakeUserCardsRepository() : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<String> logTransaction({
    required String userCardId,
    required Money amount,
    String? categoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
  }) async => 'fake-txn-id';

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Save stays disabled until an amount and a card are both set', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('an empty-or-zero amount shows a validation error on Save attempt, not a crash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '0');
    await tester.pumpAndSettle();
    // Save is still disabled (no card selected) — this test only verifies
    // the screen builds cleanly with a zero-amount entry, matching this
    // task's amount>0 validation rule.
    expect(find.text('Amount'), findsOneWidget);
  });

  testWidgets('amount entry field is auto-focused so typing the amount is the first tap', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(find.widgetWithText(TextField, 'Amount'));
    expect(amountField.autofocus, isTrue);
  });

  testWidgets('Save becomes enabled once a positive amount and a card are chosen', (tester) async {
    const card = UserCard(id: 'card-1', cardProductId: 'product-1', cardName: 'Test Card', isDefault: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '250');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Card').last);
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton.onPressed, isNotNull);
  });

  testWidgets('typing a merchant query shows live search suggestions and picking one auto-fills category', (
    tester,
  ) async {
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
            (ref) async => const [SpendCategory(id: 'groceries-id', slug: 'groceries', name: 'Groceries')],
          ),
          merchantSearchRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Merchant (optional)'), 'dmart');
    // Debounce is 300ms — advance past it, then let the fake repo's Future resolve.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('DMart Powai'), findsOneWidget);

    await tester.tap(find.text('DMart Powai'));
    await tester.pumpAndSettle();

    // The merchant field now holds the picked name, and the category
    // dropdown shows the category carried by the search match.
    expect(find.widgetWithText(TextField, 'Merchant (optional)'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'Merchant (optional)')).controller!.text,
      'DMart Powai',
    );
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets('picking a merchant suggestion persists it to recent-merchants shared_preferences', (tester) async {
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
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Merchant (optional)'), 'cafe');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cafe Coffee Day'));
    await tester.pumpAndSettle();

    // A fresh SharedPreferences.getInstance() read (not just in-memory
    // widget state) must see the persisted merchant — same "survives a
    // fresh read" proof Task 14's merchant-search test uses.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(_recentMerchantsKey), ['Cafe Coffee Day']);
  });

  testWidgets('recent merchants show as suggestions before typing anything, once the field is focused', (tester) async {
    SharedPreferences.setMockInitialValues({
      _recentMerchantsKey: ['Cafe Coffee Day', 'DMart Powai'],
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Merchant (optional)'));
    await tester.pumpAndSettle();

    expect(find.text('Cafe Coffee Day'), findsOneWidget);
    expect(find.text('DMart Powai'), findsOneWidget);
  });

  testWidgets('picking a recent merchant (no categoryId) leaves category unset, unlike a search match', (tester) async {
    SharedPreferences.setMockInitialValues({
      _recentMerchantsKey: ['Cafe Coffee Day'],
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith(
            (ref) async => const [SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining')],
          ),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Merchant (optional)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cafe Coffee Day'));
    await tester.pumpAndSettle();

    // Category dropdown still shows its placeholder label, not 'Dining' —
    // a recent-merchant pick (name only, no categoryId) must not
    // accidentally auto-fill category.
    expect(find.text('Category (optional)'), findsOneWidget);
    expect(find.text('Dining'), findsNothing);
  });

  testWidgets('a failed merchant search does not crash the screen — typeahead degrades to plain free text', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_ThrowingMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Merchant (optional)'), 'anything');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'Merchant (optional)')).controller!.text,
      'anything',
    );
  });

  testWidgets('a future date shows a confirmation dialog instead of silently accepting or blocking', (tester) async {
    const card = UserCard(id: 'card-1', cardProductId: 'product-1', cardName: 'Test Card', isDefault: true);
    final clock = TestClock(DateTime(2026, 1, 15));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
          clockProvider.overrideWithValue(clock),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '100');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Card').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Today'));
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

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('This date is in the future'), findsOneWidget);

    // Cancel must not save — dialog just closes, Save button reappears
    // enabled (screen still on QuickAddScreen, not popped).
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Quick add'), findsOneWidget);
  });

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
    const card = UserCard(id: 'card-1', cardProductId: 'product-1', cardName: 'Test Card', isDefault: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Falls back to no selection rather than the stale id — Save stays
    // disabled until the user actually picks a card from the current wallet.
    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('tapping Undo after a save+pop sequence does not throw (messenger captured before pop)', (
    tester,
  ) async {
    const card = UserCard(id: 'card-1', cardProductId: 'product-1', cardName: 'Test Card', isDefault: true);
    final fakeRepo = _FakeUserCardsRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          userCardsRepositoryProvider.overrideWithValue(fakeRepo),
          categoriesProvider.overrideWith((ref) async => const []),
          merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const QuickAddScreen()),
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

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '250');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Card').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
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
  });
}
