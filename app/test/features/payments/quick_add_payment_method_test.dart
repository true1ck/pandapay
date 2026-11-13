import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quick Add "Paid with": the chosen payment method reaches the outbox row
/// (the phone's queue that logTransaction is later called from), and a save
/// that never touched it is unchanged.
class _EmptyMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [];

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

class _Repo extends UserCardsRepository {
  _Repo() : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  final AppDatabase db = openInMemoryForTesting();

  Map<String, Object?>? get lastRow {
    final rows = db.db.select('SELECT * FROM transaction_outbox_entries');
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.last);
  }

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {}
}

Future<void> _pump(WidgetTester tester, _Repo repo) async {
  tester.view.physicalSize = const Size(2400, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('legacy'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(repo.db)),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        merchantSearchRepositoryProvider.overrideWithValue(
          _EmptyMerchantSearchRepository(),
        ),
        userCardsRepositoryProvider.overrideWithValue(repo),
      ],
      child: const MaterialApp(home: QuickAddScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> _enterAmountAndSave(WidgetTester tester, String amount) async {
  await tester.enterText(
    find.byKey(const ValueKey('quick-add-amount-field')),
    amount,
  );
  await tester.pumpAndSettle();
  final save = find.ancestor(
    of: find.byIcon(Icons.save_outlined),
    matching: find.byType(FilledButton),
  );
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a cash save that never touches More stores no payment method', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await _tapText(tester, 'Cash');
    await _enterAmountAndSave(tester, '450');

    final row = repo.lastRow!;
    expect(row['instrument'], 'cash');
    expect(row['payment_method'], isNull);
  });

  testWidgets('UPI / bank with no method chosen stores no payment method', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await _tapText(tester, 'UPI / bank');
    await _enterAmountAndSave(tester, '450');

    expect(repo.lastRow!['instrument'], 'upi_bank');
    expect(repo.lastRow!['payment_method'], isNull);
  });

  testWidgets('Cheque saves as UPI / bank + cheque', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo);
    expect(find.byKey(const ValueKey('payment-chip-method-cheque')),
        findsNothing,
        reason: 'the default credit-card selection never offers a cheque');
    await _tapText(tester, 'UPI / bank');
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _enterAmountAndSave(tester, '12000');

    final row = repo.lastRow!;
    expect(row['instrument'], 'upi_bank');
    expect(row['payment_method'], 'cheque');
    expect(row['user_card_id'], isNull);
  });

  testWidgets('a method picked from More (EMI on debit) is saved', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await _tapText(tester, 'Debit');
    await _tapKey(tester, 'payment-more-chip');
    await _tapKey(tester, 'payment-more-option-emi');
    await _enterAmountAndSave(tester, '3000');

    final row = repo.lastRow!;
    expect(row['instrument'], 'debit_card');
    expect(row['payment_method'], 'emi');
  });

  testWidgets('switching to Cash after a Cheque drops the method', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await _tapText(tester, 'UPI / bank');
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _tapText(tester, 'Cash');
    await _enterAmountAndSave(tester, '100');

    final row = repo.lastRow!;
    expect(row['instrument'], 'cash');
    expect(row['payment_method'], isNull);
  });

  testWidgets('income moves off credit card and keeps nothing invalid', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await _tapText(tester, 'Income');
    expect(find.text('Credit card'), findsNothing);
    expect(find.text('UPI / bank'), findsOneWidget);
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _enterAmountAndSave(tester, '90000');

    final row = repo.lastRow!;
    expect(row['entry_kind'], 'income');
    expect(row['instrument'], 'upi_bank');
    expect(row['payment_method'], 'cheque');
  });
}
