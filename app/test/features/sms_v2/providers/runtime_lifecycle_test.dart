import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Q-08: the connection coming back makes every waiting upload due at once,
/// instead of leaving it behind a back-off that was set while offline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('offline to online resets the upload back-off and syncs', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(db);
    addTearDown(() {
      financial.dispose();
      db.db.dispose();
    });
    final encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    final bundle = RuleBundle.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );
    final paths = <String>[];
    final now = DateTime.utc(2026, 11, 1, 7);
    final runtime = SmsV2Runtime(
      financial: financial,
      namespace: 'user:test',
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response('', 304);
      }),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => now,
    );
    final queue = OutboxStore(db.db, namespace: 'user:test');
    queue.enqueue('other', 'x', {'a': 1});
    queue.retry(queue.due(DateTime.utc(2100)).single, now);
    expect(queue.due(now), isEmpty);

    final online = StreamController<bool>();
    addTearDown(online.close);
    final container = ProviderContainer(
      overrides: [
        app.isOnlineProvider.overrideWith((ref) => online.stream),
        smsV2RuntimeProvider.overrideWith((ref) async => runtime),
      ],
    );
    addTearDown(container.dispose);
    container.listen(app.isOnlineProvider, (_, _) {});
    container.read(smsV2LifecycleProvider);
    online.add(false);
    await pumpEventQueue();
    paths.clear();
    expect(queue.due(now), isEmpty, reason: 'still waiting while offline');
    online.add(true);
    await pumpEventQueue(times: 200);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(queue.due(now), hasLength(1), reason: 'back-off reset on reconnect');
    expect(paths, isNotEmpty, reason: 'a sync ran');
  });
}
