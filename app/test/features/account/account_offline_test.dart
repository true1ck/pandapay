import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/account_name_api.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/account/account_commands.dart';
import 'package:pandapay/features/account/account_local_first.dart';
import 'package:pandapay/features/account/card_reports.dart';
import 'package:pandapay/features/account/contributions_opt_in.dart';
import 'package:pandapay/features/account/support_submit.dart';

// WP-C11: account writes without the network. Synthetic data only.

const _ns = 'user:test-account';

class _Repo extends UserCardsRepository {
  _Repo() : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  bool reachable = false;
  final optIns = <bool>[];
  final reads = <String?>[];

  @override
  Future<void> setContributionsOptIn(bool optIn) async {
    if (!reachable) throw const SocketException('offline');
    optIns.add(optIn);
  }

  @override
  Future<void> markNotificationsRead({String? id}) async {
    if (!reachable) throw const SocketException('offline');
    reads.add(id);
  }
}

class _Names extends AccountNameApi {
  _Names()
    : super(
        apiBaseUrl: 'http://test.local',
        authBaseUrl: 'http://auth.local',
        accessToken: 'tok',
      );
  final saved = <String>[];
  @override
  Future<Map<String, dynamic>> save(String typed) async {
    saved.add(typed);
    return {'display_name': typed};
  }
}

void main() {
  late ProviderContainer container;
  late Ref ref;
  late _Repo repo;
  late _Names names;

  setUp(() {
    KnownConnectivity.online = false;
    repo = _Repo();
    names = _Names();
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        accessTokenProvider.overrideWith((_) => 'tok'),
        userCardsRepositoryProvider.overrideWithValue(repo),
        accountNameApiProvider.overrideWithValue(names),
        profileProvider.overrideWith(
          (_) async => {'display_name': 'Old', 'contributions_opt_in': false},
        ),
      ],
    );
    container.read(Provider<void>((r) => ref = r));
  });

  tearDown(() {
    KnownConnectivity.reset();
    container.dispose();
  });

  Future<int> pending() async =>
      (await container.read(commandOutboxProvider.future)).pendingCount;

  Future<int> flush() async => (await container.read(
    commandOutboxProvider.future,
  )).flush(accountCommandHandlers(ref));

  test('opt-in toggle offline queues, patches the profile, replays', () async {
    await container.read(profileProvider.future);
    final r = await setContributionsOptInLocalFirst(ref, true);
    expect(r, AccountWrite.queued);
    expect(await pending(), 1);
    final cache = await container.read(responseCacheProvider.future);
    final saved = await cache.get('$_ns:profile');
    expect(saved, contains('"contributions_opt_in":true'));

    KnownConnectivity.online = true;
    repo.reachable = true;
    expect(await flush(), 1);
    expect(repo.optIns, [true]);
  });

  test('opt-in toggled twice offline sends only the latest', () async {
    await setContributionsOptInLocalFirst(ref, true);
    await setContributionsOptInLocalFirst(ref, false);
    expect(await pending(), 1);
    KnownConnectivity.online = true;
    repo.reachable = true;
    await flush();
    expect(repo.optIns, [false]);
  });

  test('profile name command replays through the two-step save', () async {
    await queueAccountCommand(
      ref,
      kind: AccountCommand.profileName,
      target: 'profile_name',
      payload: {'name': 'New Name'},
    );
    expect(await flush(), 1);
    expect(names.saved, ['New Name']);
  });

  test('support ticket offline is queued with a client id, kept until sent', () async {
    final r = await submitTicketLocalFirst(
      ref,
      accessToken: 'tok',
      kind: 'bug',
      message: 'It broke',
      diagnostics: {'platform': 'test'},
      appVersion: '1.0.0+1',
    );
    expect(r, AccountWrite.queued);
    final commands = await container.read(commandOutboxProvider.future);
    final queued = commands
        .pendingOf({AccountCommand.supportTicket})
        .single
        .payload;
    expect(queued['id'], isNotEmpty);
    expect(queued['message'], 'It broke');
    // No handler server here: the replay fails as "cannot reach" and the
    // ticket stays queued (it is not dropped).
    expect(await pending(), 1);
  });

  test('two card reports offline are two queued commands', () async {
    await requestNewCardLocalFirst(ref, issuerName: 'Bank A', productName: 'Card A');
    await requestNewCardLocalFirst(ref, issuerName: 'Bank B', productName: 'Card B');
    await reportWrongDataLocalFirst(
      ref,
      cardProductId: 'p1',
      fieldPath: 'annual_fee',
      claimedValue: '500',
    );
    expect(await pending(), 3);
  });

  test('inbox read marks replay, mark-all after mark-one both go', () async {
    await queueAccountCommand(
      ref,
      kind: AccountCommand.notificationRead,
      target: 'n1',
      payload: {'id': 'n1'},
    );
    await queueAccountCommand(
      ref,
      kind: AccountCommand.notificationReadAll,
      target: 'all',
      payload: {},
    );
    KnownConnectivity.online = true;
    repo.reachable = true;
    expect(await flush(), 2);
    expect(repo.reads, ['n1', null]);
  });
}
