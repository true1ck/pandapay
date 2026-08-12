import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_user_cards_repository.dart';
import 'package:pandapay/features/auth/guest_migration.dart';

/// Plan Phase 1.2. The property that actually matters here is the ORDER:
/// the local guest wallet must not be deleted until the server has confirmed
/// it received it. Get that wrong and signing up — the single most important
/// moment in the funnel — silently destroys everything the user built while
/// trying the app out.
///
/// So the failure paths are tested at least as carefully as the happy one: a
/// non-201, a thrown socket error, and a signed-out call must all leave the
/// local rows exactly where they were.
void main() {
  late AppDatabase appDb;
  late LocalUserCardsRepository local;

  setUp(() {
    appDb = openInMemoryForTesting();
    local = LocalUserCardsRepository(appDb);
  });
  tearDown(() => appDb.close());

  ProviderContainer harness({required http.Client client, String? token = 'test-token'}) {
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => token),
        localUserCardsRepositoryProvider.overrideWith((ref) async => local),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  GuestMigration migrationWith(ProviderContainer container, http.Client client) {
    // Read through a Provider so GuestMigration gets a real Ref, matching how
    // guestMigrationProvider constructs it in the app.
    late GuestMigration built;
    final p = Provider<GuestMigration>((ref) => built = GuestMigration(ref, client: client));
    container.read(p);
    return built;
  }

  test('a guest wallet is posted and only then cleared locally', () async {
    await local.addCard('product-1', nickname: 'Everyday');
    await local.addCard('product-2');

    Map<String, dynamic>? sentBody;
    final client = MockClient((request) async {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'results': [
            {'localId': 'a', 'status': 'imported'},
            {'localId': 'b', 'status': 'imported'},
          ],
          'importedCount': 2,
        }),
        201,
      );
    });

    final container = harness(client: client);
    final result = await migrationWith(container, client).run();

    expect(result.imported, 2);
    expect(await local.count(), 0, reason: 'cleared only after a confirmed 201');

    final cards = (sentBody!['cards'] as List).cast<Map<String, dynamic>>();
    expect(cards, hasLength(2));
    expect(cards.first['cardProductId'], 'product-1');
    expect(cards.first['nickname'], 'Everyday');
    expect(cards.first['isDefault'], isTrue, reason: 'first guest card is the default');
  });

  test('a server error leaves the local wallet completely intact', () async {
    await local.addCard('product-1');
    final client = MockClient((_) async => http.Response('{"error":"internal_error"}', 500));

    final container = harness(client: client);

    await expectLater(migrationWith(container, client).run(), throwsA(isA<Exception>()));
    expect(await local.count(), 1, reason: 'a failed push must never destroy the guest wallet');
  });

  test('a transport failure leaves the local wallet completely intact', () async {
    await local.addCard('product-1');
    final client = MockClient((_) async => throw const _OfflineError());

    final container = harness(client: client);

    await expectLater(migrationWith(container, client).run(), throwsA(isA<_OfflineError>()));
    expect(await local.count(), 1);
  });

  test('archived guest cards travel too, rather than being dropped on signup', () async {
    // R4 is "archive, never delete". Signing up must not be a back door
    // through which an archived card silently disappears.
    final id = await local.addCard('product-1');
    await local.archiveCard(id);

    Map<String, dynamic>? sentBody;
    final client = MockClient((request) async {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'results': [], 'importedCount': 0}), 201);
    });

    final container = harness(client: client);
    await migrationWith(container, client).run();

    final cards = (sentBody!['cards'] as List).cast<Map<String, dynamic>>();
    expect(cards, hasLength(1));
    expect(cards.single['isArchived'], isTrue);
  });

  test('an empty guest wallet makes no request at all', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 201);
    });

    final container = harness(client: client);
    final result = await migrationWith(container, client).run();

    expect(called, isFalse);
    expect(result.didAnything, isFalse);
  });

  test('signed out, nothing is sent and nothing is cleared', () async {
    await local.addCard('product-1');
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 201);
    });

    final container = harness(client: client, token: null);
    final result = await migrationWith(container, client).run();

    expect(called, isFalse);
    expect(result.didAnything, isFalse);
    expect(await local.count(), 1);
  });
}

class _OfflineError implements Exception {
  const _OfflineError();
}
