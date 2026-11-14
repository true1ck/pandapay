// Scenario w: a storm of typed edits queued offline survives a 503 pause and
// the noise other background calls make while it lasts (QA run 3, F-1/F-2).
// Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/server_backoff.dart';
import 'package:pandapay/features/payments/payment_method_command.dart';

import 'harness.dart';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() async {
    ServerBackoff.process.resetForTest();
    await app.dispose();
  });

  Future<List<String>> seedAndQueue(int n) async {
    final ids = [
      for (var i = 0; i < n; i++)
        app.server.seedTransaction(amount: 100.0 + i)['id'] as String,
    ];
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    for (var i = 0; i < ids.length; i++) {
      await queueCommand(
        app.ref,
        kind: PaymentMethodCommand.setTyped,
        target: ids[i],
        payload: {'id': ids[i], 'amountInr': 500.0 + i},
      );
    }
    return ids;
  }

  bool allArrived(List<String> ids) => ids.indexed.every(
    (e) => app.server.transactions[e.$2]!['amount_inr'] == 500.0 + e.$1,
  );

  test('w1. 24 edits queued offline all arrive soon after one 503 pause, '
      'without waiting for the command backoff', () async {
    final ids = await seedAndQueue(24);
    var first = true;
    app.server.retryAfterSeconds = 1;
    app.server.failWhen = (m, p, b) {
      if (m == 'PATCH' && first) {
        first = false;
        return 503;
      }
      return null;
    };
    await app.goOnline();
    // The clock is never advanced: the refused head command must not be held
    // back by a 30 s backoff on top of the server's 1 s Retry-After.
    await app.until(() => allArrived(ids), what: 'all 24 edits');
    expect(
      app.server.log.where((r) => r.method == 'PATCH').length,
      25,
      reason: 'one refused try plus one delivery each, no duplicates',
    );
  });

  test('w2. a read 429 and a push-provider 503 do not freeze the queue',
      () async {
    final ids = await seedAndQueue(24);
    // What the QA phone saw while it was offline-then-online: the rules
    // download answered 429 with a Retry-After of about half an hour, and the
    // push registration answered 503 without one, again and again.
    ServerBackoff.process.noteResponse(
      429,
      '1909',
      path: '/sms/v2/rules',
      method: 'GET',
    );
    ServerBackoff.process.noteResponse(
      503,
      null,
      path: '/notification-devices',
      method: 'POST',
    );
    expect(ServerBackoff.process.isPaused, isFalse);
    await app.goOnline();
    await app.until(() => allArrived(ids), what: 'all 24 edits');
  });

  test('w3. a 429 on a write route still pauses every queue', () async {
    await seedAndQueue(2);
    ServerBackoff.process.noteResponse(
      429,
      '30',
      path: '/transactions/x',
      method: 'PATCH',
    );
    expect(ServerBackoff.process.isPaused, isTrue);
  });
}
