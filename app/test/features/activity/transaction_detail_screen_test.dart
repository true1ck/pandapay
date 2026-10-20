import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/data/local/split_repository.dart';
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchDeletedTransactions() async => const [];

  @override
  Future<void> restoreTransaction(String id) async {}

  TransactionEntry entry;
  final bool failFetch;
  final bool failSplits;
  String? lastIgnoreReason;
  String? lastNote;
  List<TransactionSplit> splits;
  _FakeUserCardsRepository(
    this.entry, {
    this.failFetch = false,
    this.failSplits = false,
    this.splits = const [],
  });

  @override
  Future<TransactionEntry> fetchTransaction(String id) async {
    if (failFetch) throw StateError('offline');
    return entry;
  }

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    lastIgnoreReason = reason;
    entry = TransactionEntry(
      id: entry.id,
      amount: entry.amount,
      occurredAt: entry.occurredAt,
      merchantName: entry.merchantName,
      categoryId: entry.categoryId,
      categoryName: entry.categoryName,
      cardDisplayName: entry.cardDisplayName,
      userCardId: entry.userCardId,
      source: entry.source,
      status: reason == 'transfer' ? 'deleted' : 'ignored',
    );
  }

  @override
  Future<void> updateTransactionNote(String id, String? note) async {
    lastNote = note;
    entry = TransactionEntry(
      id: entry.id,
      amount: entry.amount,
      occurredAt: entry.occurredAt,
      merchantName: entry.merchantName,
      categoryId: entry.categoryId,
      categoryName: entry.categoryName,
      cardDisplayName: entry.cardDisplayName,
      userCardId: entry.userCardId,
      source: entry.source,
      status: entry.status,
      note: note,
    );
  }

  @override
  Future<TransactionSplitDocument> fetchSplitDocument(
    String transactionId,
  ) async => TransactionSplitDocument(
    await fetchSplits(transactionId),
    fingerprint: SplitRepository.fingerprint(splits),
  );

  @override
  Future<TransactionSplitDocument> saveSplitDocument(
    String transactionId,
    TransactionSplitDocument document,
  ) async => TransactionSplitDocument(
    await saveSplits(transactionId, document.splits),
    fingerprint: SplitRepository.fingerprint(document.splits),
  );

  @override
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async {
    if (failSplits) {
      throw ApiException(
        'GET splits failed: 401 {"error":"Missing or invalid access token"}',
      );
    }
    return splits;
  }

  @override
  Future<List<TransactionSplit>> saveSplits(
    String transactionId,
    List<TransactionSplit> next,
  ) async {
    splits = next;
    return splits;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  TransactionEntry? initialEntry,
}) async {
  final router = GoRouter(
    initialLocation: '/activity/t1',
    routes: [
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) => TransactionDetailScreen(
          transactionId: state.pathParameters['id']!,
          initialEntry: initialEntry,
        ),
      ),
      GoRoute(
        path: '/activity/:id/edit',
        builder: (context, state) => const Text('edit screen'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [userCardsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'keeps the tapped spending row visible when the detail fetch is offline',
    (tester) async {
      final tapped = TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 10, 17),
        merchantName: 'Offline Merchant',
        categoryName: 'Shopping',
        cardDisplayName: 'HDFC Card',
        userCardId: 'uc1',
        source: 'sms',
        status: 'active',
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(tapped, failFetch: true),
        initialEntry: tapped,
      );

      expect(find.text('Offline Merchant'), findsOneWidget);
      expect(find.text('HDFC Card'), findsOneWidget);
      expect(find.text('Transaction not available offline'), findsNothing);
    },
  );

  testWidgets(
    'shows merchant, card, category, and source for an active transaction',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(750),
          occurredAt: DateTime(2026, 3, 1),
          merchantName: 'Corner Store',
          categoryName: 'Groceries',
          cardDisplayName: 'My Axis Card',
          userCardId: 'uc1',
          source: 'sms',
          status: 'active',
        ),
      );
      await _pump(tester, repo: repo);

      expect(find.text('Corner Store'), findsOneWidget);
      expect(find.text('My Axis Card'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('SMS'), findsOneWidget);
      expect(
        find.text('Refund, reversal, or delete transaction'),
        findsOneWidget,
      );
      expect(find.text('Edit transaction'), findsOneWidget);
    },
  );

  testWidgets('opens the edit page from the transaction detail action', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Corner Store',
        userCardId: 'uc1',
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final editButton = find.text('Edit transaction');
    await tester.ensureVisible(editButton);
    await tester.tap(editButton);
    await tester.pumpAndSettle();

    expect(find.text('edit screen'), findsOneWidget);
  });

  testWidgets('saves a note and keeps it visible on the transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Corner Store',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final addNote = find.text('Add a note');
    await tester.ensureVisible(addNote);
    await tester.tap(addNote);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Bought for the office');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastNote, 'Bought for the office');
    expect(find.text('Bought for the office'), findsOneWidget);
  });

  testWidgets('saves and displays a split across two people', (tester) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final splitButton = find.text('Split this expense');
    await tester.ensureVisible(splitButton);
    await tester.tap(splitButton);
    await tester.pumpAndSettle();

    expect(find.text('Split this expense'), findsOneWidget);
    final amounts = find.byType(TextField);
    await tester.enterText(amounts.at(0), '400');
    await tester.tap(find.text('Add a share'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), '600');
    await tester.enterText(find.byType(TextField).at(1), 'Priya');
    await tester.enterText(find.byType(TextField).at(3), 'Sujay');

    await tester.tap(find.text('Save split'));
    await tester.pumpAndSettle();
    expect(
      find.text('Saved on this device — waiting to sync.'),
      findsOneWidget,
    );
    expect(repo.splits, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.splits, hasLength(2));
    expect(repo.splits[0].amount, Money.fromRupees(400));
    expect(repo.splits[0].note, 'Priya');
    expect(repo.splits[1].amount, Money.fromRupees(600));
    expect(repo.splits[1].note, 'Sujay');
    expect(find.text('Split across 2 shares'), findsOneWidget);
    expect(find.text('Your share: ₹0.00'), findsOneWidget);
  });

  testWidgets(
    'editing shares validates amounts and preserves card and category',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(1000),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'manual',
          status: 'active',
        ),
        splits: [
          TransactionSplit(
            amount: Money.fromRupees(400),
            note: 'Priya',
            userCardId: 'uc1',
            categoryId: 'category1',
          ),
        ],
      );
      await _pump(tester, repo: repo);
      final button = find.text('Split across 1 share');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      for (final invalid in ['-10', '1.001', 'NaN', '1001']) {
        await tester.enterText(find.byType(TextField).at(0), invalid);
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save split'),
              )
              .onPressed,
          isNull,
        );
      }
      await tester.enterText(find.byType(TextField).at(0), '300.25');
      await tester.pump();
      await tester.tap(find.text('Save split'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(repo.splits.single.amount, Money.fromRupees(300.25));
      expect(repo.splits.single.userCardId, 'uc1');
      expect(repo.splits.single.categoryId, 'category1');
    },
  );

  testWidgets('can clear an existing split', (tester) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
      splits: [TransactionSplit(amount: Money.fromRupees(400), note: 'Priya')],
    );
    await _pump(tester, repo: repo);

    final splitButton = find.text('Split across 1 share');
    await tester.ensureVisible(splitButton);
    await tester.tap(splitButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.tap(find.text('Clear split'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.splits, isEmpty);
    expect(find.text('Split this expense'), findsOneWidget);
  });

  testWidgets(
    'does not expose the raw token error when split loading is rejected',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(1000),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'sms',
          status: 'active',
        ),
        failSplits: true,
      );
      await _pump(tester, repo: repo);

      expect(
        find.textContaining('Missing or invalid access token'),
        findsNothing,
      );
      expect(find.textContaining("We couldn't load this yet"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'an ignored transaction shows the exclusion banner and no ignore action',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(750),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'manual',
          status: 'ignored',
        ),
      );
      await _pump(tester, repo: repo);

      expect(
        find.textContaining('excluded from caps and rankings'),
        findsOneWidget,
      );
      expect(
        find.text('Refund, reversal, or delete transaction'),
        findsNothing,
      );
    },
  );

  testWidgets('cardless UPI and unknown category are shown honestly', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(30),
        occurredAt: DateTime(2026, 10, 5),
        merchantName: 'Balaji enterprises',
        rail: TxnRail.upiQr,
        categoryName: null,
        cardDisplayName: null,
        instrumentKnown: false,
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    expect(find.text('UPI / bank account'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Assign category'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('marking ignored calls the repository with the chosen reason', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();

    expect(repo.lastIgnoreReason, 'refund');
  });

  testWidgets('labels the transfer action as delete transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Delete transaction'), findsOneWidget);
    await tester.tap(find.text('Delete transaction'));
    await tester.pumpAndSettle();

    expect(repo.lastIgnoreReason, 'transfer');
  });
}
