import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/split_repository.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_attention.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_attention_sheet.dart';
import 'package:pandapay/features/sync/split_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

// WP-C8: capability flags while offline, reconnect, handled refusals and the
// needs-attention list. Synthetic ids only.
const _json = {'content-type': 'application/json'};

void main() {
  late AppDatabase db;
  late SharedExpensesRuntime runtime;
  late AuthenticatedHttpClient client;

  // What the fake server does.
  var offline = false, commandStatus = 200, nameClash = false;
  String? clashKind;
  var capabilitiesOn = true, capabilityCalls = 0;
  final posted = <String>[];

  http.Response ok(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _json);

  setUp(() {
    offline = false;
    commandStatus = 200;
    nameClash = false;
    clashKind = null;
    capabilitiesOn = true;
    capabilityCalls = 0;
    posted.clear();
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    final token =
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': fixtures.accountA.substring(5)}))).replaceAll('=', '')}.signature';
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        final last = request.url.path.split('/').last;
        if (request.method == 'POST' && last == 'commands') {
          final command = SharedCommand.fromJson(jsonDecode(request.body));
          posted.add(command.operationId);
          if (nameClash || command.kind == clashKind) {
            return ok({'error': 'friend_name_taken'}, 409);
          }
          if (commandStatus != 200) {
            return ok({'error': 'internal_error'}, commandStatus);
          }
          return ok({
            'receipt': {
              'operationId': command.operationId,
              'kind': command.kind,
              'requestHash': command.requestHash,
              'contextId': command.contextId,
              'result': {'status': 'created'},
              'state': 'committed',
            },
            'records': [],
          });
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/operations/')) {
          return ok({'error': 'operation_not_found'}, 404);
        }
        return ok(switch (last) {
          'capabilities' => () {
            capabilityCalls++;
            return {
              'schemaVersion': 1,
              'available': true,
              'reads': capabilitiesOn,
              'proposals': capabilitiesOn,
              'acceptedWrites': capabilitiesOn,
              'settlements': capabilitiesOn,
              'sourceFunding': false,
            };
          }(),
          'changes' => {
            'records': [],
            'nextCursor': null,
            'hasMore': false,
            'revokedContextIds': [],
            'grantedContextIds': [],
          },
          _ => {},
        });
      }),
    );
    runtime = SharedExpensesRuntime(
      store: SharedExpensesStore(db, namespace: fixtures.accountA),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: fixtures.accountA,
        client: client,
        accessToken: () => token,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
      isCurrent: () => true,
    );
  });
  tearDown(() {
    BambooFonts.useSystemFontsForTests = false;
    try {
      runtime.dispose();
    } catch (_) {} // a test may already have disposed it
    client.close();
    db.close();
  });

  group('capability flags unknown (never loaded)', () {
    test('creating a group is queued instead of throwing', () async {
      offline = true;
      expect(runtime.capabilities, isNull);
      expect(runtime.canQueueProposals, isTrue);
      final id = await runtime.submit('context.create', {
        'contextId': fixtures.contextId,
        'contextKind': 'group',
        'name': 'Trip',
      });
      await runtime.settled(); // the send is background work
      expect(
        runtime.store.operation(id)!.state,
        isNot(SharedCommandState.rejected),
      );
      expect(runtime.store.pendingCount, 1);
      expect(runtime.offline, isTrue);
    });

    test('adding a friend is queued with its invite after it', () async {
      offline = true;
      final added = await runtime.addFriend(name: 'Sam');
      expect(added.contextId, isNotEmpty);
      expect(runtime.store.pendingCount, 2);
    });

    test('approving an expense and reporting a payment are queued', () async {
      offline = true;
      await runtime.respondToExpense(
        fixtures.contextId,
        fixtures.op1,
        fixtures.op2,
        'approve',
      );
      await runtime.reportSettlement(
        contextId: fixtures.contextId,
        settlementId: fixtures.op2,
        payerMemberId: fixtures.op1,
        receiverMemberId: fixtures.op2,
        amountMinor: '100',
        method: 'upi',
        paidOn: '2026-11-04',
      );
      expect(runtime.store.pendingCount, 2);
    });

    test('a known-off flag still refuses to queue', () async {
      capabilitiesOn = false;
      await runtime.refresh();
      expect(runtime.capabilities!['proposals'], isFalse);
      expect(runtime.canQueueProposals, isFalse);
      await expectLater(
        runtime.submit('context.create', {
          'contextId': fixtures.contextId,
          'contextKind': 'group',
          'name': 'Trip',
        }),
        throwsA(isA<SharedRuntimeUnavailable>()),
      );
      expect(runtime.store.pendingCount, 0);
    });

    test('the saved flags survive revoking a split', () async {
      await runtime.refresh();
      expect(capabilityCalls, 1);
      await Future<void>.delayed(Duration.zero);
      final key = '${fixtures.accountA}:shared:capabilities';
      expect(await runtime.cache.get(key), isNotNull);
      await runtime.revokeContext(fixtures.contextId);
      expect(await runtime.cache.get(key), isNotNull);
    });
  });

  group('reconnect (X-02)', () {
    test('reconnect sends a command that is waiting out a backoff', () async {
      await runtime.refresh();
      commandStatus = 503;
      final id = await runtime.submit('member.rename', {
        'contextId': fixtures.contextId,
        'memberId': fixtures.op2,
        'displayName': 'Sam',
      });
      await runtime.settled();
      expect(runtime.store.operation(id)!.state, SharedCommandState.retry);
      commandStatus = 200;
      // An ordinary refresh respects the backoff earned a moment ago...
      await runtime.refresh();
      expect(posted, [id]);
      // ...a reconnect does not.
      await runtime.reconnect();
      expect(posted, [id, id]);
      expect(runtime.store.operation(id)!.state, SharedCommandState.committed);
    });

    test('reconnect never throws, even when the runtime is gone', () async {
      runtime.dispose();
      await runtime.reconnect();
      // (tear-down disposes again; that is tolerated above)
    });
  });

  group('refusals the screen already explained', () {
    test(
      'a taken friend name is thrown to the screen and left no row',
      () async {
        await runtime.refresh();
        nameClash = true;
        await expectLater(
          runtime.addFriend(name: 'Sam'),
          throwsA(isA<SharedNameException>()),
        );
        expect(runtime.store.attentionCount, 0);
        expect(runtime.store.pendingCount, 0);
      },
    );
  });

  group('refusal on the member step (WP-H2)', () {
    test('a name refused on the member op is acknowledged: no leftover "not synced"', () async {
      await runtime.refresh();
      clashKind = 'member.invite';
      await expectLater(
        runtime.addFriend(name: 'Sam'),
        throwsA(isA<SharedNameException>()),
      );
      expect(runtime.store.attentionCount, 0);
    });
  });

  group('needs attention (X-01)', () {
    Future<String> refusedBackground() async {
      await runtime.refresh();
      nameClash = true;
      // Saved while offline, so no screen was waiting to explain the refusal.
      final id = await runtime.submit('member.rename', {
        'contextId': fixtures.contextId,
        'memberId': fixtures.op2,
        'displayName': 'Sam',
      });
      await runtime.settled();
      nameClash = false;
      return id;
    }

    test('a refused command is counted and listed in plain words', () async {
      final id = await refusedBackground();
      // 409 without `retryable` is a conflict: shown, never auto-retried.
      expect(runtime.store.operation(id)!.state, SharedCommandState.conflict);
      expect(runtime.attentionCount, 1);
      final item = runtime.store.readAttention().single;
      expect(sharedAttentionTitle(item), contains('Rename someone'));
      expect(sharedAttentionReason(item), isNot(contains('http')));
      expect(sharedAttentionCanRetry(item), isFalse); // a name needs a new name
    });

    test('Retry re-queues and sends; Discard forgets', () async {
      final id = await runtime.submit('member.rename', {
        'contextId': fixtures.contextId,
        'memberId': fixtures.op2,
        'displayName': 'Sam',
      });
      db.db.execute(
        "UPDATE shared_commands SET state='rejected',error_code='http_422' WHERE operation_id=?",
        [id],
      );
      expect(runtime.attentionCount, 1);
      await runtime.retryRefused(id);
      expect(runtime.store.operation(id)!.state, SharedCommandState.committed);
      expect(runtime.attentionCount, 0);

      final other = await runtime.submit('member.rename', {
        'contextId': fixtures.contextId,
        'memberId': fixtures.op1,
        'displayName': 'Ann',
      });
      db.db.execute(
        "UPDATE shared_commands SET state='rejected',error_code='http_403' WHERE operation_id=?",
        [other],
      );
      await runtime.discardRefused(other);
      expect(runtime.store.operation(other), isNull);
      expect(runtime.attentionCount, 0);
    });

    testWidgets('the Split hub row opens the list; Discard empties it', (
      tester,
    ) async {
      // Store only: no HTTP, which cannot run under the widget test's clock.
      final command = SharedCommand(
        operationId: fixtures.op1,
        kind: 'member.rename',
        payload: {
          'contextId': fixtures.contextId,
          'memberId': fixtures.op2,
          'displayName': 'Sam',
        },
      );
      await runtime.store.enqueue(command);
      final id = command.operationId;
      db.db.execute(
        "UPDATE shared_commands SET state='rejected',error_code='http_403' WHERE operation_id=?",
        [id],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: SharedNeedsAttentionRow(runtime: runtime)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 needs attention'), findsOneWidget);
      await tester.tap(find.byKey(const Key('needs-attention-row')));
      await tester.pumpAndSettle();
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.textContaining('Rename someone'), findsOneWidget);
      expect(
        find.text('You no longer have permission to do this.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Everything is up to date.'), findsOneWidget);
      expect(runtime.store.operation(id), isNull);
    });

    testWidgets('the row takes no space when nothing needs attention', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SharedNeedsAttentionRow(runtime: runtime)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('needs-attention-row')), findsNothing);
    });

    test('the combined count adds blocked private splits', () async {
      final id = await runtime.submit('member.rename', {
        'contextId': fixtures.contextId,
        'memberId': fixtures.op2,
        'displayName': 'Sam',
      });
      db.db.execute(
        "UPDATE shared_commands SET state='rejected',error_code='http_403' WHERE operation_id=?",
        [id],
      );
      final repo = SplitRepository(
        db,
        namespace: fixtures.accountA,
        remote: () => null,
        canSync: () => false,
        now: DateTime.now,
        autoSync: false,
      );
      db.db.execute(
        "INSERT INTO split_documents(namespace,transaction_id,document_json,pending,blocked,fetched_at) VALUES(?,?,?,?,?,?)",
        [fixtures.accountA, 'tx-1', '{"splits":[]}', 1, 1, 0],
      );
      final container = ProviderContainer(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          splitRepositoryProvider.overrideWith((ref) async => repo),
        ],
      );
      addTearDown(container.dispose);
      container.listen(needsAttentionCountProvider, (_, _) {});
      await container.read(sharedExpensesRuntimeProvider.future);
      await container.read(splitRepositoryProvider.future);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(needsAttentionCountProvider), 2);
      repo.dispose();
    });
  });
}
