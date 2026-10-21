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
  Map<String, dynamic>? lastOverrideArgs;

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
  Future<bool> overrideSmsFact({
    required String sourceKey,
    required int factIndex,
    required Map<String, dynamic> patch,
    String? reason,
  }) async {
    lastOverrideArgs = {
      'sourceKey': sourceKey,
      'factIndex': factIndex,
      'patch': patch,
      'reason': reason,
    };
    return true;
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
  await tester.binding.setSurfaceSize(const Size(1000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
    final future = DateTime.now().add(const Duration(days: 10));
    final dueOn = DateTime(future.year, future.month, future.day);
    final dueDateText = '${dueOn.year}-${dueOn.month.toString().padLeft(2, '0')}-${dueOn.day.toString().padLeft(2, '0')}';
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-1',
        sender: 'JX-MYTNEU-S',
        body:
            'Your HDFC BANK CREDIT CARD bill of Rs. 10148.00 is ready. Pay by $dueDateText.',
        receivedAt: DateTime.now(),
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
    expect(saved.single.dueOn, dueOn);
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

  testWidgets(
    'screenshot security case (HDFC Transaction Check Alert) shows Dismiss alert and not Review transaction',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'sec-1',
          sender: 'VM-HDFCBK-S',
          body:
              'Transaction Check Alert! We tried to contact you twice to confirm the following txn: Rs.2,000.00 on Card XX4321 at AMAZON on 16-10-26. If this was not you, call 1860-266-2661',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Dismiss alert'), findsOneWidget);

      await tester.tap(find.text('Dismiss alert'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'screenshot service case (ViCARE call forwarding) shows Dismiss alert and not Review transaction',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'serv-1',
          sender: 'ViCARE',
          body: 'Call Forwarding is now active',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Dismiss alert'), findsOneWidget);
    },
  );

  testWidgets(
    'screenshot investment settlement case (Kotak Neo) shows Review transfer and not Review transaction',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'kotak-1',
          sender: 'KOTAKN',
          body:
              'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account. You should receive funds in A/c XX1234 by EOD.',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Investment settlement payout'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Review transfer'), findsOneWidget);
    },
  );

  testWidgets(
    'ambiguous account debit shows Choose card/account action label',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'ambig-1',
          sender: 'HDFCBK',
          body: 'Rs.500 spent',
          reason: 'ambiguous_account_debit',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Choose card/account'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
    },
  );

  testWidgets(
    'saving reviewed transaction syncs structured fact override for 64-char source key',
    (tester) async {
      final key = 'f' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'VM-HDFCBK',
          body: 'Rs.499 spent at AMAZON',
          reason: 'no_transaction_match',
          receivedAt: DateTime(2026, 10, 1),
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      await tester.tap(find.text('Review transaction'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect((repo.lastOverrideArgs!['patch'] as Map)['amountRole'], 'posted');
      expect(await reviews.fetchAll(), isEmpty);
    },
  );
}
