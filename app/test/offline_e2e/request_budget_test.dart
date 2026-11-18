// Requests the app makes, measured on the real app stack against the fake
// server (so a regression in what the app asks for fails a test, not a bill).
//
// 18 Nov 2026 census, SMS-v2 account, before this change:
//   * every save read the 2-month transaction window (6.9 MB at 40,000 rows)
//     although no v2 screen shows it;
//   * every open and resume asked the server for an aggregate over the whole
//     history (`/home-summary`) that a v2 account never reads.
// Everything the person SEES and every queue must be unchanged by removing them.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/refresh_views.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

const _mutationId = '11111111-1111-4111-8111-111111111111';

void main() {
  late OfflineApp app;
  late String cardId;

  setUp(() async {
    app = await OfflineApp.create();
    final card = app.server.seedCard(nickname: 'Daily', last4: '1111');
    cardId = card['id'] as String;
    app.server.seedTransaction(
      amount: 120,
      cardId: cardId,
      merchant: 'Shop A',
      at: DateTime.now().subtract(const Duration(days: 1)),
    );
  });
  tearDown(() => app.dispose());

  Future<void> open({required bool v2}) => app.start(
    overrides: [if (v2) smsV2ReportingEnabledProvider.overrideWithValue(true)],
  );

  /// The two-month window the utilization provider reads (`?from=`), as opposed
  /// to the paged list Activity reads (`?pageSize=`).
  int windowReads() => app.server
      .requests('GET', '/transactions')
      .where((r) => r.query.containsKey('from'))
      .length;

  /// What the quick-add screen does on Save: queue it locally, ask for delivery,
  /// refresh every view that shows an edit.
  Future<void> saveQuickAdd() async {
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    await outbox.enqueue(
      userCardId: cardId,
      amount: Money.fromRupees(250),
      merchantName: 'Budget Cafe',
      occurredAt: DateTime.now(),
      clientMutationId: _mutationId,
    );
    app.c.read(outboxFlushRequestProvider.notifier).state++;
    await refreshViews(ContainerRef(app.c));
    await app.flushAll();
    await app.idle(300);
  }

  group('a save', () {
    test('on an SMS-v2 account does not read the utilization window', () async {
      await open(v2: true);
      await app.firstSyncOnline();
      app.server.clearLog();

      await saveQuickAdd();

      expect(windowReads(), 0);
      expect(app.server.count('POST', '/transactions'), 1);
    });

    test(
      'on a legacy account still does (its screens show that list)',
      () async {
        await open(v2: false);
        await app.firstSyncOnline();
        app.server.clearLog();

        await saveQuickAdd();

        expect(windowReads(), greaterThanOrEqualTo(1));
      },
    );

    test(
      'is delivered exactly once and every queue drains, v2 and legacy',
      () async {
        for (final v2 in [true, false]) {
          final phone = await OfflineApp.create();
          addTearDown(phone.dispose);
          final card = phone.server.seedCard(nickname: 'Daily', last4: '1111');
          await phone.start(
            overrides: [
              if (v2) smsV2ReportingEnabledProvider.overrideWithValue(true),
            ],
          );
          await phone.firstSyncOnline();
          final outbox = await phone.c.read(outboxRepositoryProvider.future);
          await outbox.enqueue(
            userCardId: card['id'] as String,
            amount: Money.fromRupees(250),
            merchantName: 'Budget Cafe',
            occurredAt: DateTime.now(),
            clientMutationId: _mutationId,
          );
          phone.c.read(outboxFlushRequestProvider.notifier).state++;
          await refreshViews(ContainerRef(phone.c));
          await phone.flushAll();

          expect(
            phone.server.count('POST', '/transactions'),
            1,
            reason: 'v2=$v2',
          );
          expect(
            phone.server.activeTransactions.map((t) => t['merchant_name']),
            contains('Budget Cafe'),
            reason: 'v2=$v2',
          );
          expect(phone.pending, 0, reason: 'v2=$v2: ${phone.queueDump}');
          final shown = (await phone.c.read(
            transactionsProvider.future,
          )).where((t) => t.merchantName == 'Budget Cafe');
          expect(shown, hasLength(1), reason: 'exactly one row, v2=$v2');
        }
      },
    );

    test(
      'v2: the utilization list is still available, saved rows first',
      () async {
        await open(v2: true);
        await app.firstSyncOnline();
        await saveQuickAdd();
        app.server.clearLog();

        // What the split planner does when it opens.
        final rows = await app.c.read(utilizationTransactionsProvider.future);

        expect(rows.map((r) => r.merchantName), contains('Budget Cafe'));
        await app.idle(300);
        expect(
          windowReads(),
          1,
          reason: 'read on demand, once, instead of on every save',
        );
      },
    );
  });

  group('opening the app', () {
    test(
      'an SMS-v2 account does not ask for the server home summary',
      () async {
        await open(v2: true);
        app.server.clearLog();

        app.c.read(homeDataRefreshProvider);
        await app.c.read(homeDataRefreshProvider.future);
        await app.idle(300);

        expect(app.server.count('GET', '/home-summary'), 0);
        // the rest of the refresh is untouched
        expect(app.server.count('GET', '/user-cards'), greaterThanOrEqualTo(1));
        expect(app.server.count('GET', '/card-overrides'), 1);
      },
    );

    test('a legacy account still does, once', () async {
      await open(v2: false);
      app.server.clearLog();

      app.c.read(homeDataRefreshProvider);
      await app.c.read(homeDataRefreshProvider.future);
      await app.idle(300);

      expect(app.server.count('GET', '/home-summary'), 1);
    });
  });
}
