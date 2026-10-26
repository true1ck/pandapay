import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
import 'package:pandapay/data/local/statement_import_pending.dart';

class _TestCipher implements StatementImportBatchCipher {
  bool failDecrypt = false;
  int overhead = 12;

  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) async {
    final output = Uint8List(plaintext.length + overhead);
    for (var i = 0; i < plaintext.length; i++) {
      output[i] = plaintext[i] ^ 0x5a;
    }
    for (var i = plaintext.length; i < output.length; i++) {
      output[i] = 0x23;
    }
    return output;
  }

  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) async {
    if (failDecrypt) throw const StatementImportOutboxException('key_missing');
    final output = Uint8List(ciphertext.length - overhead);
    for (var i = 0; i < output.length; i++) {
      output[i] = ciphertext[i] ^ 0x5a;
    }
    return output;
  }
}

const _user1 = 'user:11111111-1111-4111-8111-111111111111';
const _user2 = 'user:22222222-2222-4222-8222-222222222222';
const _session1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _session2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _session3 = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
String _key(String seed) => sha256.convert(utf8.encode(seed)).toString();
String _repeat(int length) => List<String>.filled(length, 'x').join();
Map<String, dynamic> _payload(String seed, {String? text}) => {
  'userCardId': null,
  'statementFrom': '2026-10-01',
  'statementTo': '2026-10-31',
  'importSource': 'csv',
  'importKey': _key(seed),
  'transactions': [
    {
      'amountInr': 12.34,
      'occurredAt': '2026-10-05T00:00:00.000Z',
      'merchantName': text ?? 'Shop $seed',
      'importRowKey': _key('row-$seed'),
    },
  ],
};

void main() {
  late Database db;
  late _TestCipher cipher;
  var clock = DateTime.utc(2026, 10, 26, 12);
  var sequence = 0;
  String id() =>
      'dddddddd-dddd-4ddd-8ddd-${(++sequence).toString().padLeft(12, '0')}';
  StatementImportOutbox make(
    String namespace, {
    Database? database,
    _TestCipher? batchCipher,
  }) => StatementImportOutbox(
    database ?? db,
    namespace: namespace,
    cipher: batchCipher ?? cipher,
    now: () => clock,
    idGenerator: id,
  );

  setUp(() {
    db = sqlite3.openInMemory();
    cipher = _TestCipher();
    clock = DateTime.utc(2026, 10, 26, 12);
    sequence = 0;
  });
  tearDown(() => db.dispose());

  test(
    'real cipher survives SQLite reopen and lost custody cannot replace a pending key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'statement-real-cipher-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/queue.sqlite';
      final store = _MemorySecureStore();
      StatementImportOutbox open(Database database) => StatementImportOutbox(
        database,
        namespace: _user1,
        now: () => clock,
        cipher: SecureStatementImportBatchCipher(
          secureStore: store,
          installId: 'synthetic-install',
          encryptedBatchesExist: (namespace) async =>
              pendingStatementImportBatches(database, namespace) > 0,
          lease: _InlineLease(),
        ),
      );
      final firstDb = sqlite3.open(path);
      final original = _payload('real', text: 'Private synthetic merchant');
      await open(firstDb).prepare(sessionId: _session1, payloads: [original]);
      final stored = List<int>.from(
        firstDb
                .select('SELECT ciphertext FROM statement_import_batches')
                .single['ciphertext']
            as List<int>,
      );
      expect(stored.take(4), [0x50, 0x50, 0x49, 0x4d]);
      expect(
        latin1.decode(stored),
        isNot(contains('Private synthetic merchant')),
      );
      final savedCustody = Map<String, String>.from(store.values);
      firstDb.dispose();
      final reopenedDb = sqlite3.open(path);
      addTearDown(reopenedDb.dispose);
      final reopened = open(reopenedDb);
      final lease = (await reopened.readNext())!;
      expect(lease.payload, original);
      reopened.releaseLease(
        sessionId: lease.sessionId,
        leaseToken: lease.leaseToken,
      );
      store.values.clear();
      await expectLater(
        reopened.readNext(),
        throwsA(isA<StatementImportCipherException>()),
      );
      await expectLater(
        reopened.prepare(sessionId: _session2, payloads: [_payload('new')]),
        throwsA(isA<StatementImportCipherException>()),
      );
      expect(store.values, isEmpty);
      expect(
        reopenedDb
            .select('SELECT ciphertext FROM statement_import_batches')
            .single['ciphertext'],
        stored,
      );
      store.values.addAll(savedCustody);
      expect((await reopened.readNext())!.payload, original);
    },
  );

  test(
    'canonical object ordering is stable and scoped resume cannot send a different plan',
    () async {
      final outbox = make(_user1);
      final payload = _payload('one');
      await outbox.prepare(sessionId: _session1, payloads: [payload]);
      await outbox.prepare(
        sessionId: _session1,
        payloads: [
          {for (final key in payload.keys.toList().reversed) key: payload[key]},
        ],
      );
      await outbox.prepare(sessionId: _session2, payloads: [_payload('two')]);
      final scoped = (await outbox.readNext(sessionId: _session2))!;
      expect(scoped.sessionId, _session2);
      expect(scoped.payload['importKey'], _key('two'));
      expect(await outbox.readNext(sessionId: _session1), isNull);
      outbox.releaseLease(
        sessionId: scoped.sessionId,
        leaseToken: scoped.leaseToken,
      );
      expect(
        (await outbox.readNext(sessionId: _session1))!.sessionId,
        _session1,
      );
    },
  );

  test(
    'prepares an immutable encrypted plan and lists metadata without payload',
    () async {
      final outbox = make(_user1);
      final planned = [_payload('one'), _payload('two')];
      await outbox.prepare(sessionId: _session1, payloads: planned);
      await outbox.prepare(sessionId: _session1, payloads: planned);
      expect(outbox.listSessions(), hasLength(1));
      expect(outbox.listSessions().single.batchCount, 2);
      expect(outbox.activePayloadsExist, isTrue);
      final stored = db.select(
        'SELECT ciphertext FROM statement_import_batches',
      );
      expect(stored, hasLength(2));
      expect(
        stored.first['ciphertext'],
        isNot(equals(utf8.encode(jsonEncode(planned.first)))),
      );
      expect(
        (await outbox.readNext())?.payload['importKey'],
        planned.first['importKey'],
      );
    },
  );

  test(
    'namespace is immutable and pending rows remain isolated between accounts',
    () async {
      final owner = make(_user1);
      await owner.prepare(sessionId: _session1, payloads: [_payload('one')]);
      final other = make(_user2);
      expect(other.listSessions(), isEmpty);
      expect(other.activePayloadsExist, isFalse);
      expect(await other.readNext(), isNull);
      expect(
        () => StatementImportOutbox(db, namespace: 'legacy', cipher: cipher),
        throwsArgumentError,
      );
    },
  );

  test(
    'same session key with changed payload and globally reused batch key conflict',
    () async {
      final outbox = make(_user1);
      final first = _payload('same');
      await outbox.prepare(sessionId: _session1, payloads: [first]);
      await expectLater(
        outbox.prepare(
          sessionId: _session1,
          payloads: [_payload('same', text: 'edited')],
        ),
        throwsA(
          isA<StatementImportOutboxException>().having(
            (e) => e.code,
            'code',
            'session_plan_conflict',
          ),
        ),
      );
      await expectLater(
        outbox.prepare(
          sessionId: _session2,
          payloads: [_payload('same', text: 'edited')],
        ),
        throwsA(
          isA<StatementImportOutboxException>().having(
            (e) => e.code,
            'code',
            'batch_key_conflict',
          ),
        ),
      );
      expect(outbox.listSessions(), hasLength(1));
    },
  );

  test('validates bounds and refuses capacity atomically', () async {
    final outbox = make(_user1);
    await expectLater(
      outbox.prepare(
        sessionId: _session1,
        payloads: [_payload('secret')..['password'] = 'bad'],
      ),
      throwsA(isA<StatementImportOutboxException>()),
    );
    await expectLater(
      outbox.prepare(
        sessionId: _session1,
        payloads: [_payload('huge')..['extra'] = _repeat(66000)],
      ),
      throwsA(isA<StatementImportOutboxException>()),
    );
    expect(outbox.listSessions(), isEmpty);

    final plans = <Map<String, dynamic>>[];
    for (var i = 0; i < 64; i++) {
      plans.add(_payload('cap-$i', text: _repeat(60000)));
    }
    await outbox.prepare(sessionId: _session1, payloads: plans);
    await outbox.prepare(
      sessionId: _session2,
      payloads: [
        for (var i = 64; i < 128; i++) _payload('cap-$i', text: _repeat(60000)),
      ],
    );
    final third = make(_user2);
    await expectLater(
      third.prepare(
        sessionId: _session3,
        payloads: [
          for (var i = 128; i < 140; i++)
            _payload('cap-$i', text: _repeat(60000)),
        ],
      ),
      throwsA(
        isA<StatementImportOutboxException>().having(
          (e) => e.code,
          'code',
          'outbox_capacity_full',
        ),
      ),
    );
    expect(third.listSessions(), isEmpty);
    expect(outbox.listSessions(), hasLength(2));
  });

  test(
    'lease fences concurrent handles, only 200/201 acknowledges, and ack deletes ciphertext',
    () async {
      final first = make(_user1);
      final second = make(_user1);
      await first.prepare(
        sessionId: _session1,
        payloads: [_payload('one'), _payload('two')],
      );
      final lease = (await first.readNext())!;
      expect(await second.readNext(), isNull);
      expect(
        () => first.cancel(_session1),
        throwsA(
          isA<StatementImportOutboxException>().having(
            (e) => e.code,
            'code',
            'session_request_in_flight',
          ),
        ),
      );
      expect(
        () => first.acknowledge(
          sessionId: _session1,
          leaseToken: lease.leaseToken,
          httpStatus: 500,
          summary: {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': 0},
        ),
        throwsA(isA<StatementImportOutboxException>()),
      );
      expect(
        () => second.acknowledge(
          sessionId: _session1,
          leaseToken: id(),
          httpStatus: 201,
          summary: {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': 0},
        ),
        throwsA(isA<StatementImportOutboxException>()),
      );
      first.acknowledge(
        sessionId: _session1,
        leaseToken: lease.leaseToken,
        httpStatus: 201,
        summary: {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': 0},
      );
      expect(
        db
            .select(
              'SELECT ciphertext FROM statement_import_batches WHERE ordinal=0',
            )
            .single['ciphertext'],
        isNull,
      );
      expect(first.listSessions().single.completedBatches, 1);
      expect(first.completedTotals(sessionId: _session1), {
        'imported': 1,
        'pendingDuplicates': 0,
        'exactRetries': 0,
      });
      final next = (await second.readNext())!;
      second.acknowledge(
        sessionId: _session1,
        leaseToken: next.leaseToken,
        httpStatus: 200,
        summary: {'imported': 0, 'pendingDuplicates': 0, 'exactRetries': 1},
      );
      expect(first.listSessions(), isEmpty);
      expect(
        first.listSessions(includeTerminal: true).single.isComplete,
        isTrue,
      );
      expect(first.activePayloadsExist, isFalse);
    },
  );

  test(
    'expired lease is fenced and only an expired session moves to review without deletion',
    () async {
      final outbox = make(_user1);
      await outbox.prepare(sessionId: _session1, payloads: [_payload('one')]);
      final original = (await outbox.readNext(
        leaseDuration: const Duration(seconds: 10),
      ))!;
      clock = clock.add(const Duration(seconds: 11));
      final reclaimed = (await outbox.readNext())!;
      expect(reclaimed.leaseToken, isNot(original.leaseToken));
      expect(
        () => outbox.acknowledge(
          sessionId: _session1,
          leaseToken: original.leaseToken,
          httpStatus: 200,
          summary: {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': 0},
        ),
        throwsA(isA<StatementImportOutboxException>()),
      );
      clock = DateTime.fromMillisecondsSinceEpoch(
        outbox.listSessions().single.expiresAtMs + 1,
      );
      outbox.markExpiredForReview();
      expect(outbox.listSessions().single.needsReview, isTrue);
      expect(outbox.activePayloadsExist, isTrue);
      expect(await outbox.readNext(), isNull);
      outbox.cancel(_session1);
      expect(outbox.activePayloadsExist, isFalse);
      expect(
        outbox.listSessions(includeTerminal: true).single.state,
        'cancelled',
      );
    },
  );

  test(
    'missing encryption key preserves ciphertext and restart can recover with same account key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'statement-outbox-test-',
      );
      final path = '${directory.path}/outbox.sqlite';
      final persistent = sqlite3.open(path);
      final writing = make(_user1, database: persistent);
      await writing.prepare(
        sessionId: _session1,
        payloads: [_payload('persist')],
      );
      persistent.dispose();
      final reopenedDb = sqlite3.open(path);
      final failingCipher = _TestCipher()..failDecrypt = true;
      final reopened = make(
        _user1,
        database: reopenedDb,
        batchCipher: failingCipher,
      );
      await expectLater(
        reopened.readNext(),
        throwsA(isA<StatementImportOutboxException>()),
      );
      expect(reopened.activePayloadsExist, isTrue);
      reopenedDb.dispose();
      await directory.delete(recursive: true);
    },
  );
}

class _MemorySecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}
