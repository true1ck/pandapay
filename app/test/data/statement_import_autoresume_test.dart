import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/statement_import_continuation.dart';
import 'package:pandapay/features/import/statement_import_continuation_provider.dart'
    show isImportTransportFailure;
import 'package:sqlite3/sqlite3.dart';

import '../support/memory_import_continuation.dart';

const _s1 = 'a1000000-0000-4000-8000-000000000001';
const _s2 = 'a1000000-0000-4000-8000-000000000002';

Map<String, dynamic> _payload(String keyChar) => {
  'userCardId': null,
  'instrument': 'other',
  'statementFrom': '2026-10-01',
  'statementTo': '2026-10-01',
  'txnCount': 1,
  'reconciledCount': 0,
  'importSource': 'statement',
  'importKey': keyChar * 64,
  'transactions': [
    {
      'occurredAt': '2026-10-01T12:00:00.000Z',
      'amountInr': 12.5,
      'merchantName': 'Synthetic Cafe',
    },
  ],
};

StatementImport _ok({int added = 1, int retries = 0}) => StatementImport(
  id: 'server',
  userCardId: null,
  addedCount: added,
  exactRetryCount: retries,
  statementFrom: DateTime(2026, 10, 1),
  statementTo: DateTime(2026, 10, 1),
  txnCount: 1,
  reconciledCount: 0,
  importedAt: DateTime(2026, 10, 1),
);

void main() {
  late Database db;
  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.dispose());

  // `db` outlives the continuation, like the phone's file outlives the app.
  StatementImportContinuation open(
    Future<StatementImport> Function(Map<String, dynamic>) send,
  ) => StatementImportContinuation(
    outbox: memoryContinuation(
      ImportRepository(apiBaseUrl: 'http://test', accessToken: 't'),
      db: db,
    ).outbox,
    checkAccountUnchanged: () {},
    sendPrepared: send,
  );

  test('offline submit keeps the batch; reconnect uploads it', () async {
    final offline = open((_) async => throw const SocketException('down'));
    await expectLater(
      offline.prepareAndRun(sessionId: _s1, payloads: [_payload('a')]),
      throwsA(isA<SocketException>()),
    );
    expect(offline.outbox.pendingCount, 1);

    var sends = 0;
    final online = open((_) async {
      sends++;
      return _ok();
    });
    expect(await online.autoResume(), 1);
    expect(sends, 1);
    expect(online.outbox.pendingCount, 0);
  });

  test('app killed after saving, before any upload: restart resumes', () async {
    await open((_) async => throw StateError('unused')).outbox.prepare(
      sessionId: _s1,
      payloads: [_payload('a'), _payload('b')],
    );
    final sent = <String>[];
    final restarted = open((p) async {
      sent.add(p['importKey'] as String);
      return _ok();
    });
    expect(await restarted.autoResume(), 2);
    expect(sent, ['a' * 64, 'b' * 64]);
  });

  test('server replay of an already-imported batch (exact retry) completes it',
      () async {
    await open((_) async => throw StateError('unused')).outbox.prepare(
      sessionId: _s1,
      payloads: [_payload('a')],
    );
    final c = open((_) async => _ok(added: 0, retries: 1));
    expect(await c.autoResume(), 1);
    expect(c.outbox.pendingCount, 0);
  });

  test('409 key_reused parks that session with a reason and moves on', () async {
    final seed = open((_) async => throw StateError('unused'));
    await seed.outbox.prepare(sessionId: _s1, payloads: [_payload('a')]);
    await seed.outbox.prepare(sessionId: _s2, payloads: [_payload('b')]);
    final sent = <String>[];
    final c = open((p) async {
      sent.add(p['importKey'] as String);
      if ((p['importKey'] as String).startsWith('a')) {
        throw ApiException(
          'POST /statement-imports failed: 409 {"error":"statement_import_key_reused"}',
        );
      }
      return _ok();
    });
    expect(await c.autoResume(), 1);
    expect(c.parkedReasons.keys, [_s1]);
    expect(c.outbox.pendingCount, 1); // parked rows are kept, not discarded
    sent.clear();
    expect(await c.autoResume(), 0);
    expect(sent, isEmpty); // never retried automatically
  });

  test('transport failures are "saved", server answers are not', () {
    expect(isImportTransportFailure(const SocketException('x')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x timed out')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x failed: 503 {}')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x failed: 500 {}')), isFalse);
    expect(isImportTransportFailure(ApiException('POST /x failed: 502 {}')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x failed: 429 {}')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x failed: 408 {}')), isTrue);
    expect(isImportTransportFailure(ApiException('POST /x failed: 400 {}')), isFalse);
  });
}
