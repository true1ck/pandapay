import 'dart:async';

import 'package:pandapay/data/catalogue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/design/widgets.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// D1: covers what the original widget_test.dart's "Chunk 18" cases did,
/// as its own file — that suite currently fails to even compile due to
/// unrelated in-flight work elsewhere in main.dart (an H6 Appearance
/// theme-mode wiring change), not anything D1 touches.
class _FakeUserCardsRepository implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  List<Map<String, dynamic>>? lastFetchArgs;
  _FakeUserCardsRepository(this.transactions);

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async {
    lastFetchArgs = [
      {
        'from': from,
        'to': to,
        'cardId': cardId,
        'categoryId': categoryId,
        'source': source,
        'query': query,
      },
    ];
    var result = transactions;
    if (cardId != null) {
      result = result.where((t) => t.userCardId == cardId).toList();
    }
    if (categoryId != null) {
      result = result
          .where(
            (t) =>
                t.categoryId == categoryId || t.parentCategoryId == categoryId,
          )
          .toList();
    }
    if (from != null) {
      final start = DateTime(from.year, from.month, from.day);
      result = result.where((t) {
        final date = DateTime(
          t.occurredAt.year,
          t.occurredAt.month,
          t.occurredAt.day,
        );
        return !date.isBefore(start);
      }).toList();
    }
    if (to != null) {
      final endExclusive = DateTime(to.year, to.month, to.day + 1);
      result = result.where((t) {
        final date = DateTime(
          t.occurredAt.year,
          t.occurredAt.month,
          t.occurredAt.day,
        );
        return date.isBefore(endExclusive);
      }).toList();
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntry _txn({
  required String id,
  required Money amount,
  required DateTime occurredAt,
  String? merchantName,
  String? categoryId,
  String? categoryName,
  String? subcategoryName,
  String? note,
  List<TransactionTag> tags = const [],
  String userCardId = 'uc1',
  TxnEntryKind entryKind = TxnEntryKind.spend,
  String source = 'manual',
}) {
  return TransactionEntry(
    id: id,
    amount: amount,
    occurredAt: occurredAt,
    merchantName: merchantName,
    categoryId: categoryId,
    categoryName: categoryName,
    subcategoryName: subcategoryName,
    tags: tags,
    userCardId: userCardId,
    entryKind: entryKind,
    source: source,
    status: 'active',
    note: note,
  );
}

DateTime _currentMonthTime(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  required List<UserCard> cards,
  ActivityScreen activityScreen = const ActivityScreen(),
  List<Override> overrides = const [],
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(body: activityScreen),
      ),
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) =>
            Text('detail ${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        foreignPaymentsProvider.overrideWith((ref) async => const []),
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        sessionInitProvider.overrideWith((ref) async {}),
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => cards),
        categoriesProvider.overrideWith((ref) async => const []),
        ...overrides,
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keeps prior rows during a transaction refresh', (tester) async {
    final row = _txn(
      id: 'steady-row',
      amount: Money.fromRupees(250),
      occurredAt: DateTime.now(),
      merchantName: 'Steady Merchant',
    );
    final pendingReload = Completer<List<TransactionEntry>>();
    var loads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          sessionInitProvider.overrideWith((ref) async {}),
          foreignPaymentsProvider.overrideWith((ref) async => const []),
          activityTransactionsProvider.overrideWith((ref) {
            loads++;
            return loads == 1 ? Future.value([row]) : pendingReload.future;
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: ActivityScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Steady Merchant'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ActivityScreen)),
    );
    container.invalidate(activityTransactionsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Steady Merchant'), findsOneWidget);
    expect(find.byType(SkeletonList), findsNothing);

    pendingReload.complete([row]);
    await tester.pumpAndSettle();
  });

  testWidgets('initial tag/category drilldown only shows matching spending', (
    tester,
  ) async {
    const trip = TransactionTag(id: 'trip', name: 'Thailand trip');
    const office = TransactionTag(id: 'office', name: 'Office');
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'match',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 8, 10),
        merchantName: 'Bangkok Cafe',
        categoryId: 'dining',
        categoryName: 'Dining',
        tags: [trip],
      ),
      _txn(
        id: 'wrong-tag',
        amount: Money.fromRupees(250),
        occurredAt: DateTime(2026, 8, 11),
        merchantName: 'Office Cafe',
        categoryId: 'dining',
        categoryName: 'Dining',
        tags: [office],
      ),
      _txn(
        id: 'wrong-category',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 8, 12),
        merchantName: 'Bangkok Taxi',
        categoryId: 'travel',
        categoryName: 'Travel',
        tags: [trip],
      ),
      _txn(
        id: 'income',
        amount: Money.fromRupees(10000),
        occurredAt: DateTime(2026, 8, 13),
        merchantName: 'Cafe refund',
        categoryId: 'dining',
        categoryName: 'Dining',
        tags: [trip],
        entryKind: TxnEntryKind.income,
      ),
    ]);
    await _pump(
      tester,
      repo: repo,
      cards: const [],
      activityScreen: ActivityScreen(
        initialTagIds: {'trip'},
        initialCategoryId: 'dining',
        initialFrom: DateTime(2026, 8, 1),
        initialTo: DateTime(2026, 8, 31),
        initialSpendOnly: true,
      ),
    );

    expect(find.text('Bangkok Cafe'), findsOneWidget);
    expect(find.text('Office Cafe'), findsNothing);
    expect(find.text('Bangkok Taxi'), findsNothing);
    expect(find.text('Cafe refund'), findsNothing);
    expect(find.text('Spending'), findsOneWidget);
    expect(repo.lastFetchArgs?.single['categoryId'], 'dining');
    expect(repo.lastFetchArgs?.single['from'], DateTime(2026, 8, 1));
    expect(repo.lastFetchArgs?.single['to'], DateTime(2026, 8, 31));
  });

  testWidgets('shows an empty state when there are no transactions', (
    tester,
  ) async {
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(const []),
      cards: const [],
    );
    expect(find.text('No activity this month'), findsOneWidget);
  });

  testWidgets('says Unknown merchant or Unknown sender, never the raw UNKNOWN', (
    tester,
  ) async {
    final now = DateTime.now();
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'spend',
        amount: Money.fromRupees(400),
        occurredAt: now,
        merchantName: 'UNKNOWN',
      ),
      _txn(
        id: 'income',
        amount: Money.fromRupees(900),
        occurredAt: now,
        merchantName: 'UNKNOWN',
        entryKind: TxnEntryKind.income,
      ),
      _txn(
        id: 'named',
        amount: Money.fromRupees(100),
        occurredAt: now,
        merchantName: 'Corner Shop',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Unknown merchant'), findsOneWidget);
    expect(find.text('Unknown sender'), findsOneWidget);
    expect(find.text('Corner Shop'), findsOneWidget);
    expect(find.text('UNKNOWN'), findsNothing);
  });

  testWidgets('groups transactions by day and shows a spend summary', (
    tester,
  ) async {
    final now = DateTime.now();
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 't1',
        amount: Money.fromRupees(500),
        occurredAt: now,
        merchantName: 'Today Shop',
      ),
      _txn(
        id: 't2',
        amount: Money.fromRupees(300),
        occurredAt: now.subtract(const Duration(days: 1)),
        merchantName: 'Yesterday Shop',
      ),
    ]);
    await _pump(
      tester,
      repo: repo,
      cards: const [],
      activityScreen: ActivityScreen(
        initialFrom: now.subtract(const Duration(days: 1)),
        initialTo: now,
      ),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today Shop'), findsOneWidget);
    expect(find.text('Yesterday Shop'), findsOneWidget);
    expect(find.text('2 txns'), findsOneWidget);
  });

  testWidgets(
    'sorts the list from the Sort button and shows each row\'s date',
    (tester) async {
      final now = DateTime.now();
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 't1',
          amount: Money.fromRupees(500),
          occurredAt: now,
          merchantName: 'Zeta Shop',
        ),
        _txn(
          id: 't2',
          amount: Money.fromRupees(9000),
          occurredAt: now.subtract(const Duration(days: 1)),
          merchantName: 'Alpha Shop',
        ),
        _txn(
          id: 't3',
          amount: Money.fromRupees(40),
          occurredAt: now.subtract(const Duration(days: 1)),
          merchantName: 'Mid Shop',
        ),
      ]);
      await _pump(
        tester,
        repo: repo,
        cards: const [],
        activityScreen: ActivityScreen(
          initialFrom: now.subtract(const Duration(days: 1)),
          initialTo: now,
        ),
      );
      double top(String name) => tester.getTopLeft(find.text(name)).dy;

      // Default: newest first, grouped by day.
      expect(find.text('Today'), findsOneWidget);
      expect(top('Zeta Shop'), lessThan(top('Alpha Shop')));
      expect(find.text('Newest'), findsOneWidget);

      await tester.tap(find.byKey(const Key('activity-sort-button')));
      await tester.pumpAndSettle();
      expect(find.text('Sort activity'), findsOneWidget);
      for (final label in [
        'Newest first',
        'Oldest first',
        'Highest amount',
        'Lowest amount',
        'Merchant A to Z',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('activity-sort-highestAmount')));
      await tester.pumpAndSettle();
      // Flat list, biggest first, no day headings; the Sort button says so.
      expect(find.text('Today'), findsNothing);
      expect(top('Alpha Shop'), lessThan(top('Zeta Shop')));
      expect(top('Zeta Shop'), lessThan(top('Mid Shop')));
      expect(find.text('Highest'), findsOneWidget);
      expect(
        find.textContaining('Today ·'),
        findsOneWidget,
        reason: 'the row for today shows its own date',
      );
      expect(find.textContaining('Yesterday ·'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('activity-sort-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('activity-sort-merchantAz')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-sort-merchantAz')));
      await tester.pumpAndSettle();
      expect(top('Alpha Shop'), lessThan(top('Mid Shop')));
      expect(top('Mid Shop'), lessThan(top('Zeta Shop')));

      // Choosing newest first again brings the day headings back.
      await tester.tap(find.byKey(const Key('activity-sort-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-sort-newest')));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Newest'), findsOneWidget);
    },
  );

  testWidgets('does not count a credit-card bill payment as spending', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'bill',
        amount: Money.fromRupees(10148),
        occurredAt: DateTime.now(),
        merchantName: 'Credit card bill payment',
        entryKind: TxnEntryKind.transfer,
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Credit card bill payment'), findsOneWidget);
    expect(find.text('No spending'), findsOneWidget);
    // The transfer amount remains visible on its Activity row; the summary
    // is the part that must not count it as spending.
    expect(find.text('₹10,148.00'), findsOneWidget);
  });

  testWidgets('shows incoming and outgoing totals with direction signs', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'income',
        amount: Money.fromRupees(9000),
        occurredAt: DateTime.now(),
        merchantName: 'Salary',
        entryKind: TxnEntryKind.income,
      ),
      _txn(
        id: 'spend',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime.now(),
        merchantName: 'Cafe',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Money in'), findsOneWidget);
    expect(find.text('Money out'), findsOneWidget);
    expect(find.text('+₹9,000'), findsOneWidget);
    expect(find.text('−₹1,250'), findsOneWidget);
    // The slim summary strip has no arrows of its own; each row's tile has one.
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
  });

  testWidgets('compacts large summary totals to keep both metrics visible', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'income',
        amount: Money.fromRupees(3388662.84),
        occurredAt: DateTime.now(),
        entryKind: TxnEntryKind.income,
      ),
      _txn(
        id: 'spend',
        amount: Money.fromRupees(4008896.21),
        occurredAt: DateTime.now(),
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('+₹33.89L'), findsOneWidget);
    expect(find.text('−₹40.09L'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the transaction time and identifies SMS timestamps', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'sms-time',
        amount: Money.fromRupees(1200),
        occurredAt: _currentMonthTime(15, 20),
        source: 'sms',
        merchantName: 'Timestamped Shop',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.textContaining('3:20 PM · SMS'), findsOneWidget);
  });

  testWidgets('shows P2P transfers as payee name with a Transfer chip', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'transfer-a',
        amount: Money.fromRupees(150),
        occurredAt: _currentMonthTime(18, 10),
        source: 'sms',
        merchantName: 'Transfer to Zephr',
        categoryName: 'Other',
        entryKind: TxnEntryKind.transfer,
      ),
      _txn(
        id: 'transfer-b',
        amount: Money.fromRupees(147),
        occurredAt: _currentMonthTime(18, 5),
        source: 'sms',
        merchantName: 'Transfer to Akriti',
        categoryName: 'Food',
        entryKind: TxnEntryKind.transfer,
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Zephr'), findsOneWidget);
    expect(find.text('Akriti'), findsOneWidget);
    expect(find.text('Transfer to Zephr'), findsNothing);
    expect(find.text('Transfer'), findsNWidgets(2));

    // `other` is one of the canonical fifteen, so a transfer whose category is
    // bare Other loses it to keep the subtitle short — a user picking Other
    // loses it too, and nothing here can tell the two apart.
    final zephrSubtitle = tester
        .widget<Text>(find.textContaining('6:10 PM · SMS'))
        .data!;
    expect(zephrSubtitle.contains('Other'), isFalse);
    final akritiSubtitle = tester
        .widget<Text>(find.textContaining('6:05 PM · SMS'))
        .data!;
    expect(akritiSubtitle.contains('Food'), isTrue);
  });

  testWidgets('reads the payee from a loosely spaced name and keeps a '
      'transfer subcategory', (tester) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'transfer-c',
        amount: Money.fromRupees(90),
        occurredAt: _currentMonthTime(18, 10),
        source: 'sms',
        merchantName: 'Transfer to  Meera',
        categoryName: 'Rent',
        entryKind: TxnEntryKind.transfer,
      ),
      _txn(
        id: 'transfer-d',
        amount: Money.fromRupees(60),
        occurredAt: _currentMonthTime(18, 5),
        source: 'sms',
        merchantName: 'Transfer to Rahul',
        categoryName: 'Other',
        subcategoryName: 'UPI',
        entryKind: TxnEntryKind.transfer,
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Meera'), findsOneWidget);
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('Transfer'), findsNWidgets(2));
    // A real subcategory earns its place back.
    final rahulSubtitle = tester
        .widget<Text>(find.textContaining('6:05 PM · SMS'))
        .data!;
    expect(rahulSubtitle.contains('Other · UPI'), isTrue);
  });

  testWidgets('drops the bare Other category only on transfer rows', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'spend-e',
        amount: Money.fromRupees(430),
        occurredAt: _currentMonthTime(18, 10),
        source: 'sms',
        merchantName: 'BOMBAY BAZAAR',
        categoryName: 'Other',
      ),
      _txn(
        id: 'transfer-a',
        amount: Money.fromRupees(150),
        occurredAt: _currentMonthTime(18, 5),
        source: 'sms',
        merchantName: 'Transfer to Zephr',
        categoryName: 'Other',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    final bazaarSubtitle = tester
        .widget<Text>(find.textContaining('6:10 PM · SMS'))
        .data!;
    expect(bazaarSubtitle.contains('Other'), isTrue);
    final zephrSubtitle = tester
        .widget<Text>(find.textContaining('6:05 PM · SMS'))
        .data!;
    expect(zephrSubtitle.contains('Other'), isFalse);
  });

  testWidgets('keeps the transfer verb when a refund takes the chip slot', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'refund-transfer',
        amount: Money.fromRupees(150),
        occurredAt: _currentMonthTime(18, 10),
        source: 'sms',
        merchantName: 'Transfer to Zephr',
        categoryName: 'Other',
        note: 'Excluded from spend [ignored: refund]',
      ),
      _txn(
        id: 'reversal-transfer',
        amount: Money.fromRupees(147),
        occurredAt: _currentMonthTime(18, 5),
        source: 'sms',
        merchantName: 'Transfer to Akriti',
        note: 'Excluded from spend [ignored: reversal]',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    // The payee-first title exists only to free the chip slot. With Refund or
    // Reversal in it, the name keeps its verb so the row does not lose both.
    expect(find.text('Transfer to Zephr'), findsOneWidget);
    expect(find.text('Transfer to Akriti'), findsOneWidget);
    expect(find.text('Zephr'), findsNothing);
    expect(find.text('Akriti'), findsNothing);
    expect(find.text('Refund'), findsOneWidget);
    expect(find.text('Reversal'), findsOneWidget);
    expect(find.text('Transfer'), findsNothing);
    // No chip on the row, so nothing replaces the category segment either.
    final refundSubtitle = tester
        .widget<Text>(find.textContaining('6:10 PM · SMS'))
        .data!;
    expect(refundSubtitle.contains('Other'), isTrue);
  });

  testWidgets('offers useful date presets for faster activity tracking', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 'monthly',
        amount: Money.fromRupees(500),
        occurredAt: DateTime.now(),
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    await tester.tap(find.text('This month').first);
    await tester.pumpAndSettle();
    expect(find.text('This month').last, findsOneWidget);
    expect(find.text('Last month'), findsOneWidget);
    expect(find.text('Last 90 days'), findsOneWidget);

    await tester.ensureVisible(find.text('Last month'));
    await tester.tap(find.text('Last month'));
    await tester.pumpAndSettle();
    expect(find.text('Last month'), findsOneWidget);
    expect(repo.lastFetchArgs!.first['from'], isNotNull);
    expect(repo.lastFetchArgs!.first['to'], isNotNull);
  });

  testWidgets(
    'includes same-day transactions in the This week filter preview',
    (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 'week-income',
          amount: Money.fromRupees(900),
          occurredAt: DateTime(today.year, today.month, today.day, 10),
          merchantName: 'Received today',
          entryKind: TxnEntryKind.income,
        ),
        _txn(
          id: 'previous-week',
          amount: Money.fromRupees(300),
          occurredAt: today.subtract(Duration(days: today.weekday)),
          merchantName: 'Previous week',
        ),
      ]);
      await _pump(tester, repo: repo, cards: const []);

      await tester.tap(find.byKey(const Key('activity-period-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This week'));
      await tester.pumpAndSettle();

      expect(find.text('Received today'), findsOneWidget);
      expect(find.text('Previous week'), findsNothing);
      expect(find.text('+₹900'), findsOneWidget);
    },
  );

  testWidgets('tapping a transaction navigates to its detail route', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 't1',
        amount: Money.fromRupees(500),
        occurredAt: DateTime.now(),
        merchantName: 'Tap Me',
      ),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    await tester.tap(find.text('Tap Me'));
    await tester.pumpAndSettle();

    expect(find.text('detail t1'), findsOneWidget);
  });

  testWidgets(
    'typing in the search box sends the query to the server, debounced',
    (tester) async {
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 't1',
          amount: Money.fromRupees(500),
          occurredAt: DateTime.now(),
          merchantName: 'Zepto',
        ),
      ]);
      await _pump(tester, repo: repo, cards: const []);

      repo.lastFetchArgs = null;
      await tester.enterText(find.byType(TextField).first, 'zep');

      // Nothing yet: the whole point of the debounce is that a burst of
      // keystrokes is not a burst of ILIKE scans.
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        repo.lastFetchArgs,
        isNull,
        reason: 'should not refetch mid-typing',
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repo.lastFetchArgs!.first['query'], 'zep');
    },
  );

  testWidgets(
    'a blank search is no filter at all, not a match-everything query',
    (tester) async {
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 't1',
          amount: Money.fromRupees(500),
          occurredAt: DateTime.now(),
          merchantName: 'Zepto',
        ),
      ]);
      await _pump(tester, repo: repo, cards: const []);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repo.lastFetchArgs!.first['query'], isNull);
    },
  );

  testWidgets(
    'displays investment contributions and returns with correct signs, labels and icons',
    (tester) async {
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 'inv-out',
          amount: Money.fromRupees(10000),
          occurredAt: DateTime.now(),
          merchantName: 'Zerodha',
          entryKind: TxnEntryKind.investment,
        ),
        _txn(
          id: 'inv-in',
          amount: Money.fromRupees(2500),
          occurredAt: DateTime.now(),
          merchantName: 'Groww Settlement',
          entryKind: TxnEntryKind.income,
          categoryId: 'investments',
          categoryName: 'Investments',
        ),
      ]);
      await _pump(tester, repo: repo, cards: const []);

      expect(find.text('−₹10,000'), findsOneWidget);
      expect(find.text('+₹2,500'), findsOneWidget);
      expect(find.textContaining('Investment'), findsNWidgets(2));
      expect(find.textContaining('Investment return'), findsOneWidget);
      expect(find.byIcon(Icons.trending_up_rounded), findsNWidgets(2));
    },
  );

  testWidgets(
    'filtering by Investments matches both contributions and investment returns',
    (tester) async {
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 'inv-out',
          amount: Money.fromRupees(10000),
          occurredAt: DateTime.now(),
          merchantName: 'Zerodha',
          entryKind: TxnEntryKind.investment,
        ),
        _txn(
          id: 'inv-in',
          amount: Money.fromRupees(2500),
          occurredAt: DateTime.now(),
          merchantName: 'Groww Settlement',
          entryKind: TxnEntryKind.income,
          categoryId: 'investments',
          categoryName: 'Investments',
        ),
        _txn(
          id: 'spend-1',
          amount: Money.fromRupees(500),
          occurredAt: DateTime.now(),
          merchantName: 'Grocery',
          entryKind: TxnEntryKind.spend,
        ),
      ]);
      await _pump(tester, repo: repo, cards: const []);

      expect(find.text('Zerodha'), findsOneWidget);
      expect(find.text('Groww Settlement'), findsOneWidget);
      expect(find.text('Grocery'), findsOneWidget);

      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Investments'));
      await tester.pumpAndSettle();

      // The button says how many transactions the choices will show.
      expect(find.text('Show 2 transactions'), findsOneWidget);
      await tester.tap(find.byKey(const Key('activity-filters-apply')));
      await tester.pumpAndSettle();

      expect(find.text('Zerodha'), findsOneWidget);
      expect(find.text('Groww Settlement'), findsOneWidget);
      expect(find.text('Grocery'), findsNothing);
    },
  );

  testWidgets(
    'setting filter, leaving page, navigating elsewhere, returning, and unsetting works reliably',
    (tester) async {
      final now = DateTime.now();
      final repo = _FakeUserCardsRepository([
        _txn(
          id: 't1',
          amount: Money.fromRupees(100),
          occurredAt: now,
          categoryId: 'dining',
          categoryName: 'Dining',
          merchantName: 'Restaurant',
        ),
        _txn(
          id: 't2',
          amount: Money.fromRupees(200),
          occurredAt: now,
          categoryId: 'groceries',
          categoryName: 'Groceries',
          merchantName: 'Supermarket',
        ),
      ]);

      const diningCat = SpendCategory(
        id: 'dining',
        name: 'Dining',
        slug: 'dining',
      );
      const grocCat = SpendCategory(
        id: 'groceries',
        name: 'Groceries',
        slug: 'groceries',
      );

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => Scaffold(
              body: ElevatedButton(
                onPressed: () => context.push('/activity'),
                child: const Text('Go Activity'),
              ),
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (context, state) => Scaffold(
              body: ElevatedButton(
                onPressed: () => context.push('/activity'),
                child: const Text('Go Activity from Other'),
              ),
            ),
          ),
          GoRoute(
            path: '/activity',
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: const Text('Activity')),
              body: const ActivityScreen(),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            foreignPaymentsProvider.overrideWith((ref) async => const []),
            accessTokenProvider.overrideWith((ref) => 'test-token'),
            sessionInitProvider.overrideWith((ref) async {}),
            userCardsRepositoryProvider.overrideWithValue(repo),
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith(
              (ref) async => [diningCat, grocCat],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Go to Activity
      await tester.tap(find.text('Go Activity'));
      await tester.pumpAndSettle();

      expect(find.text('Restaurant'), findsOneWidget);
      expect(find.text('Supermarket'), findsOneWidget);

      // 2. Set a filter: Category is a dropdown that opens a multi-select
      await tester.tap(find.byKey(const Key('activity-filters-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('activity-filter-categories')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('activity-pick-dining')));
      await tester.tap(find.byKey(const Key('activity-pick-done')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('activity-filters-apply')));
      await tester.pumpAndSettle();

      expect(find.text('Restaurant'), findsOneWidget);
      expect(find.text('Supermarket'), findsNothing);

      // One Clear all, and a chip for the category with its own x
      expect(find.text('Clear all'), findsOneWidget);
      expect(find.byKey(const Key('activity-filters-count')), findsOneWidget);

      // 3. Back go
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Go Activity'), findsOneWidget);

      // 4. Go to some other page and go back in
      router.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('Go Activity from Other'), findsOneWidget);

      await tester.tap(find.text('Go Activity from Other'));
      await tester.pumpAndSettle();

      // Coming back keeps the filter: it stays until Clear all.
      expect(find.text('Restaurant'), findsOneWidget);
      expect(find.text('Supermarket'), findsNothing);
      expect(find.text('Clear all'), findsOneWidget);

      // 5. Clear all puts everything back
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(find.text('Restaurant'), findsOneWidget);
      expect(find.text('Supermarket'), findsOneWidget);
      expect(find.text('Clear all'), findsNothing);
    },
  );

  group('redesigned header: search suggestions, merchants and filters', () {
    List<TransactionEntry> shops() {
      final now = DateTime.now();
      return [
        _txn(
          id: 'a1',
          amount: Money.fromRupees(100),
          occurredAt: now,
          merchantName: 'Swiggy',
        ),
        _txn(
          id: 'a2',
          amount: Money.fromRupees(300),
          occurredAt: now,
          merchantName: 'Swiggy',
        ),
        _txn(
          id: 'b1',
          amount: Money.fromRupees(250),
          occurredAt: now,
          merchantName: 'Zomato',
        ),
        _txn(
          id: 'c1',
          amount: Money.fromRupees(40),
          occurredAt: now,
          merchantName: 'Swish Mart',
        ),
        _txn(
          id: 'd1',
          amount: Money.fromRupees(900),
          occurredAt: now,
          merchantName: 'Blinkit',
        ),
      ];
    }

    testWidgets(
      'typing suggests merchants with counts, and several can be added',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(
          tester,
          repo: _FakeUserCardsRepository(shops()),
          cards: const [],
          overrides: [
            transactionsProvider.overrideWith((ref) async => shops()),
          ],
        );

        await tester.tap(find.byKey(const Key('activity-search-field')));
        await tester.pumpAndSettle();
        // Nothing typed yet: your merchants, most used first, with how many.
        expect(
          find.byKey(const Key('activity-search-suggestions')),
          findsOneWidget,
        );
        expect(find.text('2 transactions'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('activity-search-field')),
          'sw',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('activity-suggest-Swiggy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('activity-suggest-Swish Mart')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('activity-suggest-Zomato')), findsNothing);
        expect(find.byKey(const Key('activity-suggest-notes')), findsOneWidget);

        // Add two merchants, one after the other.
        await tester.tap(find.byKey(const Key('activity-suggest-Swiggy')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('activity-suggest-Zomato')));
        await tester.pumpAndSettle();
        expect(find.text('Done'), findsOneWidget);
        await tester.tap(find.byKey(const Key('activity-search-done')));
        await tester.pumpAndSettle();

        // The list shows only those two merchants, each with a chip to remove it.
        expect(
          find.byKey(const Key('activity-search-suggestions')),
          findsNothing,
        );
        expect(find.text('Blinkit'), findsNothing);
        expect(find.text('Swish Mart'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('Remove Swiggy')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Remove Zomato')), findsOneWidget);
        expect(find.byKey(const Key('activity-filters-count')), findsOneWidget);

        await tester.tap(find.bySemanticsLabel(RegExp('Remove Zomato')));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(RegExp('Remove Zomato')), findsNothing);
        expect(find.text('Zomato'), findsNothing);
        expect(find.text('Swiggy'), findsWidgets);

        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();
        expect(find.text('Blinkit'), findsOneWidget);
        expect(find.text('Clear all'), findsNothing);
        semantics.dispose();
      },
    );

    testWidgets(
      'the Filters sheet picks merchants from a dropdown and counts live',
      (tester) async {
        await _pump(
          tester,
          repo: _FakeUserCardsRepository(shops()),
          cards: const [],
        );

        await tester.tap(find.byKey(const Key('activity-filters-button')));
        await tester.pumpAndSettle();
        expect(find.text('Show 5 transactions'), findsOneWidget);

        await tester.tap(find.byKey(const Key('activity-filter-merchants')));
        await tester.pumpAndSettle();
        // Searchable, with a count beside each merchant.
        await tester.enterText(
          find.byKey(const Key('activity-pick-search')),
          'zom',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('activity-pick-Zomato')), findsOneWidget);
        expect(find.byKey(const Key('activity-pick-Swiggy')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('activity-pick-search')),
          '',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('activity-pick-Swiggy')));
        await tester.tap(find.byKey(const Key('activity-pick-Zomato')));
        await tester.pumpAndSettle();
        expect(find.text('Done, 2 selected'), findsOneWidget);
        await tester.tap(find.byKey(const Key('activity-pick-done')));
        await tester.pumpAndSettle();

        expect(find.text('Swiggy, Zomato'), findsOneWidget);
        expect(find.text('Show 3 transactions'), findsOneWidget);

        // An amount range narrows it further, and the button follows.
        await tester.enterText(
          find.byKey(const Key('activity-amount-min')),
          '150',
        );
        await tester.pumpAndSettle();
        expect(find.text('Show 2 transactions'), findsOneWidget);

        await tester.tap(find.byKey(const Key('activity-filters-apply')));
        await tester.pumpAndSettle();
        expect(find.text('Blinkit'), findsNothing);
        expect(find.text('Zomato'), findsWidgets);
        expect(find.text('From ₹150'), findsOneWidget);
        // Merchants and amount are two kinds of filter.
        expect(find.text('2'), findsOneWidget);
      },
    );

    testWidgets('Reset in the sheet clears every choice but not the period', (
      tester,
    ) async {
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(shops()),
        cards: const [],
      );
      await tester.tap(find.byKey(const Key('activity-filters-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('activity-amount-max')),
        '50',
      );
      await tester.pumpAndSettle();
      expect(find.text('Show 1 transaction'), findsOneWidget);
      await tester.tap(find.byKey(const Key('activity-filters-reset')));
      await tester.pumpAndSettle();
      expect(find.text('Show 5 transactions'), findsOneWidget);
    });

    testWidgets('a saved view comes back on a fresh start', (tester) async {
      SharedPreferences.setMockInitialValues({
        'activity_view_v1':
            '{"type":"all","datePreset":"allTime","merchants":["Zomato"],"sort":"highestAmount"}',
      });
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(shops()),
        cards: const [],
        overrides: [transactionsProvider.overrideWith((ref) async => shops())],
      );
      await tester.pumpAndSettle();

      expect(find.text('Highest'), findsOneWidget);
      expect(find.text('All time'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Remove Zomato')), findsOneWidget);
      expect(find.text('Blinkit'), findsNothing);
      expect(find.text('Zomato'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('a change is saved for next time, without the search text', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(shops()),
        cards: const [],
      );

      await tester.tap(find.byKey(const Key('activity-sort-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('activity-sort-merchantAz')),
      );
      await tester.tap(find.byKey(const Key('activity-sort-merchantAz')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('activity-search-field')),
        'zom',
      );
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      final saved = (await SharedPreferences.getInstance()).getString(
        'activity_view_v1',
      );
      expect(saved, isNotNull);
      expect(saved, contains('"sort":"merchantAz"'));
      expect(saved, isNot(contains('zom')));
    });
  });
}
