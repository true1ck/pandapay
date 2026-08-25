import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmptyMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [];
}

class _OfflineUserCardsRepository extends UserCardsRepository {
  _OfflineUserCardsRepository() : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
  }) async {
    throw ApiException('no connectivity');
  }
}

/// The Quick Add form is a ListView and, since the "Kind" and "Paid with"
/// selectors were added for non-card entries (cash, income, investments),
/// the Save button sits below the fold of the 600px test viewport. A
/// ListView doesn't build off-screen children, so Save has to be scrolled
/// into existence before any finder can reach it.
Future<Finder> _saveButton(WidgetTester tester) async {
  final finder = find.widgetWithText(FilledButton, 'Save');
  await tester.dragUntilVisible(finder, find.byType(ListView), const Offset(0, -120));
  await tester.pumpAndSettle();
  return finder;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a save that fails while offline queues to the outbox instead of showing a bare error', (
    tester,
  ) async {
    const card = UserCard(id: 'card-1', cardProductId: 'product-1', cardName: 'Test Card', isDefault: true);
    final container = ProviderContainer(
      overrides: [
        userCardsProvider.overrideWith((ref) async => const [card]),
        userCardsRepositoryProvider.overrideWithValue(_OfflineUserCardsRepository()),
        categoriesProvider.overrideWith((ref) async => const []),
        merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
      ],
    );
    addTearDown(container.dispose);
    // Force isOnlineProvider to start emitting before _save() reads it —
    // StreamProviders are lazy and nothing else in this widget tree
    // watches it, so without this its first read would still be
    // AsyncLoading (a Stream's first event is never synchronous, even for
    // Stream.value), defaulting _save()'s `?? true` fallback to "online."
    container.listen(isOnlineProvider, (_, _) {});

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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

    await tester.tap(await _saveButton(tester));
    await tester.pumpAndSettle();

    expect(find.textContaining("Saved offline"), findsOneWidget);

    final outbox = await container.read(outboxRepositoryProvider.future);
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.userCardId, 'card-1');
    expect(pending.single.amountPaise, Money.fromRupees(250).paise);
  });
}
