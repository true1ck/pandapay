import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';

/// WP-C3 / Q-11: pendingRecoveryStatusProvider reads QueueRegistry. Its keys
/// 'sms', 'blocked' and 'legacy' keep their meaning; applied changes are not
/// counted; parked rows of the other queues are counted separately.
const _ns = 'user:11111111-1111-4111-8111-111111111111';

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  late ProviderContainer container;

  void run(String sql, [List<Object?> args = const []]) =>
      db.db.execute(sql, args);

  setUp(() {
    db = openInMemoryForTesting();
    SmsV2Schema.ensure(db.db);
    ensureForeignPaymentsSchema(db);
    SmsIntakeRepository(db);
    run('''CREATE TABLE IF NOT EXISTS command_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
      kind TEXT NOT NULL, target TEXT NOT NULL, payload_json TEXT NOT NULL,
      created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, next_attempt_at INTEGER NOT NULL DEFAULT 0,
      parked INTEGER NOT NULL DEFAULT 0)''');
    cache = ResponseCache(db);
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        responseCacheProvider.overrideWith((ref) async => cache),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    cache.financialStore.dispose();
    db.close();
  });

  test('an empty account reports zeros', () async {
    expect(await container.read(pendingRecoveryStatusProvider.future), {
      'sms': 0,
      'blocked': 0,
      'parked': 0,
      'awaiting': 0,
      'legacy': 0,
    });
  });

  test('blocked, parked and applied rows are told apart', () async {
    // sync_pending_changes: 1 healthy, 1 parked (attempts>=5), 1 applied that
    // is also past its attempts (must not count anywhere).
    run(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at, attempts, in_flight) '
      "VALUES (?, 'transactions', 'a', 'update', '{}', '{}', 1, 0, 0), "
      "(?, 'transactions', 'b', 'update', '{}', '{}', 1, 5, 0), "
      "(?, 'transactions', 'c', 'update', '{}', '{}', 1, 5, 2)",
      [_ns, _ns, _ns],
    );
    // A parked command counts as blocked (as before).
    run(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at, parked) '
      "VALUES (?, 'x', 't', '{}', 1, 1)",
      [_ns],
    );
    // Parked rows of queues the recovery screen cannot retry: 'parked'.
    run(
      'INSERT INTO transaction_outbox_entries '
      '(namespace, client_mutation_id, amount_paise, created_at, parked) '
      "VALUES (?, 'm', 1, 1, 1)",
      [_ns],
    );
    // A Split command waiting for a sign-in: 'awaiting'.
    run(
      'INSERT INTO shared_commands '
      '(namespace, operation_id, context_id, kind, request_json, request_hash, state, created_at) '
      "VALUES (?, 'op', 'c', 'k', '{}', 'h', 'awaitingAuth', 1)",
      [_ns],
    );
    // Messages waiting to be read.
    run(
      "INSERT INTO sms_intake (namespace, id, sender, body, received_at) VALUES (?, 'i1', 'S', 'b', 1), (?, 'i2', 'S', 'b', 1)",
      [_ns, _ns],
    );

    final status = await container.read(pendingRecoveryStatusProvider.future);

    expect(status['sms'], 2);
    expect(status['blocked'], 2, reason: 'one parked edit + one parked command');
    expect(status['parked'], 1);
    expect(status['awaiting'], 1);
    expect(status['legacy'], 0);
  });

  test('legacy rows keep being counted from the raw tables', () async {
    run(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES ('legacy', 'transactions', 'a', 'update', '{}', '{}', 1)",
    );
    final status = await container.read(pendingRecoveryStatusProvider.future);
    expect(status['legacy'], 1);
    expect(status['blocked'], 0);
  });
}
