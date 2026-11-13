import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_routes.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_settle_sheet.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import '../storage/shared_store_test.dart' as fixtures;

class _VisibleRuntime extends SharedExpensesRuntime {
  final bool paging;
  Map<SharedHubTab, String> lastSearches = const {};
  _VisibleRuntime(SharedExpensesRuntime original, {this.paging = false})
    : super(
        store: original.store,
        remote: original.remote,
        cache: original.cache,
        isCurrent: original.isCurrent,
      );
  @override
  Future<SharedHubPresentation> loadHub({
    Map<SharedHubTab, String?> after = const {},
    Map<SharedHubTab, String> searches = const {},
  }) async {
    lastSearches = Map.of(searches);
    return SharedHubPresentation(
      friends: SharedPage(),
      activity: SharedPage(),
      groups: SharedPage(
        items: store.isContextRevoked(fixtures.contextId)
            ? []
            : [
                SharedContextRow(
                  id: fixtures.contextId,
                  title: after[SharedHubTab.groups] == null
                      ? 'Flatmates'
                      : 'Flatmates page 2',
                  balance: const SharedBalanceSummary(
                    owedToYou: Money.fromPaise(100),
                    youOwe: Money.zero(),
                    netBalance: Money.fromPaise(100),
                  ),
                ),
              ],
        hasMore: paging && after[SharedHubTab.groups] == null,
        hasPrevious: after[SharedHubTab.groups] != null,
        nextCursor: paging && after[SharedHubTab.groups] == null
            ? 'groups-page-2'
            : null,
        nextLabel: 'Next page',
      ),
    );
  }

  @override
  Future<SharedGroupPresentation> loadGroup(
    String id, {
    String? expenseAfter,
    String? balanceAfter,
  }) async => SharedGroupPresentation(
    id: id,
    title: id == fixtures.contextId ? 'Flatmates' : 'Trip',
    expenses: SharedPage(),
    balances: SharedPage(),
  );
}

/// Answers the roster only when the test lets it, like a slow network.
class _SlowRosterRuntime extends _VisibleRuntime {
  final answer = Completer<SharedRoster>();
  var rosterCalls = 0;
  _SlowRosterRuntime(super.original);
  @override
  Future<SharedRoster> contextRoster(String id) {
    rosterCalls++;
    return answer.future;
  }
}

class _PausingCache extends ResponseCache {
  final started = Completer<void>(), release = Completer<void>();
  _PausingCache(super.db);
  @override
  Future<void> put(String key, String rawJson) async {
    started.complete();
    await release.future;
    await super.put(key, rawJson);
  }
}

void main() {
  late AppDatabase db;
  late SharedExpensesRuntime runtime;
  late AuthenticatedHttpClient client;
  var current = true, offline = false, enabled = true;
  var serverDown = false, overviewDown = false, combined = false;
  var hubCalls = 0, legacyContextCalls = 0, requests = 0, changesCalls = 0;
  var revoked = false;
  Completer<void>? overviewStarted, releaseOverview;
  setUp(() {
    current = true;
    offline = false;
    serverDown = false;
    overviewDown = false;
    combined = false;
    hubCalls = 0;
    legacyContextCalls = 0;
    requests = 0;
    changesCalls = 0;
    enabled = true;
    revoked = false;
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
    overviewStarted = releaseOverview = null;
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    final token =
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': fixtures.accountA.substring(5)}))).replaceAll('=', '')}.signature';
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((request) async {
        requests++;
        if (offline) throw http.ClientException('offline');
        if (serverDown ||
            overviewDown && request.url.path.endsWith('/overview')) {
          return http.Response(
            jsonEncode({'error': 'internal_error'}),
            503,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/overview') && releaseOverview != null) {
          overviewStarted!.complete();
          await releaseOverview!.future;
        }
        Object bodyFor(String name, Map<String, String> query) =>
            switch (name) {
              'capabilities' => {
                'schemaVersion': 1,
                'available': true,
                'reads': enabled,
                'proposals': enabled,
                'acceptedWrites': enabled,
                'settlements': enabled,
                'sourceFunding': false,
              },
              'changes' => {
                'records': [],
                'nextCursor': null,
                'hasMore': false,
                'revokedContextIds': [],
                'grantedContextIds': [],
              },
              'overview' => {
                'currency': 'INR',
                'owedMinor': revoked ? '0' : '100',
                'owingMinor': revoked ? '0' : '100',
                'netMinor': '0',
                'contextCount': '1',
                'expenseCount': '2',
              },
              'contexts' => {
                'items': revoked || query['kind'] == 'direct'
                    ? []
                    : [
                        {
                          'contextId': fixtures.contextId,
                          'name': 'Flatmates',
                          'kind': 'group',
                          'membershipState': 'active',
                          'expenseCount': '2',
                          'owedMinor': '100',
                          'owingMinor': '100',
                          'memberId': fixtures.contextId,
                          'committedSequence': '3',
                        },
                      ],
                'nextCursor': null,
                'hasMore': false,
              },
              'activity' => {'items': [], 'nextCursor': null, 'hasMore': false},
              _ => {},
            };
        final last = request.url.path.split('/').last;
        final Object body;
        if (last == 'hub' || last == 'screen') {
          // An older server has no such route: an HTML 404, not JSON.
          if (last == 'screen' || !combined) {
            return http.Response(
              'Not found',
              404,
              headers: {'content-type': 'text/html'},
            );
          }
          hubCalls++;
          body = {
            'friends': bodyFor('contexts', {'kind': 'direct'}),
            'groups': bodyFor('contexts', {'kind': 'group'}),
            'overview': bodyFor('overview', {}),
            'activity': bodyFor('activity', {}),
          };
        } else {
          if (last == 'contexts') legacyContextCalls++;
          if (last == 'changes') changesCalls++;
          body = bodyFor(last, request.url.queryParameters);
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final store = SharedExpensesStore(
      db,
      namespace: fixtures.accountA,
      isCurrent: () => current,
    );
    final remote = SharedExpensesHttpTransport(
      apiBaseUrl: 'http://127.0.0.1:4001',
      namespace: fixtures.accountA,
      client: client,
      accessToken: () => token,
      isCurrent: () => current,
    );
    runtime = SharedExpensesRuntime(
      store: store,
      remote: remote,
      cache: ResponseCache(db),
      isCurrent: () => current,
    );
  });
  tearDown(() {
    BambooFonts.useSystemFontsForTests = false;
    runtime.dispose();
    client.close();
    db.close();
  });
  testWidgets('hub has no draft navigation and retains the add action', (
    tester,
  ) async {
    final old = runtime;
    runtime = _VisibleRuntime(runtime);
    old.dispose();
    var added = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          home: SharedExpensesRoute(
            onOpenContext: (_) {},
            onAddExpense: () {
              added = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Drafts & submissions'), findsNothing);
    await tester.tap(find.byTooltip('Add expense'));
    expect(added, isTrue);
    expect(runtime.store.pendingCount, 0);
  });
  testWidgets('repeated taps open one split and one editor, not a stack', (
    tester,
  ) async {
    final old = runtime;
    runtime = _VisibleRuntime(runtime);
    old.dispose();
    // Like go_router's push: the future ends only when the page is closed.
    final opened = <String>[];
    var pageOpen = Completer<void>();
    var adds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          home: SharedExpensesRoute(
            onOpenContext: (id) {
              opened.add(id);
              return pageOpen.future;
            },
            onAddExpense: () {
              adds++;
              return pageOpen.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Flatmates'));
      await tester.pump();
    }
    expect(opened, [fixtures.contextId], reason: 'second tap must be ignored');
    // While one page is open, the add button cannot open a second one either.
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pump();
    expect(adds, 0);
    // Coming back re-arms the buttons.
    pageOpen.complete();
    await tester.pumpAndSettle();
    pageOpen = Completer<void>();
    await tester.tap(find.byTooltip('Add expense'));
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pump();
    expect(adds, 1);
    pageOpen.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flatmates'));
    await tester.pump();
    expect(opened.length, 2);
  });
  testWidgets('Settle up opens one form however often it is tapped while slow', (
    tester,
  ) async {
    final old = runtime;
    final slow = _SlowRosterRuntime(old)
      ..capabilities = {
        'available': true,
        'reads': true,
        'proposals': true,
        'acceptedWrites': true,
        'settlements': true,
      };
    runtime = slow;
    old.dispose();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          home: SharedContextRoute(
            contextId: fixtures.contextId,
            onAddExpense: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Balances'));
    await tester.pumpAndSettle();
    final settle = find.text('Settle up');
    expect(settle, findsOneWidget);
    // The roster is slow: nothing opens yet, and the person keeps tapping.
    for (var i = 0; i < 5; i++) {
      await tester.tap(settle);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(slow.rosterCalls, 1, reason: 'taps while loading must be ignored');
    slow.answer.complete(
      SharedRoster(
        name: 'Flatmates',
        ownMemberId: 'me',
        direct: false,
        canInvite: false,
        members: const [
          SharedEditorMember('me', 'You', profileId: 'p1', role: 'owner'),
          SharedEditorMember('bob', 'Bob', profileId: 'p2'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SharedSettleSheet), findsOneWidget);
  });
  testWidgets('group screen add-expense button is single-flight too', (
    tester,
  ) async {
    final old = runtime;
    runtime = _VisibleRuntime(runtime);
    old.dispose();
    final page = Completer<void>();
    var adds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          home: SharedContextRoute(
            contextId: fixtures.contextId,
            onAddExpense: () {
              adds++;
              return page.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add expense'));
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pump();
    expect(adds, 1);
    page.complete();
    await tester.pumpAndSettle();
  });
  testWidgets(
    'hub pages preserve search and selected tab with independent previous cursors',
    (tester) async {
      final old = runtime, visible = _VisibleRuntime(runtime, paging: true);
      runtime = visible;
      old.dispose();
      var added = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          ],
          child: MaterialApp(
            home: SharedExpensesRoute(
              onOpenContext: (_) {},
              onAddExpense: () => added++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add expense'));
      await tester.pumpAndSettle();
      expect(added, 1);
      await tester.tap(find.byTooltip('Search splits'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'flat');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(visible.lastSearches[SharedHubTab.groups], 'flat');
      await tester.ensureVisible(find.text('Next page'));
      await tester.tap(find.text('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates page 2'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'flat',
      );
      await tester.ensureVisible(find.text('Previous page'));
      await tester.tap(find.text('Previous page'));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsOneWidget);
      expect(find.text('Previous page'), findsNothing);
      expect(visible.lastSearches[SharedHubTab.groups], 'flat');
    },
  );
  testWidgets(
    'reusing a context route changes the authorized view and resets old context state',
    (tester) async {
      final old = runtime;
      runtime = _VisibleRuntime(runtime);
      old.dispose();
      var added = 0;
      final override = sharedExpensesRuntimeProvider.overrideWith(
        (ref) async => runtime,
      );
      Widget subject(String id) => ProviderScope(
        overrides: [override],
        child: MaterialApp(
          home: SharedContextRoute(contextId: id, onAddExpense: () => added++),
        ),
      );
      await tester.pumpWidget(subject(fixtures.contextId));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsOneWidget);
      await tester.tap(find.byTooltip('Add expense'));
      await tester.pumpAndSettle();
      expect(added, 1);
      await tester.pumpWidget(subject(fixtures.op1));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsNothing);
      expect(find.text('Trip'), findsOneWidget);
    },
  );
  testWidgets(
    'visible hub refreshes after access loss without requiring navigation',
    (tester) async {
      final original = runtime;
      runtime = _VisibleRuntime(original);
      original.dispose();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          ],
          child: MaterialApp(
            home: SharedExpensesRoute(
              onOpenContext: (_) {},
              onAddExpense: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsOneWidget);
      revoked = true;
      await runtime.revokeContext(fixtures.contextId);
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsNothing);
    },
  );
  test(
    'account recovery drains a query through its cache publication',
    () async {
      await runtime.refresh();
      final old = runtime, paused = _PausingCache(db);
      runtime = SharedExpensesRuntime(
        store: old.store,
        remote: old.remote,
        cache: paused,
        isCurrent: () => current,
      )..capabilities = old.capabilities;
      old.dispose();
      final query = runtime.contexts();
      await paused.started.future;
      var entered = false;
      final recovery = runtime.store.recoveryGate.exclusive(() async {
        entered = true;
      });
      await Future<void>.delayed(Duration.zero);
      final enteredBeforeQueryFinished = entered;
      paused.release.complete();
      await query;
      await recovery;
      expect(enteredBeforeQueryFinished, isFalse);
      expect(entered, isTrue);
    },
  );
  test(
    'revocation fences an already in-flight aggregate before clearing private cache',
    () async {
      await runtime.refresh();
      overviewStarted = Completer<void>();
      releaseOverview = Completer<void>();
      final request = runtime.loadHub();
      final rejected = expectLater(
        request,
        throwsA(isA<SharedRuntimeUnavailable>()),
      );
      await overviewStarted!.future;
      await runtime.revokeContext(fixtures.contextId);
      releaseOverview!.complete();
      await rejected;
      expect(
        await runtime.cache.read('${fixtures.accountA}:shared:overview'),
        isNull,
      );
      expect(runtime.store.isContextRevoked(fixtures.contextId), isTrue);
    },
  );
  test(
    'runtime loads exact authorized overview without converting net zero to settled',
    () async {
      await runtime.refresh();
      final view = await runtime.loadHub();
      expect(view.summary!.owedToYou.paise, 100);
      expect(view.summary!.youOwe.paise, 100);
      expect(view.groups.items.single.canHideAsSettled, isFalse);
      expect(view.groups.items.single.title, 'Flatmates');
    },
  );
  test(
    'disabled server capability never becomes an empty settled dashboard',
    () async {
      enabled = false;
      await runtime.refresh();
      expect(runtime.readsEnabled, isFalse);
      await expectLater(
        runtime.loadHub(),
        throwsA(isA<SharedRuntimeUnavailable>()),
      );
    },
  );
  test(
    'offline display reuses only same-account authorized query cache',
    () async {
      await runtime.refresh();
      await runtime.loadHub();
      offline = true;
      final view = await runtime.loadHub();
      expect(view.offline, isTrue);
      expect(view.groups.items.single.title, 'Flatmates');
      expect(
        await runtime.cache.read('user:other:shared:contexts:first'),
        isNull,
      );
    },
  );
  test('the hub loads in one request when the server supports it', () async {
    combined = true;
    await runtime.refresh();
    final view = await runtime.loadHub();
    expect(hubCalls, 1);
    expect(legacyContextCalls, 0);
    expect(view.groups.items.single.title, 'Flatmates');
    // And it is saved, so the same screen shows offline.
    offline = true;
    final again = await runtime.loadHub();
    expect(again.offline, isTrue);
    expect(again.groups.items.single.title, 'Flatmates');
  });
  test('an older server without the one-request route still works', () async {
    combined = false;
    await runtime.refresh();
    final view = await runtime.loadHub();
    expect(hubCalls, 0);
    expect(legacyContextCalls, greaterThan(0));
    expect(view.groups.items.single.title, 'Flatmates');
    // The first answer is remembered: the next load does not probe again.
    legacyContextCalls = 0;
    await runtime.loadHub();
    expect(legacyContextCalls, greaterThan(0));
  });
  test('a failing server is not sent four more requests', () async {
    combined = true;
    await runtime.refresh();
    serverDown = true;
    requests = 0;
    await expectLater(runtime.loadHub(), throwsA(anything));
    expect(requests, 1);
  });
  test('reopening right after a live load asks the server nothing', () async {
    combined = true;
    await runtime.refresh();
    expect(runtime.hubFresh(), isFalse);
    await runtime.loadHub();
    expect(runtime.hubFresh(), isTrue);
    runtime.dataVersion++;
    expect(runtime.hubFresh(), isFalse);
  });
  test(
    'a failing refresh backs the background timer off, a good one clears it',
    () async {
      serverDown = true;
      await runtime.refresh();
      expect(runtime.backingOff, isTrue);
      serverDown = false;
      await runtime.refresh();
      expect(runtime.backingOff, isFalse);
    },
  );
  test(
    'a refresh asked for while one runs is followed by one more, not dropped',
    () async {
      final first = runtime.refresh();
      final second = runtime.refresh();
      await Future.wait([first, second]);
      expect(changesCalls, 2);
      expect(runtime.busy, isFalse);
    },
  );
  test('a 5xx from the server still shows the saved splits', () async {
    await runtime.refresh();
    await runtime.loadHub();
    serverDown = true;
    final view = await runtime.loadHub();
    expect(view.offline, isTrue);
    expect(view.groups.items.single.title, 'Flatmates');
  });
  test('a failed totals strip does not blank friends and groups', () async {
    await runtime.refresh();
    overviewDown = true;
    final view = await runtime.loadHub();
    expect(view.groups.items.single.title, 'Flatmates');
    expect(view.summary?.incomplete, isTrue);
  });
  test(
    'cold start offline reuses the saved flags and the saved screen',
    () async {
      await runtime.ensureCapabilities();
      await runtime.refresh();
      await runtime.loadHub();
      // A fresh runtime over the same database, with no network at all.
      offline = true;
      final cold = SharedExpensesRuntime(
        store: runtime.store,
        remote: runtime.remote,
        cache: runtime.cache,
        isCurrent: () => current,
      );
      addTearDown(cold.dispose);
      await cold.ensureCapabilities();
      expect(cold.readsEnabled, isTrue);
      final view = await cold.loadHub();
      expect(view.offline, isTrue);
      expect(view.groups.items.single.title, 'Flatmates');
    },
  );
  test('cache-only paints the saved screen without the network', () async {
    await runtime.refresh();
    await runtime.loadHub();
    var calls = 0;
    offline = true;
    final view = await runtime.runCacheOnly(() {
      calls++;
      return runtime.loadHub();
    });
    expect(calls, 1);
    expect(view.offline, isFalse);
    expect(view.groups.items.single.title, 'Flatmates');
  });
  test('refresh with nothing new does not bump the data version', () async {
    await runtime.refresh();
    final before = runtime.dataVersion;
    await runtime.refresh();
    expect(runtime.dataVersion, before);
  });
  test(
    'a switched-off feature is reported as off, not as a load failure',
    () async {
      enabled = false;
      await runtime.refresh();
      await expectLater(
        runtime.loadHub(),
        throwsA(
          isA<SharedRuntimeUnavailable>().having(
            (e) => e.reason,
            'reason',
            'reads_off',
          ),
        ),
      );
    },
  );
  test(
    'a stale account generation cannot enqueue or publish cached results',
    () async {
      await runtime.refresh();
      current = false;
      await expectLater(
        runtime.submit('context.create', {
          'contextId': fixtures.contextId,
          'contextKind': 'group',
          'name': 'New',
        }),
        throwsA(isA<SharedRuntimeUnavailable>()),
      );
      expect(runtime.store.pendingCount, 0);
    },
  );
  test('missing operation never claims the submission was saved', () {
    expect(
      runtime.operationStatus(fixtures.op1),
      'No saved submission · try again',
    );
    expect(runtime.store.pendingCount, 0);
  });
}
