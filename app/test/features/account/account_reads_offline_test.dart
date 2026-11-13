import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/changelog_repository.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/account/account_commands.dart';
import 'package:pandapay/features/notifications/notification_read.dart';
import 'package:pandapay/features/settings/whats_new_providers.dart';

// WP-C11: cached reads and optimistic read marks. Synthetic data only.

const _ns = 'user:test-account';

class _Repo extends UserCardsRepository {
  _Repo() : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  bool reachable = false;
  final reads = <String?>[];

  @override
  Future<({List<AppNotification> items, int unreadCount})>
  fetchNotifications() async {
    if (!reachable) throw const SocketException('offline');
    return (items: <AppNotification>[], unreadCount: 0);
  }

  @override
  Future<void> markNotificationsRead({String? id}) async {
    if (!reachable) throw const SocketException('offline');
    reads.add(id);
  }
}

Map<String, Object?> _n(String id, {String? readAt}) => {
  'id': id,
  'category': 'general',
  'severity': 'info',
  'title': 'Title $id',
  'body': null,
  'deep_link': null,
  'read_at': readAt,
  'created_at': '2026-11-10T10:00:00.000Z',
};

void main() {
  late ProviderContainer container;
  late Ref ref;
  late _Repo repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    KnownConnectivity.online = false;
    repo = _Repo();
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        accessTokenProvider.overrideWith((_) => 'tok'),
        userCardsRepositoryProvider.overrideWithValue(repo),
      ],
    );
    container.read(Provider<void>((r) => ref = r));
  });

  tearDown(() {
    KnownConnectivity.reset();
    container.dispose();
  });

  test('inbox shows the saved copy offline; a read mark is optimistic and queued', () async {
    final cache = await container.read(responseCacheProvider.future);
    await cache.put(
      '$_ns:notifications',
      jsonEncode({
        'notifications': [_n('a'), _n('b')],
        'unreadCount': 2,
      }),
    );
    var inbox = await container.read(notificationsProvider.future);
    expect(inbox.items, hasLength(2));
    expect(inbox.unreadCount, 2);

    await markNotificationsReadLocalFirst(ref, id: 'a');
    inbox = await container.read(notificationsProvider.future);
    expect(inbox.items.firstWhere((n) => n.id == 'a').isUnread, isFalse);
    expect(inbox.items.firstWhere((n) => n.id == 'b').isUnread, isTrue);
    expect(inbox.unreadCount, 1);

    final commands = await container.read(commandOutboxProvider.future);
    expect(commands.pendingCount, 1);

    KnownConnectivity.online = true;
    repo.reachable = true;
    expect(await commands.flush(accountCommandHandlers(ref)), 1);
    expect(repo.reads, ['a']);
  });

  test('mark all read is queued and survives an inbox refresh', () async {
    final cache = await container.read(responseCacheProvider.future);
    await cache.put(
      '$_ns:notifications',
      jsonEncode({
        'notifications': [_n('a'), _n('b')],
        'unreadCount': 2,
      }),
    );
    await markNotificationsReadLocalFirst(ref);
    final inbox = await container.read(notificationsProvider.future);
    expect(inbox.unreadCount, 0);
    expect(inbox.items.every((n) => !n.isUnread), isTrue);
  });

  test('changelog falls back to the last good copy when the network fails', () async {
    final entry = {
      'id': 'c1',
      'app_version': '1.2.3',
      'title': 'Synthetic release',
      'body_markdown': 'Notes',
      'highlights_data_change': false,
      'published_at': '2026-11-01T00:00:00.000Z',
    };
    var fail = false;
    final repository = ChangelogRepository(
      apiBaseUrl: 'http://test.local',
      client: MockClient((_) async {
        if (fail) throw const SocketException('offline');
        return http.Response(
          jsonEncode({
            'entries': [entry],
          }),
          200,
        );
      }),
    );
    final c = ProviderContainer(
      overrides: [changelogRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(c.dispose);
    expect((await c.read(changelogProvider.future)).single.title, 'Synthetic release');
    fail = true;
    c.invalidate(changelogProvider);
    final again = await c.read(changelogProvider.future);
    expect(again.single.appVersion, '1.2.3');
  });
}
