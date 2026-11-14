// WP-Q1 scenarios l, m, n: notifications, a statement import saved offline,
// and Split (group + dependent commands) queued offline.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/statement_import_continuation.dart';
import 'package:pandapay/features/import/statement_import_continuation_provider.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_attention.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';

import '../support/memory_import_continuation.dart';
import 'harness.dart';

class _FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final shown = <String>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #show) {
      shown.add(invocation.positionalArguments[1] as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #initialize) {
      return Future<bool?>.value(true);
    }
    return super.noSuchMethod(invocation);
  }
}

const _uuidUser = '11111111-1111-4111-8111-111111111111';

void main() {
  late OfflineApp app;
  tearDown(() => app.dispose());

  test('l. notification: local alert offline with default prefs, inbox row '
      'queued and delivered once', () async {
    app = await OfflineApp.create();
    final plugin = _FakePlugin();
    app.server.seedCard(last4: '1111');
    await app.start(overrides: [
      localNotificationsPluginProvider.overrideWithValue(plugin),
    ]);
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final gate = app.c.read(notificationGateProvider);
    final fired = await gate.fire(
      category: 'caps',
      title: 'Cap nearly reached',
      body: 'Synthetic body',
      dedupeKey: 'cap-1',
    );
    expect(fired, isTrue);
    expect(plugin.shown, ['Cap nearly reached'],
        reason: 'the alert fires on the phone with no network');
    // The same alert again (a second sweep) is deduped.
    expect(
        await gate.fire(
          category: 'caps',
          title: 'Cap nearly reached',
          body: 'Synthetic body',
          dedupeKey: 'cap-1',
        ),
        isFalse);
    expect(plugin.shown, hasLength(1));
    expect(app.pending, 1, reason: 'the inbox row waits in the queue');
    expect((await app.summaryNow()).pendingCount, 1);

    await app.restart(online: false, overrides: [
      localNotificationsPluginProvider.overrideWithValue(plugin),
    ]);
    expect(app.pending, 1);

    app.server.loseNext(1, ['/notifications']);
    await app.goOnline();
    await app.flushAll();
    expect(app.server.notifications, hasLength(1),
        reason: 'delivered once even though the first answer was lost');
    expect(app.server.count('POST', '/notifications'), 2);
    expect(plugin.shown, hasLength(1), reason: 'no second banner on replay');
    expect(app.pending, 0);
  });

  test('m. statement import offline is saved, resumes after a kill, uploads once',
      () async {
    app = await OfflineApp.create(userId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
    List<Override> overrides() => [
      statementImportContinuationProvider.overrideWith((ref) async {
        final repo = ImportRepository(
          apiBaseUrl: 'http://fake.test',
          accessToken: app.token,
          client: ref.read(authenticatedHttpClientProvider),
        );
        return StatementImportContinuation(
          outbox: StatementImportOutbox(
            app.db.db,
            namespace: app.namespace.toLowerCase(),
            cipher: PassthroughImportCipher(),
          ),
          checkAccountUnchanged: () {},
          sendPrepared: repo.confirmPreparedStatementImport,
        );
      }),
    ];
    Map<String, dynamic> payload(String key, String merchant) => {
      'userCardId': null,
      'instrument': 'other',
      'statementFrom': '2026-10-01',
      'statementTo': '2026-10-31',
      'txnCount': 1,
      'reconciledCount': 0,
      'importSource': 'statement',
      'importKey': key * 64,
      'transactions': [
        {
          'occurredAt': '2026-10-05T12:00:00.000Z',
          'amountInr': 12.5,
          'merchantName': merchant,
        },
      ],
    };
    const s1 = 'a1000000-0000-4000-8000-000000000001';

    await app.start(overrides: overrides());
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final continuation = await app.c.read(
      statementImportContinuationProvider.future,
    );
    await expectLater(
      continuation!.prepareAndRun(
        sessionId: s1,
        payloads: [payload('a', 'Stmt A'), payload('b', 'Stmt B')],
      ),
      throwsA(anything),
    );
    expect(app.pending, 2, reason: 'both batches are saved on the phone');
    expect((await app.summaryNow()).mode, SyncStatusMode.offline);
    expect(app.server.log, isEmpty);

    // Kill the app, open it again, still offline.
    await app.restart(online: false, overrides: overrides());
    expect(app.pending, 2);

    // Online again, but the second batch's request keeps failing (503): the
    // first one is delivered and must not be sent again afterwards.
    app.server.failWhen = (m, p, b) =>
        p == '/statement-imports' && '${b?['importKey']}'.startsWith('b') ? 503 : null;
    await app.goOnline();
    await app.until(() => app.pending == 1, what: 'first batch to upload');
    expect(app.server.importsByKey.keys, ['a' * 64]);

    // Kill mid-way, heal the server, reopen: the second goes, the first never again.
    await app.restart(online: true, overrides: overrides());
    app.server.failWhen = null;
    // The 503 paused every queue; a long wait ends that pause.
    app.advance(const Duration(minutes: 1));
    app.server.loseNext(1, ['/statement-imports']);
    // A lost answer leaves the batch saved until the next trigger (resume,
    // reconnect or a flush request); no timer retries imports by design.
    await app.idle(300);
    await app.flushAll();
    expect(app.server.importsByKey.keys.toSet(), {'a' * 64, 'b' * 64});
    final postsPerKey = <String, int>{};
    for (final r in app.server.log) {
      if (r.method == 'POST' && r.path == '/statement-imports') {
        final k = '${r.body!['importKey']}'[0];
        postsPerKey[k] = (postsPerKey[k] ?? 0) + 1;
      }
    }
    expect(postsPerKey['a'], 1, reason: 'a delivered batch is never re-sent');
    expect(app.server.activeTransactions.where((t) =>
        (t['merchant_name'] as String).startsWith('Stmt')), hasLength(2),
        reason: 'one server row per statement line');
  });

  test('n. Split: group and dependent commands offline, committed in order',
      () async {
    app = await OfflineApp.create(userId: _uuidUser);
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    // Keep the Split runtime and its lifecycle alive like the shell does.
    app.c.listen(sharedExpensesRuntimeProvider, (_, _) {});
    final runtime = await app.c.read(sharedExpensesRuntimeProvider.future);
    app.c.listen(sharedExpensesLifecycleProvider, (_, _) {});

    const ctx = '33333333-3333-4333-8333-333333333333';
    const member = '77777777-7777-4777-8777-777777777777';
    final createOp = await runtime.submit('context.create', {
      'contextId': ctx,
      'contextKind': 'group',
      'name': 'Trip',
    });
    await runtime.submit(
      'member.invite',
      {'contextId': ctx, 'memberId': member, 'displayName': 'Sam'},
      dependsOn: [createOp],
    );
    await runtime.submit(
      'member.rename',
      {'contextId': ctx, 'memberId': member, 'displayName': 'Samuel'},
      dependsOn: [createOp],
    );
    final friend = await runtime.addFriend(name: 'Pat');
    expect(friend.contextId, isNotEmpty);
    expect(runtime.store.pendingCount, 5);
    expect(app.pending, 5);
    expect(app.server.log, isEmpty);

    await app.restart(online: false);
    app.c.listen(sharedExpensesRuntimeProvider, (_, _) {});
    final again = await app.c.read(sharedExpensesRuntimeProvider.future);
    app.c.listen(sharedExpensesLifecycleProvider, (_, _) {});
    expect(again.store.pendingCount, 5, reason: 'queued commands survive');

    await app.goOnline();
    await app.until(() => app.pending == 0, what: 'Split commands to commit');
    final kinds = [for (final c in app.server.splitCommands) c.kind];
    expect(kinds, hasLength(5));
    // Every dependent command arrives after its own context was created.
    final created = <String>{};
    for (final c in app.server.splitCommands) {
      if (c.kind == 'context.create') {
        created.add(c.contextId!);
      } else {
        expect(created, contains(c.contextId),
            reason: '${c.kind} arrived before its context.create');
      }
    }
    expect(app.c.read(needsAttentionCountProvider), 0,
        reason: 'nothing was rejected');
    expect(app.attention, 0);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
