import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/notification_preferences_repository.dart';
import 'package:pandapay/data/notification_devices_api.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/notifications/notification_commands.dart';
import 'package:pandapay/features/notifications/notification_gate.dart';
import 'package:pandapay/features/notifications/push_notification_service.dart';

// WP-C4: notifications must work with no network. Synthetic data only.

const _ns = 'user:test-account';

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

/// Inbox repository whose POST can be switched off, and which remembers what
/// the server would hold (one row per dedupe key, like the real upsert).
class _InboxRepo extends UserCardsRepository {
  _InboxRepo() : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  bool reachable = true;
  int postAttempts = 0;
  final rows = <String, Map<String, Object?>>{};

  @override
  Future<void> recordNotification({
    required String category,
    required String title,
    String? body,
    String severity = 'info',
    String? deepLink,
    String? dedupeKey,
  }) async {
    postAttempts++;
    if (!reachable) throw const SocketException('offline');
    rows[dedupeKey ?? 'none-${rows.length}'] = {
      'category': category,
      'title': title,
    };
  }

  @override
  Future<void> replayQueuedNotification({
    required String category,
    required String title,
    String? body,
    String severity = 'info',
    String? deepLink,
    required String dedupeKey,
    String? clientMutationId,
    DateTime? createdAt,
  }) async {
    if (!reachable) throw const SocketException('offline');
    rows[dedupeKey] = {'category': category, 'title': title};
  }
}

class _PrefsRepo extends NotificationPreferencesRepository {
  _PrefsRepo() : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  bool reachable = true;
  int fetches = 0;
  Completer<void>? gate;
  NotificationPreferences server = NotificationPreferences.defaults;
  List<MutedMerchant> serverMuted = const [];
  final updates = <Map<String, dynamic>>[];
  final muteCalls = <String>[];
  final unmuteCalls = <String>[];

  @override
  Future<NotificationPreferences> fetch() async {
    fetches++;
    await gate?.future;
    if (!reachable) throw const SocketException('offline');
    return server;
  }

  @override
  Future<NotificationPreferences> update(Map<String, dynamic> changes) async {
    if (!reachable) throw const SocketException('offline');
    updates.add(changes);
    server = NotificationPreferences.fromJson({
      ...server.toJson(),
      ...changes,
    });
    return server;
  }

  @override
  Future<List<MutedMerchant>> fetchMutedMerchants() async {
    if (!reachable) throw const SocketException('offline');
    return serverMuted;
  }

  @override
  Future<void> muteMerchant(String merchantId) async {
    if (!reachable) throw const SocketException('offline');
    muteCalls.add(merchantId);
  }

  @override
  Future<void> unmuteMerchant(String merchantId) async {
    if (!reachable) throw const SocketException('offline');
    unmuteCalls.add(merchantId);
  }
}

NotificationPreferences _prefs({
  bool caps = true,
  String? quietStart,
  String? quietEnd,
  int dailyCap = 3,
}) => NotificationPreferences.fromJson({
  ...NotificationPreferences.defaults.toJson(),
  'category_caps': caps,
  'quiet_hours_start': quietStart,
  'quiet_hours_end': quietEnd,
  'daily_cap': dailyCap,
});

void main() {
  late ProviderContainer container;
  late Ref ref;
  late _FakePlugin plugin;
  late _InboxRepo inbox;
  late _PrefsRepo prefsRepo;
  late StreamController<bool> online;

  Future<void> seedCache(String key, Object json) async {
    final cache = await container.read(responseCacheProvider.future);
    await cache.put('$_ns:$key', jsonEncode(json));
  }

  /// Makes a cached copy look old enough to be refreshed in the background.
  Future<void> backdate(String key) async {
    final cache = await container.read(responseCacheProvider.future);
    cache.financialStore.database.db.execute(
      'UPDATE cached_responses SET fetched_at=? WHERE key=?',
      [DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch, '$_ns:$key'],
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    plugin = _FakePlugin();
    inbox = _InboxRepo();
    prefsRepo = _PrefsRepo();
    online = StreamController<bool>.broadcast();
    final capture = Provider<void>((r) => ref = r);
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        userCardsRepositoryProvider.overrideWithValue(inbox),
        notificationPreferencesRepositoryProvider.overrideWithValue(prefsRepo),
        isOnlineProvider.overrideWith((_) => online.stream),
      ],
    );
    container.read(capture);
  });

  tearDown(() async {
    container.dispose();
    await online.close();
  });

  NotificationGate gate() => NotificationGate(ref: ref, notifications: plugin);

  Future<int> pending() async =>
      (await container.read(commandOutboxProvider.future)).pendingCount;

  Future<int> replay() async {
    final commands = await container.read(commandOutboxProvider.future);
    return commands.flush(
      commandHandlersFor(inbox, notificationPrefs: prefsRepo),
    );
  }

  group('NotificationPreferences defaults', () {
    test('defaults match what a brand-new account gets from the server', () {
      const d = NotificationPreferences.defaults;
      expect(d.categoryLocation, isFalse);
      expect(d.categoryMonthlyReport, isFalse);
      expect(d.categoryCaps, isTrue);
      expect(d.categoryBills, isTrue);
      expect(d.categoryBudgetExceeded, isTrue);
      expect(d.dailyCap, 3);
      expect(d.quietHoursStart, isNull);
    });

    test('toJson round-trips through fromJson', () {
      final p = _prefs(caps: false, quietStart: '22:00', quietEnd: '07:00', dailyCap: 5);
      final again = NotificationPreferences.fromJson(p.toJson());
      expect(again.categoryCaps, isFalse);
      expect(again.quietHoursStart, '22:00');
      expect(again.quietHoursEnd, '07:00');
      expect(again.dailyCap, 5);
    });

    test('a row without daily_cap falls back to the default instead of throwing', () {
      final p = NotificationPreferences.fromJson({'category_caps': false});
      expect(p.dailyCap, 3);
      expect(p.categoryCaps, isFalse);
    });
  });

  group('gate with no network', () {
    test('preferences repo throws and the cache is empty: fires with defaults and shows the banner', () async {
      prefsRepo.reachable = false;
      inbox.reachable = false;
      final fired = await gate().fire(category: 'caps', title: 'Cap near', body: 'b', dedupeKey: 'k1');
      expect(fired, isTrue);
      expect(plugin.shown, ['Cap near']);
      expect(await pending(), 1, reason: 'the inbox row is queued, not lost');
    });

    test('defaults still keep location opt-in off', () async {
      prefsRepo.reachable = false;
      final fired = await gate().fire(category: 'location', title: 't', body: 'b', dedupeKey: 'loc');
      expect(fired, isFalse);
      expect(plugin.shown, isEmpty);
    });

    test('cached preferences are honoured: category off', () async {
      await seedCache('notification_preferences', _prefs(caps: false).toJson());
      prefsRepo.reachable = false;
      final fired = await gate().fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k');
      expect(fired, isFalse);
      expect(plugin.shown, isEmpty);
    });

    test('cached preferences are honoured: quiet hours', () async {
      await seedCache(
        'notification_preferences',
        _prefs(quietStart: '00:00', quietEnd: '23:59').toJson(),
      );
      prefsRepo.reachable = false;
      final fired = await gate().fire(
        category: 'caps',
        title: 't',
        body: 'b',
        dedupeKey: 'k',
        now: DateTime(2026, 1, 1, 12),
      );
      expect(fired, isFalse);
      expect(plugin.shown, isEmpty);
    });

    test('cached preferences are honoured: daily cap', () async {
      await seedCache('notification_preferences', _prefs(dailyCap: 1).toJson());
      prefsRepo.reachable = false;
      final first = await gate().fire(category: 'caps', title: 'a', body: 'b', dedupeKey: 'k1');
      final second = await gate().fire(category: 'caps', title: 'b', body: 'b', dedupeKey: 'k2');
      expect([first, second], [true, false]);
      expect(plugin.shown, ['a']);
    });

    test('a cached muted merchant suppresses a merchant-scoped alert offline', () async {
      await seedCache('notification_muted_merchants', [
        {'merchant_id': 'm1', 'muted_at': '2026-01-01T00:00:00Z', 'merchant_name': 'Shop'},
      ]);
      await seedCache('notification_preferences', _prefs().toJson());
      prefsRepo.reachable = false;
      final muted = await gate().fire(
        category: 'caps', title: 't', body: 'b', dedupeKey: 'k1', merchantId: 'm1',
      );
      final other = await gate().fire(
        category: 'caps', title: 't2', body: 'b', dedupeKey: 'k2', merchantId: 'm2',
      );
      expect([muted, other], [false, true]);
      expect(plugin.shown, ['t2']);
    });

    test('online and healthy: banner, one inbox POST, nothing queued', () async {
      final fired = await gate().fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k1');
      expect(fired, isTrue);
      expect(plugin.shown, ['t']);
      expect(inbox.rows.keys, ['k1']);
      expect(await pending(), 0);
    });
  });

  group('inbox write is durable', () {
    test('a failed POST is queued and replayed once; no second banner, no duplicate row', () async {
      inbox.reachable = false;
      final g = gate();
      final fired = await g.fire(
        category: 'caps', title: 'Cap near', body: 'b', dedupeKey: 'caps:1', deepLink: '/x',
      );
      expect(fired, isTrue);
      expect(plugin.shown, ['Cap near']);
      expect(inbox.rows, isEmpty);
      expect(await pending(), 1);

      // The same condition is detected again while still offline.
      expect(await g.fire(category: 'caps', title: 'Cap near', body: 'b', dedupeKey: 'caps:1'), isFalse);
      expect(await pending(), 1);

      inbox.reachable = true;
      expect(await replay(), 1);
      expect(inbox.rows.keys, ['caps:1']);
      expect(await pending(), 0);
      expect(plugin.shown, ['Cap near'], reason: 'replay never shows another banner');

      // And again after the reconnect.
      expect(await g.fire(category: 'caps', title: 'Cap near', body: 'b', dedupeKey: 'caps:1'), isFalse);
      expect(plugin.shown.length, 1);
    });

    test('known offline: the POST is not even attempted, the row is queued', () async {
      container.listen(isOnlineProvider, (_, _) {});
      online.add(false);
      await Future<void>.delayed(Duration.zero);
      await gate().fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k1');
      expect(inbox.postAttempts, 0);
      expect(await pending(), 1);
      expect(plugin.shown, ['t']);
    });

    test('the queued payload carries the dedupe key, created time and a mutation id', () async {
      inbox.reachable = false;
      await gate().fire(category: 'bills', title: 't', body: 'b', dedupeKey: 'bills:1', deepLink: '/bills');
      final commands = await container.read(commandOutboxProvider.future);
      final queued = commands.pendingOf({NotificationCommand.recordAppNotification}).single;
      expect(queued.target, 'bills:1');
      expect(queued.payload['dedupeKey'], 'bills:1');
      expect(queued.payload['category'], 'bills');
      expect(queued.payload['deepLink'], '/bills');
      expect(queued.payload['createdAt'], isA<String>());
      expect(queued.payload['clientMutationId'], isA<String>());
    });

    test('recordAppNotification without a dedupe key gets a stable one when it has to queue', () async {
      inbox.reachable = false;
      await recordAppNotification(ref, category: 'streak', title: 'Streak', body: 'b');
      final commands = await container.read(commandOutboxProvider.future);
      final queued = commands.pendingOf({NotificationCommand.recordAppNotification}).single;
      expect(queued.payload['dedupeKey'], startsWith('client:'));
      inbox.reachable = true;
      await replay();
      await replay();
      expect(inbox.rows.length, 1);
    });

    test('a hung POST does not hold the notification: it is queued after the timeout', () async {
      final slow = _SlowInboxRepo();
      final c2 = ProviderContainer(overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        userCardsRepositoryProvider.overrideWithValue(slow),
        notificationPreferencesRepositoryProvider.overrideWithValue(prefsRepo),
        isOnlineProvider.overrideWith((_) => online.stream),
      ]);
      addTearDown(c2.dispose);
      late Ref r2;
      c2.read(Provider<void>((r) => r2 = r));
      final g = NotificationGate(
        ref: r2,
        notifications: plugin,
        inboxTimeout: const Duration(milliseconds: 50),
      );
      final fired = await g.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'slow');
      expect(fired, isTrue);
      expect(plugin.shown, ['t']);
      expect((await c2.read(commandOutboxProvider.future)).pendingCount, 1);
    });
  });

  group('preferences provider', () {
    test('never leaves an error behind: falls back to defaults when offline with no cache', () async {
      prefsRepo.reachable = false;
      final p = await container.read(notificationPreferencesProvider.future);
      expect(p, isNotNull);
      expect(p!.dailyCap, 3);
      expect(container.read(notificationPreferencesProvider).hasError, isFalse);
    });

    test('recovers after an earlier failure once the network is back, without a restart', () async {
      prefsRepo.reachable = false;
      expect((await container.read(notificationPreferencesProvider.future))!.categoryCaps, isTrue);

      prefsRepo.reachable = true;
      prefsRepo.server = _prefs(caps: false);
      online.add(false);
      await Future<void>.delayed(Duration.zero);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final p = await container.read(notificationPreferencesProvider.future);
      expect(p!.categoryCaps, isFalse);
    });

    test('a successful fetch is cached and used when the next fetch fails', () async {
      prefsRepo.server = _prefs(caps: false, dailyCap: 7);
      final fresh = await container.read(notificationPreferencesProvider.future);
      expect(fresh!.dailyCap, 7);

      container.invalidate(notificationPreferencesProvider);
      prefsRepo.reachable = false;
      final offline = await container.read(notificationPreferencesProvider.future);
      expect(offline!.dailyCap, 7);
      expect(offline.categoryCaps, isFalse);
    });

    test('cache first: a cached value returns without waiting for the network, then refreshes', () async {
      await seedCache('notification_preferences', _prefs(dailyCap: 4).toJson());
      await backdate('notification_preferences');
      prefsRepo.gate = Completer<void>();
      prefsRepo.server = _prefs(dailyCap: 9);

      final p = await container
          .read(notificationPreferencesProvider.future)
          .timeout(const Duration(seconds: 2));
      expect(p!.dailyCap, 4, reason: 'served from the cache');

      prefsRepo.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final refreshed = await container.read(notificationPreferencesProvider.future);
      expect(refreshed!.dailyCap, 9, reason: 'background refresh landed');
    });

    test('signed out (no repository) is still null', () async {
      final c = ProviderContainer(overrides: [
        cacheNamespaceProvider.overrideWithValue('signed-out'),
        notificationPreferencesRepositoryProvider.overrideWithValue(null),
      ]);
      addTearDown(c.dispose);
      expect(await c.read(notificationPreferencesProvider.future), isNull);
    });
  });

  group('writes made offline', () {
    test('a toggle offline updates the cache at once and queues one command', () async {
      prefsRepo.reachable = false;
      await updateNotificationPreferences(ref, {'category_caps': false});
      final p = await container.read(notificationPreferencesProvider.future);
      expect(p!.categoryCaps, isFalse);
      final commands = await container.read(commandOutboxProvider.future);
      final queued = commands.pendingOf({NotificationCommand.updatePreferences});
      expect(queued.single.payload['changes'], {'category_caps': false});
    });

    test('two offline toggles merge into one command and both reach the server', () async {
      prefsRepo.reachable = false;
      await updateNotificationPreferences(ref, {'category_caps': false});
      await updateNotificationPreferences(ref, {'daily_cap': 6});
      await updateNotificationPreferences(ref, {'category_caps': true});
      final commands = await container.read(commandOutboxProvider.future);
      expect(commands.pendingCount, 1);

      prefsRepo.reachable = true;
      expect(await replay(), 1);
      expect(prefsRepo.updates.single, {'category_caps': true, 'daily_cap': 6});
    });

    test('a background refresh does not undo a toggle that is still waiting to sync', () async {
      prefsRepo.reachable = false;
      await updateNotificationPreferences(ref, {'category_caps': false});
      await backdate('notification_preferences');
      prefsRepo.reachable = true; // server still holds the old value
      container.invalidate(notificationPreferencesProvider);
      await container.read(notificationPreferencesProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final p = await container.read(notificationPreferencesProvider.future);
      expect(p!.categoryCaps, isFalse);
    });

    test('a refresh already in flight cannot overwrite a toggle made while it ran (WP-H2)', () async {
      await seedCache('notification_preferences', _prefs().toJson());
      await backdate('notification_preferences');
      prefsRepo.gate = Completer<void>();
      await container.read(notificationPreferencesProvider.future); // starts the refresh
      prefsRepo.reachable = false;
      await updateNotificationPreferences(ref, {'category_caps': false});
      prefsRepo.reachable = true; // the held answer is the old server copy
      prefsRepo.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final p = await container.read(notificationPreferencesProvider.future);
      expect(p!.categoryCaps, isFalse);
    });

    test('online, a toggle goes straight to the server and nothing is queued', () async {
      await updateNotificationPreferences(ref, {'category_bills': false});
      expect(prefsRepo.updates, [
        {'category_bills': false},
      ]);
      expect(await pending(), 0);
      final p = await container.read(notificationPreferencesProvider.future);
      expect(p!.categoryBills, isFalse);
    });

    test('a refusal from the server is shown to the caller and rolled back', () async {
      final bad = _RefusingPrefsRepo();
      final c = ProviderContainer(overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        notificationPreferencesRepositoryProvider.overrideWithValue(bad),
        isOnlineProvider.overrideWith((_) => online.stream),
      ]);
      addTearDown(c.dispose);
      late Ref r;
      c.read(Provider<void>((x) => r = x));
      await c.read(notificationPreferencesProvider.future);
      await expectLater(
        updateNotificationPreferences(r, {'daily_cap': 99}),
        throwsA(isA<ApiException>()),
      );
      final p = await c.read(notificationPreferencesProvider.future);
      expect(p!.dailyCap, 3);
      expect((await c.read(commandOutboxProvider.future)).pendingCount, 0);
    });

    test('mute offline: the gate honours it straight away and it syncs later', () async {
      prefsRepo.reachable = false;
      await muteNotificationMerchant(ref, 'm9', merchantName: 'Cafe');
      final fired = await gate().fire(
        category: 'location', title: 't', body: 'b', dedupeKey: 'k', merchantId: 'm9',
      );
      expect(fired, isFalse);

      prefsRepo.reachable = true;
      await replay();
      expect(prefsRepo.muteCalls, ['m9']);
    });

    test('mute then unmute offline cancels out and sends nothing', () async {
      prefsRepo.reachable = false;
      await muteNotificationMerchant(ref, 'm9', merchantName: 'Cafe');
      await unmuteNotificationMerchant(ref, 'm9');
      expect(await pending(), 0);
      prefsRepo.reachable = true;
      await replay();
      expect(prefsRepo.muteCalls, isEmpty);
      expect(prefsRepo.unmuteCalls, isEmpty);
    });
  });

  group('push registration', () {
    test('a failed registration is retried the moment the network is back, not on the timer', () async {
      var reachable = false;
      final calls = <String>[];
      final service = PushNotificationService(
        api: NotificationDevicesApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'access',
          client: MockClient((request) async {
            calls.add(request.method);
            return reachable ? http.Response('', 201) : http.Response('{}', 503);
          }),
        ),
        gate: gate(),
      );
      addTearDown(service.stop);

      await service.debugRegisterToken('synthetic-token');
      expect(calls, ['POST'], reason: 'first attempt failed and a 5 s timer is now pending');

      reachable = true;
      await service.onReconnected();
      expect(calls.length, 2);

      // Registered now: a later reconnect does not post again.
      await service.onReconnected();
      expect(calls.length, 2);
    });

    test('reconnecting before anything was started does nothing', () async {
      final service = PushNotificationService(
        api: NotificationDevicesApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'access',
          client: MockClient((_) async => fail('no request expected')),
        ),
        gate: gate(),
      );
      await service.onReconnected();
    });
  });
}

class _SlowInboxRepo extends _InboxRepo {
  @override
  Future<void> recordNotification({
    required String category,
    required String title,
    String? body,
    String severity = 'info',
    String? deepLink,
    String? dedupeKey,
  }) => Completer<void>().future; // never answers (captive Wi-Fi)
}

class _RefusingPrefsRepo extends _PrefsRepo {
  @override
  Future<NotificationPreferences> update(Map<String, dynamic> changes) async {
    throw ApiException('PUT /notification-preferences failed: 400 {"error":"bad"}');
  }
}
