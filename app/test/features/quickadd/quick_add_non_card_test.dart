import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quick Add for spend that never touched a credit card.
///
/// Until migration 0040 every transaction had to belong to a credit card,
/// so cash, a debit swipe, a salary credit and an SIP simply could not be
/// recorded — which capped a spend tracker at "what my credit cards did".
/// These tests hold the line on the part that is easy to get wrong: a
/// non-card entry must be savable WITHOUT a card, and must not pretend to
/// be a card transaction.
class _EmptyMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [];
}

class _RecordingUserCardsRepository extends UserCardsRepository {
  _RecordingUserCardsRepository() : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  Map<String, dynamic>? lastCall;

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
    lastCall = {
      'userCardId': userCardId,
      'amount': amount,
      'instrument': instrument,
      'entryKind': entryKind,
    };
    return 'fake-txn-id';
  }

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {}
}

Future<Finder> _saveButton(WidgetTester tester) async {
  final finder = find.widgetWithText(FilledButton, 'Save');
  await tester.dragUntilVisible(finder, find.byType(ListView), const Offset(0, -120));
  await tester.pumpAndSettle();
  return finder;
}

Future<void> _pump(WidgetTester tester, _RecordingUserCardsRepository repo) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        merchantSearchRepositoryProvider.overrideWithValue(_EmptyMerchantSearchRepository()),
        userCardsRepositoryProvider.overrideWithValue(repo),
      ],
      child: const MaterialApp(home: QuickAddScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Picks a value in the dropdown whose current label is [currentLabel].
Future<void> _selectDropdown(WidgetTester tester, String currentLabel, String option) async {
  await tester.ensureVisible(find.text(currentLabel).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(currentLabel).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a cash spend saves with no card at all', (tester) async {
    // The regression this protects: Save stayed permanently disabled for
    // every non-card entry because the enable check still demanded a card.
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, repo);

    await tester.enterText(find.byType(TextField).first, '450');
    await tester.pumpAndSettle();

    await _selectDropdown(tester, 'Credit card', 'Cash');

    await tester.tap(await _saveButton(tester));
    await tester.pumpAndSettle();

    expect(repo.lastCall, isNotNull, reason: 'Save must be reachable without a card');
    expect(repo.lastCall!['userCardId'], isNull);
    expect(repo.lastCall!['instrument'], TxnInstrument.cash);
    expect(repo.lastCall!['entryKind'], TxnEntryKind.spend);
  });

  testWidgets('choosing a non-card instrument hides the card picker', (tester) async {
    await _pump(tester, _RecordingUserCardsRepository());
    expect(find.text('Card'), findsOneWidget);

    await _selectDropdown(tester, 'Credit card', 'Cash');

    expect(find.text('Card'), findsNothing);
    expect(
      find.textContaining('won\'t move any card\'s'),
      findsOneWidget,
      reason: 'the user has to be told this does not affect caps or points',
    );
  });

  testWidgets('switching to income moves off credit card automatically', (tester) async {
    // The overwhelmingly common "money in" is a salary or a transfer, and
    // neither arrives on a credit card — so leaving the instrument there
    // would make the usual case wrong. Steering, not forbidding: the server
    // accepts income on a credit card on purpose (a refund or cashback
    // credit is exactly that), and such a row earns nothing and moves no
    // cap state, so the user can pick the card back if they meant a refund.
    await _pump(tester, _RecordingUserCardsRepository());

    await _selectDropdown(tester, 'Spending', 'Money in');

    expect(find.text('Credit card'), findsNothing);
    expect(find.text('UPI from bank'), findsOneWidget);
  });

  testWidgets('an income entry is recorded as income, not as spending', (tester) async {
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, repo);

    await tester.enterText(find.byType(TextField).first, '90000');
    await tester.pumpAndSettle();
    await _selectDropdown(tester, 'Spending', 'Money in');

    await tester.tap(await _saveButton(tester));
    await tester.pumpAndSettle();

    expect(repo.lastCall!['entryKind'], TxnEntryKind.income);
    expect(
      repo.lastCall!['instrument'],
      isNot(TxnInstrument.creditCard),
      reason: 'the form steers money-in away from a credit card by default',
    );
  });

  testWidgets('a credit-card entry still requires a card', (tester) async {
    // The default path must be unchanged: with no card chosen and the
    // instrument left on credit card, Save stays disabled.
    await _pump(tester, _RecordingUserCardsRepository());
    await tester.enterText(find.byType(TextField).first, '450');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(await _saveButton(tester));
    expect(button.onPressed, isNull);
  });
}
