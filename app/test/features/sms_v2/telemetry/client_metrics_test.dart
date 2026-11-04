import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/telemetry/client_metrics.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  var consent = true;
  var now = DateTime.utc(2026, 11, 4, 9);
  late ClientMetrics metrics;

  ClientMetrics make({String namespace = 'a', Future<bool> Function()? gate}) =>
      ClientMetrics(
        state: SyncStateStore(db, namespace: namespace),
        hasConsent: gate ?? () async => consent,
        clock: () => now,
      );

  Map<String, int> stored(String day, {String namespace = 'a'}) {
    final rows = db.select(
      'SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
      [namespace, 'metrics:d:$day:%'],
    );
    return {
      for (final row in rows)
        (row['key'] as String).split(':').last: int.parse(
          row['value'] as String,
        ),
    };
  }

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    consent = true;
    now = DateTime.utc(2026, 11, 4, 9);
    metrics = make();
  });
  tearDown(() => db.dispose());

  Future<void> upload(
    ClientMetrics m,
    http.Client client, {
    String version = '2.0.1+7',
    bool Function()? current,
  }) => m.upload(
    client: client,
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {'Authorization': 'Bearer fixture'},
    appVersion: version,
    accountIsCurrent: current ?? () => true,
  );

  test('classifies failures into coarse reasons and ignores account changes', () {
    expect(
      ClientMetrics.classify(TimeoutException('x')),
      SyncErrorReason.timeout,
    );
    expect(
      ClientMetrics.classify(const SocketException('x')),
      SyncErrorReason.network,
    );
    expect(
      ClientMetrics.classify(http.ClientException('x')),
      SyncErrorReason.network,
    );
    expect(
      ClientMetrics.classify(const HttpException('x')),
      SyncErrorReason.server,
    );
    expect(
      ClientMetrics.classify(SqliteException(1, 'x')),
      SyncErrorReason.storage,
    );
    expect(
      ClientMetrics.classify(const FormatException('x')),
      SyncErrorReason.data,
    );
    expect(ClientMetrics.classify(Exception('x')), SyncErrorReason.other);
  });

  test('counts sync attempts and errors by reason, and rethrows the failure', () async {
    await metrics.measureSync(() async {});
    await metrics.measureSync(() async {});
    await expectLater(
      metrics.measureSync(() async => throw const SocketException('offline')),
      throwsA(isA<SocketException>()),
    );
    await expectLater(
      metrics.measureSync(() async => throw TimeoutException('slow')),
      throwsA(isA<TimeoutException>()),
    );
    // An account switch is not a failed sync and not an attempt.
    await expectLater(
      metrics.measureSync(() async => throw StateError('SMS account changed')),
      throwsA(isA<StateError>()),
    );
    expect(stored('2026-11-04'), {
      'sync_attempts': 4,
      'sync_errors_network': 1,
      'sync_errors_timeout': 1,
    });
  });

  test('counts migration started, completed and failed', () async {
    expect(await metrics.measureMigration(() async => 'report'), 'report');
    await expectLater(
      metrics.measureMigration<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    await expectLater(
      metrics.measureMigration<void>(
        () async => throw StateError('Migration account changed'),
      ),
      throwsStateError,
    );
    await metrics.bundleDownloadFailed();
    expect(stored('2026-11-04'), {
      'migration_started': 3,
      'migration_completed': 1,
      'migration_failed': 1,
      'bundle_download_failures': 1,
    });
  });

  test('without sharing consent nothing is counted, and stored counts are deleted', () async {
    consent = false;
    await metrics.measureSync(() async {});
    await metrics.bundleDownloadFailed();
    expect(stored('2026-11-04'), isEmpty);

    consent = true;
    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 5, 9);
    expect(stored('2026-11-04'), isNotEmpty);
    consent = false;
    var posted = 0;
    await upload(
      metrics,
      MockClient((request) async {
        posted++;
        return http.Response('{}', 202);
      }),
    );
    expect(posted, 0);
    expect(stored('2026-11-04'), isEmpty, reason: 'withdrawal removes counts');
  });

  test('counts survive a restart and stay within one account', () async {
    await metrics.measureSync(() async {});
    await make().measureSync(() async {});
    await make(namespace: 'b').measureSync(() async {});
    expect(stored('2026-11-04'), {'sync_attempts': 2});
    expect(stored('2026-11-04', namespace: 'b'), {'sync_attempts': 1});
  });

  test('uploads only closed days, with a payload of counts and nothing else', () async {
    await metrics.measureSync(() async {});
    await expectLater(
      metrics.measureSync(() async => throw const SocketException('offline')),
      throwsA(anything),
    );
    final bodies = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      expect(request.url.path, '/sms/v2/client-metrics');
      expect(request.headers['Authorization'], 'Bearer fixture');
      bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
      return http.Response('{"status":"recorded"}', 202);
    });
    await upload(metrics, client);
    expect(bodies, isEmpty, reason: 'today is still open');

    now = DateTime.utc(2026, 11, 5, 9);
    await upload(metrics, client);
    expect(bodies, hasLength(1));
    expect(bodies.single, {
      'day': '2026-11-04',
      'appVersion': '2.0.1+7',
      'counters': {'sync_attempts': 2, 'sync_errors_network': 1},
    });
    expect(stored('2026-11-04'), isEmpty);

    // At most daily, even with new closed counts.
    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 5, 20);
    await upload(metrics, client);
    expect(bodies, hasLength(1));
    now = DateTime.utc(2026, 11, 6, 10);
    await upload(metrics, client);
    expect(bodies, hasLength(2));
    expect(bodies.last['day'], '2026-11-05');
  });

  test('a failed upload keeps the counts and retries no sooner than an hour', () async {
    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 5, 9);
    var calls = 0;
    var status = 503;
    final client = MockClient((request) async {
      calls++;
      return http.Response('{}', status);
    });
    await upload(metrics, client);
    expect(calls, 1);
    expect(stored('2026-11-04'), {'sync_attempts': 1});
    now = now.add(const Duration(minutes: 20));
    await upload(metrics, client);
    expect(calls, 1);
    now = now.add(const Duration(hours: 1));
    status = 202;
    await upload(metrics, client);
    expect(calls, 2);
    expect(stored('2026-11-04'), isEmpty);
  });

  test('a rejected day is dropped, a network error is swallowed, old days are discarded', () async {
    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 5, 9);
    await upload(metrics, MockClient((_) async => http.Response('{}', 400)));
    expect(stored('2026-11-04'), isEmpty);

    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 6, 9);
    await upload(
      metrics,
      MockClient((_) async => throw const SocketException('offline')),
    );
    expect(stored('2026-11-05'), {'sync_attempts': 1}, reason: 'kept for a retry');

    now = DateTime.utc(2026, 11, 20, 9);
    await upload(metrics, MockClient((_) async => http.Response('{}', 503)));
    expect(stored('2026-11-05'), isEmpty, reason: 'too old for the server');
  });

  test('uploads at most three days at once and sanitises the app version', () async {
    for (var day = 1; day <= 5; day++) {
      now = DateTime.utc(2026, 11, day, 9);
      await metrics.measureSync(() async {});
    }
    now = DateTime.utc(2026, 11, 6, 9);
    final bodies = <Map<String, Object?>>[];
    await upload(
      metrics,
      MockClient((request) async {
        bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        return http.Response('{}', 202);
      }),
      version: '1.0 (build; DROP TABLE)',
    );
    expect(bodies.map((b) => b['day']), ['2026-11-01', '2026-11-02', '2026-11-03']);
    expect(bodies.every((b) => b['appVersion'] == 'unknown'), isTrue);
    expect(stored('2026-11-04'), isNotEmpty);
  });

  test('an account switch during upload stops without sending or clearing', () async {
    await metrics.measureSync(() async {});
    now = DateTime.utc(2026, 11, 5, 9);
    var current = true;
    var posted = 0;
    await upload(
      metrics,
      MockClient((request) async {
        posted++;
        return http.Response('{}', 202);
      }),
      current: () {
        final value = current;
        current = false;
        return value;
      },
    );
    expect(posted, 0);
    expect(stored('2026-11-04'), {'sync_attempts': 1});
  });

  test('failures inside the collector never reach the caller', () async {
    final throwingGate = make(gate: () async => throw StateError('no consent store'));
    await throwingGate.measureSync(() async {});
    await throwingGate.bundleDownloadFailed();
    expect(await throwingGate.measureMigration(() async => 5), 5);
    await upload(throwingGate, MockClient((_) async => http.Response('', 202)));

    final broken = sqlite3.openInMemory();
    final brokenMetrics = ClientMetrics(
      state: SyncStateStore(broken, namespace: 'a'),
      hasConsent: () async => true,
      clock: () => now,
    );
    await brokenMetrics.measureSync(() async {});
    await expectLater(
      brokenMetrics.measureSync(() async => throw const SocketException('x')),
      throwsA(isA<SocketException>()),
      reason: 'the original failure is the only thing the caller sees',
    );
    await upload(brokenMetrics, MockClient((_) async => http.Response('', 202)));
    broken.dispose();
  });

  test('only the known counter names are ever stored', () {
    expect(ClientMetrics.counterNames, {
      'sync_attempts',
      'sync_errors_network',
      'sync_errors_timeout',
      'sync_errors_server',
      'sync_errors_storage',
      'sync_errors_data',
      'sync_errors_other',
      'migration_started',
      'migration_completed',
      'migration_failed',
      'bundle_download_failures',
    });
  });
}
