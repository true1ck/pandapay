import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/needs_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastLogArgs;

  @override
  Future<String> logTransaction({
    String? userCardId,
    required dynamic amount,
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
    lastLogArgs = {
      'userCardId': userCardId,
      'amount': amount,
      'categoryId': categoryId,
    };
    return 'fake-txn-id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  required NeedsReviewRepository reviews,
  CommitmentsRepository? commitments,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        needsReviewRepositoryProvider.overrideWithValue(reviews),
        if (commitments != null)
          commitmentsRepositoryProvider.overrideWithValue(commitments),
      ],
      child: const MaterialApp(home: NeedsReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late NeedsReviewRepository reviews;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    reviews = NeedsReviewRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
  });
  tearDown(() => db.close());

  testWidgets('shows an empty state when nothing needs review', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets('shows the raw sender and body for a queued item', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'unparseable_amount',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('VM-HDFCBK'), findsOneWidget);
    expect(find.text('Rs.499 spent at AMAZON'), findsOneWidget);
    expect(find.textContaining('unparseable_amount'), findsOneWidget);
  });

  testWidgets('Ignore message removes the item from the queue', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'not really a txn',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Ignore message'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('Review transaction opens a clear bottom-sheet review form', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'txn-review-1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'no_transaction_match',
        receivedAt: DateTime(2026, 10, 1),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Review transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Review this transaction'), findsOneWidget);
    expect(
      find.textContaining('possible transaction in this message'),
      findsOneWidget,
    );
    expect(find.text('Save transaction'), findsOneWidget);
    expect(find.text('Amount (₹)'), findsOneWidget);
    expect(find.text('Merchant or sender'), findsOneWidget);
  });

  testWidgets('Dismiss all clears every queued item at once', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 's1',
        body: 'b1',
        receivedAt: DateTime.now(),
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: '2',
        sender: 's2',
        body: 'b2',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Dismiss all'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('Save bill opens a review sheet and only then persists it', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-1',
        sender: 'JX-MYTNEU-S',
        body:
            'Your HDFC BANK CREDIT CARD bill of Rs. 10148.00 is ready. Pay by 2026-10-09.',
        receivedAt: DateTime(2026, 10, 1),
        kind: NeedsReviewKind.commitment,
      ),
    );
    final commitments = CommitmentsRepository(namespace: 'user:test');
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save bill'));
    await tester.pumpAndSettle();

    expect(find.text('Review bill details'), findsOneWidget);
    expect(
      find.textContaining('Nothing is saved until you tap Save bill.'),
      findsOneWidget,
    );
    expect(await commitments.fetchAll(), isEmpty);

    final sheetSave = find.widgetWithText(FilledButton, 'Save bill');
    await tester.tap(sheetSave.last);
    await tester.pumpAndSettle();

    final saved = await commitments.fetchAll();
    expect(saved, hasLength(1));
    expect(saved.single.amount?.paise, 1014800);
    expect(saved.single.dueOn, DateTime(2026, 10, 9));
    expect(saved.single.isUserConfirmed, isTrue);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('a commitment can be dismissed from its own close action', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-2',
        sender: 'VZ-VICARE-S',
        body: 'Your mobile invoice is ready for download.',
        receivedAt: DateTime(2026, 10, 1),
        kind: NeedsReviewKind.commitment,
      ),
    );
    final commitments = CommitmentsRepository(namespace: 'user:test');
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    await tester.tap(find.byTooltip('Dismiss message'));
    await tester.pumpAndSettle();

    expect(await reviews.fetchAll(), isEmpty);
    final tombstones = await commitments.fetchAll();
    expect(tombstones.single.status, CommitmentStatus.dismissed);
  });
}
