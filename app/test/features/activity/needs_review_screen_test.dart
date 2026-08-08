import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/needs_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastLogArgs;

  @override
  Future<void> logTransaction({required String userCardId, required dynamic amount, String? categoryId}) async {
    lastLogArgs = {'userCardId': userCardId, 'amount': amount, 'categoryId': categoryId};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, {required _FakeUserCardsRepository repo}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: NeedsReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows an empty state when nothing needs review', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository());
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets('shows the raw sender and body for a queued item', (tester) async {
    await NeedsReviewRepository().add(NeedsReviewItem(
      id: '1',
      sender: 'VM-HDFCBK',
      body: 'Rs.499 spent at AMAZON',
      reason: 'unparseable_amount',
      receivedAt: DateTime.now(),
    ));
    await _pump(tester, repo: _FakeUserCardsRepository());

    expect(find.text('VM-HDFCBK'), findsOneWidget);
    expect(find.text('Rs.499 spent at AMAZON'), findsOneWidget);
    expect(find.textContaining('unparseable_amount'), findsOneWidget);
  });

  testWidgets('"Not a transaction" removes the item from the queue', (tester) async {
    await NeedsReviewRepository().add(NeedsReviewItem(
      id: '1',
      sender: 'VM-HDFCBK',
      body: 'not really a txn',
      receivedAt: DateTime.now(),
    ));
    await _pump(tester, repo: _FakeUserCardsRepository());

    await tester.tap(find.text('Not a transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await NeedsReviewRepository().fetchAll(), isEmpty);
  });

  testWidgets('Dismiss all clears every queued item at once', (tester) async {
    await NeedsReviewRepository().add(NeedsReviewItem(id: '1', sender: 's1', body: 'b1', receivedAt: DateTime.now()));
    await NeedsReviewRepository().add(NeedsReviewItem(id: '2', sender: 's2', body: 'b2', receivedAt: DateTime.now()));
    await _pump(tester, repo: _FakeUserCardsRepository());

    await tester.tap(find.text('Dismiss all'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await NeedsReviewRepository().fetchAll(), isEmpty);
  });
}
