import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/session_end_reason.dart';
import 'package:pandapay/data/token_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WP-C3 / L-01 / D10: a refresh token the server rejects ends the SESSION,
/// not the person's data. Only an explicit sign-out clears the account.
/// Synthetic ids and amounts only.
String _jwt(String subject) {
  String enc(Map<String, Object?> v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${enc({'alg': 'none', 'typ': 'JWT'})}.${enc({'sub': subject})}.sig';
}

Future<void> _settle() async {
  // Listener callbacks and the async cache lookup inside them.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  late ProviderContainer container;
  late TokenStore store;
  final tokenA = _jwt('11111111-1111-4111-8111-111111111111');
  final tokenB = _jwt('22222222-2222-4222-8222-222222222222');
  const nsA = 'user:11111111-1111-4111-8111-111111111111';
  const nsB = 'user:22222222-2222-4222-8222-222222222222';

  void seed(String ns) {
    cache.financialStore.setManualBankBalance(
      ns,
      issuer: 'Test Bank',
      accountLast4: '1234',
      balance: Money.fromPaise(125000),
    );
    cache.financialStore.saveCardBillAssignment(
      ns,
      'obs-1',
      userCardId: 'card-1',
      amountDuePaise: 50000,
      dueDate: DateTime(2026, 11, 20),
    );
    cache.financialStore.saveProvisional(
      ns,
      TransactionEntry(
        id: 'local-sms:one',
        amount: Money.fromPaise(10000),
        occurredAt: DateTime(2026, 10, 18),
        sourceKey: 'one',
        merchantName: 'Shop',
        source: 'sms',
        status: 'active',
      ),
    );
    SyncQueue(db, namespace: ns)
      ..enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn-1',
        fields: {'note': 'queued edit'},
      )
      ..deviceId = 'device-$ns'
      ..lastServerSeq = 42;
    CommandOutbox(
      db,
      namespace: ns,
    ).enqueue(kind: 'ignore_transaction', target: 'txn-2');
  }

  int localOnlyCount(String ns) =>
      cache.financialStore.entities(ns, 'bill_card_assignments').length +
      cache.financialStore.entities(ns, 'manual_bank_balances').length +
      cache.financialStore.entities(ns, 'transactions').length;

  int queuedCount(String ns) =>
      SyncQueue(db, namespace: ns).pendingCount +
      CommandOutbox(db, namespace: ns).pendingCount;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await TokenStore.load();
    await store.save(accessToken: tokenA, refreshToken: 'refresh-a');
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    await cache.put('$nsA:user_cards', '[]');
    seed(nsA);
    final client = MockClient(
      (_) async => http.Response('{"error":"Invalid refresh token"}', 401),
    );
    container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWith((ref) async => store),
        authApiProvider.overrideWithValue(
          AuthApi(authBaseUrl: 'http://auth.test', client: client),
        ),
        appDatabaseProvider.overrideWith((ref) async => db),
        responseCacheProvider.overrideWith((ref) async => cache),
      ],
    );
    container.read(accessTokenProvider.notifier).state = tokenA;
    // Mounted for the app's whole lifetime in `_AppShell`.
    container.listen(cacheNamespaceProvider, (_, _) {});
    container.read(cacheLifecycleProvider);
    expect(container.read(cacheNamespaceProvider), nsA);
  });

  tearDown(() async {
    container.dispose();
    cache.financialStore.dispose();
    db.close();
    await store.clear();
  });

  test(
    'a refresh the server rejects clears the tokens but keeps every local '
    'entity, queue row and cached response',
    () async {
      expect(localOnlyCount(nsA), greaterThan(0));
      expect(queuedCount(nsA), 2);

      final result = await container
          .read(sessionRefreshCoordinatorProvider)
          .refresh();
      await _settle();

      expect(result, isNull);
      expect(container.read(accessTokenProvider), isNull);
      expect(store.refreshToken, isNull, reason: 'credentials stay cleared');
      expect(container.read(cacheNamespaceProvider), 'signed-out');
      expect(
        container.read(sessionEndReasonProvider).reason,
        SessionEndReason.sessionRejected,
      );

      expect(
        cache.financialStore.entities(nsA, 'bill_card_assignments'),
        hasLength(1),
      );
      expect(
        cache.financialStore.entities(nsA, 'manual_bank_balances'),
        hasLength(1),
      );
      expect(
        cache.financialStore.entities(nsA, 'transactions'),
        hasLength(1),
        reason: 'the provisional SMS row',
      );
      expect(queuedCount(nsA), 2);
      expect(await cache.get('$nsA:user_cards'), isNotNull);
      final state = SyncQueue(db, namespace: nsA);
      expect(state.deviceId, 'device-$nsA');
      expect(state.lastServerSeq, 42);
    },
  );

  test('the same person signing in again finds the data and queue', () async {
    await container.read(sessionRefreshCoordinatorProvider).refresh();
    await _settle();
    expect(container.read(cacheNamespaceProvider), 'signed-out');

    container.read(accessTokenProvider.notifier).state = tokenA;
    await _settle();

    expect(container.read(cacheNamespaceProvider), nsA);
    expect(
      container.read(sessionEndReasonProvider).reason,
      isNull,
      reason: 'a new session forgets how the last one ended',
    );
    expect(localOnlyCount(nsA), 3);
    expect(queuedCount(nsA), 2);
    expect(SyncQueue(db, namespace: nsA).deviceId, 'device-$nsA');
  });

  test('a different person signing in sees none of it', () async {
    await container.read(sessionRefreshCoordinatorProvider).refresh();
    await _settle();

    container.read(accessTokenProvider.notifier).state = tokenB;
    await _settle();

    expect(container.read(cacheNamespaceProvider), nsB);
    final queueB = SyncQueue(db, namespace: nsB);
    expect(queueB.pendingCount, 0);
    expect(queueB.deviceId, isNull);
    expect(CommandOutbox(db, namespace: nsB).pendingCount, 0);
    expect(localOnlyCount(nsB), 0);
    expect(await cache.get('$nsB:user_cards'), isNull);
    // The first person's rows are still theirs, untouched.
    expect(localOnlyCount(nsA), 3);
  });

  test('an explicit sign-out still clears the account as before', () async {
    // What AccountSignOut.run does first, then closeDatabases drops the token.
    container.read(sessionEndReasonProvider).markUserSignedOut();
    container.read(accessTokenProvider.notifier).state = null;
    await _settle();

    expect(container.read(cacheNamespaceProvider), 'signed-out');
    expect(cache.financialStore.entities(nsA, 'bill_card_assignments'), isEmpty);
    expect(cache.financialStore.entities(nsA, 'manual_bank_balances'), isEmpty);
    expect(cache.financialStore.entities(nsA, 'transactions'), isEmpty);
    expect(await cache.get('$nsA:user_cards'), isNull);
  });

  test(
    'a 401 that arrives while the person is signing out does not downgrade '
    'the sign-out',
    () async {
      container.read(sessionEndReasonProvider)
        ..markUserSignedOut()
        ..markSessionRejected();
      expect(
        container.read(sessionEndReasonProvider).mayWipeAccountData,
        isTrue,
      );
      container.read(accessTokenProvider.notifier).state = null;
      await _settle();
      expect(
        cache.financialStore.entities(nsA, 'manual_bank_balances'),
        isEmpty,
      );
    },
  );

  test('an unknown reason keeps the data (the safe default)', () async {
    container.read(accessTokenProvider.notifier).state = null;
    await _settle();
    expect(
      cache.financialStore.entities(nsA, 'manual_bank_balances'),
      hasLength(1),
    );
    expect(queuedCount(nsA), 2);
  });
}
