import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_routes.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
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
  var revoked = false;
  Completer<void>? overviewStarted, releaseOverview;
  setUp(() {
    current = true;
    offline = false;
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
        if (offline) throw http.ClientException('offline');
        if (request.url.path.endsWith('/overview') && releaseOverview != null) {
          overviewStarted!.complete();
          await releaseOverview!.future;
        }
        final Object body = switch (request.url.path.split('/').last) {
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
            'items': revoked || request.url.queryParameters['kind'] == 'direct'
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
  testWidgets(
    'hub pages preserve search and selected tab with independent previous cursors',
    (tester) async {
      final old = runtime, visible = _VisibleRuntime(runtime, paging: true);
      runtime = visible;
      old.dispose();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          ],
          child: MaterialApp(home: SharedExpensesRoute(onOpenContext: (_) {})),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
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
      final override = sharedExpensesRuntimeProvider.overrideWith(
        (ref) async => runtime,
      );
      Widget subject(String id) => ProviderScope(
        overrides: [override],
        child: MaterialApp(home: SharedContextRoute(contextId: id)),
      );
      await tester.pumpWidget(subject(fixtures.contextId));
      await tester.pumpAndSettle();
      expect(find.text('Flatmates'), findsOneWidget);
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
          child: MaterialApp(home: SharedExpensesRoute(onOpenContext: (_) {})),
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
}
