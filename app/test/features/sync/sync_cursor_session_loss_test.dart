import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/session_end_reason.dart';
import 'package:pandapay/features/sync/split_sync.dart';
import 'package:pandapay/features/sync/sync_engine.dart';

/// WP-C3 / L-01 / SRV-05: the sync device id and cursor belong to the account.
/// They are kept when the server rejects the session (the same person resumes
/// with the same device), and reset on an explicit sign-out as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ns = 'user:11111111-1111-4111-8111-111111111111';

  Future<(ProviderContainer, AppDatabase)> boot() async {
    final db = openInMemoryForTesting();
    SyncQueue(db, namespace: ns)
      ..deviceId = 'device-1'
      ..lastServerSeq = 7;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async => db),
        transactionTagsProvider.overrideWith((ref) => null),
        splitSyncLifecycleProvider.overrideWithValue(null),
      ],
    );
    container.read(accessTokenProvider.notifier).state =
        // Unsigned token whose subject maps to [ns].
        'e30.eyJzdWIiOiIxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTEifQ.sig';
    container.listen(cacheNamespaceProvider, (_, _) {});
    expect(container.read(cacheNamespaceProvider), ns);
    container.read(syncLifecycleProvider);
    // In the running app the database provider is alive for the whole session;
    // the sign-out reset only touches a database that is still open (H1-7).
    await container.read(appDatabaseProvider.future);
    return (container, db);
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a rejected session keeps the device id and the cursor', () async {
    final (container, db) = await boot();
    addTearDown(() {
      container.dispose();
      db.close();
    });
    container.read(sessionEndReasonProvider).markSessionRejected();
    container.read(accessTokenProvider.notifier).state = null;
    await settle();

    final queue = SyncQueue(db, namespace: ns);
    expect(queue.deviceId, 'device-1');
    expect(queue.lastServerSeq, 7);
  });

  test('an explicit sign-out resets them, as before', () async {
    final (container, db) = await boot();
    addTearDown(() {
      container.dispose();
      db.close();
    });
    container.read(sessionEndReasonProvider).markUserSignedOut();
    container.read(accessTokenProvider.notifier).state = null;
    await settle();

    final queue = SyncQueue(db, namespace: ns);
    expect(queue.deviceId, isNull);
    expect(queue.lastServerSeq, 0);
  });
}
