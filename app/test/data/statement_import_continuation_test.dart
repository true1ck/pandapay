import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/data/statement_import_continuation.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _sessionId = 'a1000000-0000-4000-8000-000000000001';
const _namespace = 'user:a2000000-0000-4000-8000-000000000002';
const _importKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, dynamic> _payload() => {
  'userCardId': null,
  'instrument': 'other',
  'statementFrom': '2026-10-01',
  'statementTo': '2026-10-01',
  'txnCount': 1,
  'reconciledCount': 0,
  'importSource': 'statement',
  'importKey': _importKey,
  'transactions': [
    {
      'occurredAt': '2026-10-01T12:00:00.000Z',
      'amountInr': 12.5,
      'merchantName': 'Cafe',
    },
  ],
};

StatementImport _result({
  int imported = 1,
  int duplicates = 0,
  int retries = 0,
}) => StatementImport(
  id: 'receipt-id',
  userCardId: null,
  statementFrom: DateTime(2026, 10),
  statementTo: DateTime(2026, 10),
  txnCount: 1,
  reconciledCount: 0,
  importedAt: DateTime(2026, 10),
  addedCount: imported,
  pendingDuplicateCount: duplicates,
  exactRetryCount: retries,
);

class _IdentityCipher implements StatementImportBatchCipher {
  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) async => Uint8List.fromList(ciphertext);
}

void main() {
  late Database database;
  late StatementImportOutbox outbox;

  setUp(() {
    database = sqlite3.openInMemory();
    outbox = StatementImportOutbox(
      database,
      namespace: _namespace,
      cipher: _IdentityCipher(),
    );
  });

  tearDown(() => database.dispose());

  test(
    'review pipeline persists every batch before POST and restart resumes only the unconfirmed body',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final receipts = <String, Map<String, dynamic>>{};
      final repository = ImportRepository(
        apiBaseUrl: 'https://api.invalid',
        accessToken: 'synthetic',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          if (bodies.length == 1) {
            expect(
              outbox.pendingCount,
              greaterThan(1),
              reason: 'The whole plan must be durable before sending',
            );
          }
          final rows = body['transactions'] as List;
          expect(rows.length, lessThanOrEqualTo(250));
          expect(utf8.encode(request.body).length, lessThanOrEqualTo(65536));
          final response = receipts.putIfAbsent(
            body['importKey'] as String,
            () => {
              'receiptVersion': 1,
              'statementImport': {
                'id': 'synthetic-${receipts.length}',
                'user_card_id': body['userCardId'],
                'statement_from': body['statementFrom'],
                'statement_to': body['statementTo'],
                'txn_count': rows.length,
                'reconciled_count': rows.length,
                'imported_at': '2026-10-26T00:00:00Z',
              },
              'summary': {
                'imported': rows.length,
                'pendingDuplicates': 0,
                'exactRetries': 0,
              },
            },
          );
          if (bodies.length == 2) {
            throw http.ClientException('synthetic response lost after commit');
          }
          return http.Response(jsonEncode(response), 200);
        }),
      );
      final session = TransactionImportSession(
        fileDigest: 'synthetic-file',
        importSource: 'csv',
        statement: ParsedStatement(
          transactions: List.generate(
            251,
            (i) => ParsedStatementLine(
              date: DateTime.utc(2026, 10, 1).add(Duration(minutes: i)),
              description: 'Synthetic row $i',
              amount: Money.fromRupees(1),
              sourceRowId: 'row:$i',
              sourceAccount: 'Bank 1234',
            ),
          ),
        ),
      );
      session.destinations['Bank 1234'] = '';
      StatementImportContinuation runner(StatementImportOutbox queue) =>
          StatementImportContinuation(
            outbox: queue,
            checkAccountUnchanged: () {},
            sendPrepared: repository.confirmPreparedStatementImport,
          );
      await expectLater(
        session.submit(repository, continuation: runner(outbox)),
        throwsA(isA<http.ClientException>()),
      );
      expect(session.reviewLocked, isTrue);
      expect(outbox.listSessions().single.completedBatches, 1);
      final restored = StatementImportOutbox(
        database,
        namespace: _namespace,
        cipher: _IdentityCipher(),
      );
      final progress = await runner(restored).resume();
      expect(bodies[2], bodies[1]);
      expect(
        bodies.where((body) => body['importKey'] == bodies.first['importKey']),
        hasLength(1),
      );
      expect(progress.added, 251);
      expect(progress.completedBatches, progress.totalBatches);
      expect(restored.pendingCount, 0);
    },
  );

  test(
    'a lost response reopens and replays the exact payload and importKey',
    () async {
      final planned = _payload();
      final sent = <Map<String, dynamic>>[];
      final first = StatementImportContinuation(
        outbox: outbox,
        checkAccountUnchanged: () {},
        sendPrepared: (payload) async {
          sent.add(payload);
          // Simulates a committed server request whose response was lost.
          throw StateError('transport dropped after commit');
        },
      );

      await expectLater(
        first.prepareAndRun(sessionId: _sessionId, payloads: [planned]),
        throwsStateError,
      );
      expect(outbox.pendingCount, 1);

      final reopened = StatementImportContinuation(
        outbox: StatementImportOutbox(
          database,
          namespace: _namespace,
          cipher: _IdentityCipher(),
        ),
        checkAccountUnchanged: () {},
        sendPrepared: (payload) async {
          sent.add(payload);
          return _result(imported: 0, retries: 1);
        },
      );
      final progress = await reopened.resume();

      expect(sent, hasLength(2));
      expect(sent[1], equals(sent[0]));
      expect(sent[1]['importKey'], _importKey);
      expect(progress.alreadyImported, 1);
      expect(outbox.pendingCount, 0);
    },
  );

  test(
    'account change after response leaves the accepted body pending',
    () async {
      var changed = false;
      final sent = <Map<String, dynamic>>[];
      final continuation = StatementImportContinuation(
        outbox: outbox,
        checkAccountUnchanged: () {
          if (changed) throw StateError('account changed');
        },
        sendPrepared: (payload) async {
          sent.add(payload);
          if (sent.length == 1) changed = true;
          return _result();
        },
      );

      await expectLater(
        continuation.prepareAndRun(
          sessionId: _sessionId,
          payloads: [_payload()],
        ),
        throwsStateError,
      );
      expect(outbox.pendingCount, 1);
      expect(sent.single['importKey'], _importKey);

      changed = false;
      final resumed = await continuation.resume();
      expect(resumed.added, 1);
      expect(sent, hasLength(2));
      expect(sent.last, equals(sent.first));
    },
  );

  test(
    'same session plan is idempotent and a changed body conflicts',
    () async {
      await outbox.prepare(sessionId: _sessionId, payloads: [_payload()]);
      await outbox.prepare(sessionId: _sessionId, payloads: [_payload()]);
      expect(outbox.pendingCount, 1);

      final changed = _payload()..['transactions'] = const [];
      await expectLater(
        outbox.prepare(sessionId: _sessionId, payloads: [changed]),
        throwsA(isA<StatementImportOutboxException>()),
      );
      expect(outbox.pendingCount, 1);
    },
  );

  test('one continuation instance does not start overlapping sends', () async {
    final started = Completer<void>();
    final settle = Completer<StatementImport>();
    final continuation = StatementImportContinuation(
      outbox: outbox,
      checkAccountUnchanged: () {},
      sendPrepared: (_) {
        started.complete();
        return settle.future;
      },
    );
    final running = continuation.prepareAndRun(
      sessionId: _sessionId,
      payloads: [_payload()],
    );
    await started.future;

    await expectLater(continuation.resume(), throwsStateError);
    settle.complete(_result());
    await running;
    expect(outbox.pendingCount, 0);
  });

  test('resumed session lists only metadata, not its payload', () async {
    await outbox.prepare(sessionId: _sessionId, payloads: [_payload()]);
    final json = jsonEncode(outbox.listSessions().single.sessionId);
    expect(jsonDecode(json), _sessionId);
    expect(json, isNot(contains('Cafe')));
  });
}
