// WP-Q1: shared harness for the app-level offline -> online scenario tests.
//
// One [OfflineApp] is "a phone": an in-memory AppDatabase that survives
// [OfflineApp.restart] (the app is killed and opened again over the SAME
// database), a controllable radio (the real seeded `isOnlineProvider` logic
// runs on top of a fake Connectivity), a [FakeServer] reached through the real
// repositories and the real AuthenticatedHttpClient, and a fake clock for the
// queues' backoff.
//
// Synthetic data only.
import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/app_status_repository.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/connectivity/connectivity_bootstrap.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/session_end_reason.dart';
import 'package:pandapay/data/connectivity/online_stream.dart';
import 'package:pandapay/data/connectivity/reachability.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/features/sync/sync_engine.dart';
import 'package:pandapay/features/sync_status/queue_totals.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';
import 'package:pandapay/features/sync_status/reachability_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

export 'fake_server.dart';

class FakeConnectivity implements Connectivity {
  FakeConnectivity(this.current);
  List<ConnectivityResult> current;
  final _controller = StreamController<List<ConnectivityResult>>.broadcast();

  void emit(List<ConnectivityResult> v) {
    current = v;
    _controller.add(v);
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;
}

/// A settable reachability monitor (the real one polls with timers).
class _FixedReachability extends ReachabilityMonitor {
  _FixedReachability(this._read);
  final bool? Function() _read;
  @override
  bool? build() => _read();
}

String jwtFor(String subject, {String salt = ''}) =>
    'e30.${base64Url.encode(utf8.encode('{"sub":"$subject"}')).replaceAll('=', '')}.sig$salt';

class OfflineApp {
  OfflineApp._(this.userId) : conn = FakeConnectivity([ConnectivityResult.wifi]);

  /// One phone with one signed-in account.
  static Future<OfflineApp> create({String userId = 'account-a'}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final app = OfflineApp._(userId);
    app.db = openInMemoryForTesting();
    return app;
  }

  final String userId;
  late final AppDatabase db;
  final FakeServer server = FakeServer();
  final FakeConnectivity conn;
  ProviderContainer? _container;

  /// The fake clock behind the queues' backoff.
  DateTime clock = DateTime(2026, 11, 14, 9);
  void advance(Duration d) => clock = clock.add(d);

  String token = '';
  int refreshCalls = 0;

  /// When true the refresh token is refused: the session is rejected (the
  /// access token is dropped, as SessionRefreshCoordinator does).
  bool refreshRejected = false;

  /// Harness view of "the server answers the probe".
  bool? reachableOverride;

  /// Per-request header/body timeouts of the HTTP client. Short so a captive
  /// scenario does not wait the real 15-30 s.
  AuthenticatedHttpTimeoutPolicy? captivePolicy;

  String get namespace => 'user:$userId';
  ProviderContainer get c => _container!;
  bool get running => _container != null;

  /// Opens the app (a fresh process) over the persistent database.
  Future<ProviderContainer> start({
    bool signedIn = true,
    bool online = true,
    List<Override> overrides = const [],
    bool listenConnectivity = true,
    bool backgroundFlush = true,
  }) async {
    assert(_container == null, 'stop() the previous process first');
    conn.current = [online ? ConnectivityResult.wifi : ConnectivityResult.none];
    if (!online) server.mode = NetMode.offline;
    if (token.isEmpty) token = jwtFor(userId);
    KnownConnectivity.online = online;
    late final ProviderContainer container;
    Future<String?> refresh() async {
      refreshCalls++;
      if (refreshRejected) {
        container.read(sessionEndReasonProvider).markSessionRejected();
        container.read(accessTokenProvider.notifier).state = null;
        return null;
      }
      final fresh = jwtFor(userId, salt: 'r$refreshCalls');
      token = fresh;
      container.read(accessTokenProvider.notifier).state = fresh;
      return fresh;
    }

    final client = AuthenticatedHttpClient(
      inner: server.client,
      timeoutFor: captivePolicy == null ? null : (_) => captivePolicy!,
      refreshAccessToken: refresh,
      // Like the app: a request rejected with an OLD token reuses the token a
      // refresh already produced instead of rotating the session again.
      refreshAccessTokenForToken: (rejected) async {
        final live = container.read(accessTokenProvider);
        if (live != null && live != rejected) return live;
        return refresh();
      },
      currentAccessToken: () => container.read(accessTokenProvider),
    );
    container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => signedIn ? token : null),
        appDatabaseProvider.overrideWith((ref) async => db),
        authenticatedHttpClientProvider.overrideWithValue(client),
        connectivityProvider.overrideWithValue(conn),
        serverReachabilityProvider.overrideWith((ref) {
          final r = ServerReachability(
            probe: () async => server.mode == NetMode.online,
          );
          ref.onDispose(r.dispose);
          return r;
        }),
        reachabilityMonitorProvider.overrideWith(
          () => _FixedReachability(
            () => reachableOverride ??
                (server.mode == NetMode.online ? null : false),
          ),
        ),
        catalogueRepositoryProvider.overrideWithValue(
          HttpCatalogueRepository(
            baseUrl: 'http://fake.test',
            client: server.client,
          ),
        ),
        categoryRepositoryProvider.overrideWithValue(
          HttpCategoryRepository(
            baseUrl: 'http://fake.test',
            client: server.client,
          ),
        ),
        appStatusRepositoryProvider.overrideWithValue(
          HttpAppStatusRepository(
            baseUrl: 'http://fake.test',
            client: server.client,
          ),
        ),
        outboxRepositoryProvider.overrideWith((ref) async {
          final ns = ref.watch(cacheNamespaceProvider);
          final cache = await ref.watch(responseCacheProvider.future);
          final repo = TransactionOutboxRepository(
            cache.financialStore.database,
            namespace: ns,
            financialStore: cache.financialStore,
            now: () => clock,
          );
          await repo.restoreLocalEntries();
          return repo;
        }),
        commandOutboxProvider.overrideWith((ref) async {
          final ns = ref.watch(cacheNamespaceProvider);
          final cache = await ref.watch(responseCacheProvider.future);
          return CommandOutbox(
            cache.financialStore.database,
            namespace: ns,
            now: () => clock,
          );
        }),
        ...overrides,
      ],
    );
    _container = container;
    if (listenConnectivity) {
      container.listen(isOnlineProvider, (_, _) {});
      // What the app root does at launch.
      container.read(connectivityBootstrapProvider);
    }
    // Let the seeded connectivity value land before anything reads it.
    await _until(() => container.read(isOnlineProvider).hasValue,
        what: 'connectivity seed');
    if (signedIn) {
      // The database is open before the shell starts its listeners (in the app
      // it is opened at splash); otherwise providers that watch it rebuild
      // under the first connectivity event.
      await container.read(appDatabaseProvider.future);
      await container.read(responseCacheProvider.future);
      // What _AppShell reads for the whole signed-in lifetime.
      container.listen(cacheLifecycleProvider, (_, _) {});
      if (backgroundFlush) {
        container.listen(outboxFlushProvider, (_, _) {});
        container.listen(syncLifecycleProvider, (_, _) {});
        container.listen(displayDataSyncLifecycleProvider, (_, _) {});
      }
      container.listen(syncQueueTotalsProvider, (_, _) {});
    }
    return container;
  }

  /// Kills the process: every provider, listener and timer is disposed; the
  /// database (the "disk") stays.
  Future<void> stop() async {
    final c = _container;
    _container = null;
    if (c != null) {
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// "Kill the app and open it again", over the same database.
  Future<ProviderContainer> restart({
    bool? online,
    bool signedIn = true,
    List<Override> overrides = const [],
  }) async {
    final wasOnline = server.mode != NetMode.offline;
    await stop();
    return start(
      online: online ?? wasOnline,
      signedIn: signedIn,
      overrides: overrides,
    );
  }

  Future<void> dispose() async {
    await stop();
    try {
      db.close();
    } catch (_) {}
  }

  // ---- network -----------------------------------------------------------
  /// Switches the network under the running app. The radio follows: only
  /// [NetMode.offline] takes it down.
  Future<void> setNet(NetMode mode) async {
    server.mode = mode;
    final radioUp = mode != NetMode.offline;
    conn.emit([radioUp ? ConnectivityResult.wifi : ConnectivityResult.none]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  Future<void> goOffline() => setNet(NetMode.offline);
  Future<void> goOnline() async {
    await setNet(NetMode.online);
    // A coming-back-online flush is started by the app's own listeners.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  // ---- queues ------------------------------------------------------------
  QueueRegistry get registry => QueueRegistry(db);

  SyncQueueTotals get totals => computeSyncQueueTotals(registry, namespace);

  /// Rows waiting in every account queue the sync strip counts.
  int get pending => totals.pending;
  int get attention => totals.attention;

  /// Per-queue counts, e.g. for a failure message.
  Map<String, String> get queueDump => {
    for (final s in registry.queues)
      if (!registry.countsFor(s.name, namespace).isEmpty)
        s.name: registry.countsFor(s.name, namespace).toString(),
  };

  /// The strip's state right now (the totals stream is recounted first).
  Future<SyncStatusSummary> summaryNow() async {
    c.read(syncStatusRefreshProvider.notifier).state++;
    final want = totals;
    await _until(
      () => c.read(syncQueueTotalsProvider).valueOrNull == want || (want.pending == 0 && want.attention == 0 && c.read(syncQueueTotalsProvider).valueOrNull == null),
      what: 'queue totals to settle',
      max: const Duration(seconds: 4),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return c.read(syncStatusSummaryProvider);
  }

  /// Runs every lifecycle flush the app has (outbox flush request, command
  /// outbox, SyncEngine) until the queues stop changing. [expectDrain] makes it
  /// fail loudly when work remains.
  Future<void> flushAll({bool expectDrain = true, int rounds = 12}) async {
    String snapshot() => queueDump.toString();
    var stable = 0;
    var last = '';
    for (var i = 0; i < rounds; i++) {
      c.read(outboxFlushRequestProvider.notifier).state++;
      await c.read(syncEngineProvider).sync();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final now = snapshot();
      if (now == last && pending == 0) {
        stable++;
        if (stable >= 2) break;
      } else {
        stable = 0;
      }
      last = now;
    }
    if (expectDrain) {
      expect(pending, 0, reason: 'queues should be empty: $queueDump ${commandRows()}');
    }
  }

  Future<void> idle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _until(
    bool Function() cond, {
    String what = 'condition',
    Duration max = const Duration(seconds: 5),
  }) async {
    final end = DateTime.now().add(max);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) {
        throw StateError('timed out waiting for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> until(bool Function() cond, {String what = 'condition'}) =>
      _until(cond, what: what);

  /// A normal online session start: the home refresh the signed-in shell does.
  Future<void> firstSyncOnline() async {
    c.read(homeDataRefreshProvider);
    await c.read(homeDataRefreshProvider.future);
    await c.read(budgetsProvider.future);
    await c.read(homeSummaryProvider.future);
    await c.read(categorySpendProvider.future);
    await c.read(syncEngineProvider).sync();
    // Let the refresh the sync triggered finish before a test cuts the net.
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

/// Re-export so the harness file does not need the long import in scenarios.


extension OfflineAppViews on OfflineApp {
  /// What a screen does after it saved something: re-read the lists.
  void refreshViews() {
    c.invalidate(transactionsProvider);
    c.invalidate(userCardsProvider);
    c.invalidate(budgetsProvider);
  }
}

/// The app's helpers take a `WidgetRef`; this one reads a [ProviderContainer].
/// (No `context`: the helpers under test must not need one.)
class ContainerRef implements WidgetRef {
  ContainerRef(this.container);
  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  T watch<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) =>
      container.invalidate(provider);

  @override
  R refresh<R>(Refreshable<R> provider) => container.refresh(provider);

  @override
  bool exists(ProviderBase<Object?> provider) => container.exists(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

extension OfflineAppRef on OfflineApp {
  WidgetRef get ref => ContainerRef(c);
}

extension OfflineAppDebug on OfflineApp {
  /// Every row left in the command outbox with its last error (for messages).
  List<String> commandRows() => [
    for (final r in db.db.select(
      'SELECT kind, target, attempts, parked, last_error FROM command_outbox',
    ))
      '${r['kind']} ${r['target']} attempts=${r['attempts']} parked=${r['parked']} err=${r['last_error']}',
  ];
}

extension OfflineAppSession on OfflineApp {
  /// The person signs in again (same account): a fresh token on the live app.
  void signInAgain() {
    refreshRejected = false;
    token = jwtFor(userId, salt: 'login${++refreshCalls}');
    c.read(accessTokenProvider.notifier).state = token;
  }
}
