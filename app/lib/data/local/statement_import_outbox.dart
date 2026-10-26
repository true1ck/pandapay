import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../secure_storage/statement_import_batch_cipher.dart';

const _uuidPattern =
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
const _sha256Pattern = r'^[0-9a-f]{64}$';

/// Bounds for the durable statement continuation. Ciphertext is the only
/// batch content persisted in SQLite; no PDF, password, or access token is
/// accepted in a planned payload.
abstract final class StatementImportOutboxLimits {
  static const maxBatchesPerSession = 64;
  static const maxPlaintextBytesPerBatch = 64 * 1024;
  static const maxCiphertextBytesPerBatch = 65569;
  static const maxCiphertextBytesGlobal = 8 * 1024 * 1024;
  static const maxActiveSessionsPerAccount = 3;
  static const maxRetainedSessionsPerAccount = 35;
  static const maxRetainedSessionsGlobal = 1000;
  static const sessionTtl = Duration(days: 14);
  static const leaseDuration = Duration(minutes: 5);
}

class StatementImportOutboxException implements Exception {
  final String code;
  const StatementImportOutboxException(this.code);

  @override
  String toString() => 'StatementImportOutboxException($code)';
}

class StatementImportSessionSummary {
  final String sessionId;
  final String state;
  final int batchCount;
  final int completedBatches;
  final int createdAtMs;
  final int expiresAtMs;
  final int imported;
  final int pendingDuplicates;
  final int exactRetries;

  const StatementImportSessionSummary({
    required this.sessionId,
    required this.state,
    required this.batchCount,
    required this.completedBatches,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.imported,
    required this.pendingDuplicates,
    required this.exactRetries,
  });

  bool get needsReview => state == 'needs_review';
  bool get isComplete => state == 'complete';
}

class StatementImportLease {
  final String sessionId;
  final int ordinal;
  final String importKey;
  final String leaseToken;
  final int leaseUntilMs;
  final Map<String, dynamic> payload;

  const StatementImportLease({
    required this.sessionId,
    required this.ordinal,
    required this.importKey,
    required this.leaseToken,
    required this.leaseUntilMs,
    required this.payload,
  });
}

/// Account-scoped durable continuation for the existing sequential statement
/// import POSTs. The injected cipher owns key custody; this class never stores
/// cleartext batch JSON in SQLite.
class StatementImportOutbox {
  final Database database;
  final String namespace;
  final StatementImportBatchCipher cipher;
  final DateTime Function() now;
  final String Function() idGenerator;

  StatementImportOutbox(
    this.database, {
    required this.namespace,
    required this.cipher,
    DateTime Function()? now,
    String Function()? idGenerator,
  }) : now = now ?? DateTime.now,
       idGenerator = idGenerator ?? _uuidV4 {
    if (!RegExp(
      r'^user:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(namespace)) {
      throw ArgumentError.value(
        namespace,
        'namespace',
        'must be user:<profile UUID>',
      );
    }
    _createSchema();
  }

  void _createSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS statement_import_sessions (
        namespace TEXT NOT NULL,
        session_id TEXT NOT NULL,
        plan_hash TEXT NOT NULL CHECK(length(plan_hash)=64),
        batch_count INTEGER NOT NULL CHECK(batch_count BETWEEN 1 AND 64),
        state TEXT NOT NULL CHECK(state IN ('pending','needs_review','complete','cancelled')),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        expires_at_ms INTEGER NOT NULL,
        PRIMARY KEY(namespace, session_id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS statement_import_batches (
        namespace TEXT NOT NULL,
        session_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 63),
        import_key TEXT NOT NULL CHECK(length(import_key)=64),
        payload_hash TEXT NOT NULL CHECK(length(payload_hash)=64),
        payload_bytes INTEGER NOT NULL CHECK(payload_bytes BETWEEN 1 AND 65536),
        ciphertext BLOB,
        completed_summary TEXT,
        completed_at_ms INTEGER,
        PRIMARY KEY(namespace, session_id, ordinal),
        UNIQUE(namespace, import_key),
        FOREIGN KEY(namespace, session_id)
          REFERENCES statement_import_sessions(namespace, session_id) ON DELETE CASCADE,
        CHECK((ciphertext IS NOT NULL AND completed_summary IS NULL AND completed_at_ms IS NULL)
           OR (ciphertext IS NULL AND completed_summary IS NOT NULL AND completed_at_ms IS NOT NULL))
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS statement_import_leases (
        namespace TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        lease_token TEXT NOT NULL,
        lease_until_ms INTEGER NOT NULL,
        FOREIGN KEY(namespace, session_id, ordinal)
          REFERENCES statement_import_batches(namespace, session_id, ordinal) ON DELETE CASCADE
      )
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS statement_import_sessions_state_idx
      ON statement_import_sessions(namespace, state, created_at_ms)
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS statement_import_batches_pending_idx
      ON statement_import_batches(namespace, session_id, ordinal) WHERE ciphertext IS NOT NULL
    ''');
  }

  /// Encrypts each bounded canonical POST body, then inserts the immutable
  /// session plan atomically. Repeating the same session plan is idempotent.
  Future<void> prepare({
    required String sessionId,
    required List<Map<String, dynamic>> payloads,
  }) async {
    if (!_isUuid(sessionId) ||
        payloads.isEmpty ||
        payloads.length > StatementImportOutboxLimits.maxBatchesPerSession) {
      throw const StatementImportOutboxException('invalid_plan');
    }
    final prepared = <_PreparedBatch>[];
    final plannedKeys = <String>{};
    for (var ordinal = 0; ordinal < payloads.length; ordinal++) {
      final payload = payloads[ordinal];
      _rejectSecrets(payload);
      final importKey = payload['importKey'];
      if (importKey is! String || !_isSha256(importKey)) {
        throw const StatementImportOutboxException('invalid_import_key');
      }
      if (!plannedKeys.add(importKey)) {
        throw const StatementImportOutboxException('duplicate_import_key');
      }
      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(_canonicalValue(payload))),
      );
      if (plaintext.isEmpty ||
          plaintext.length >
              StatementImportOutboxLimits.maxPlaintextBytesPerBatch) {
        throw const StatementImportOutboxException('batch_too_large');
      }
      final digest = sha256.convert(plaintext).toString();
      final encrypted = await cipher.encrypt(
        namespace: namespace,
        sessionId: sessionId,
        ordinal: ordinal,
        importKey: importKey,
        plaintext: plaintext,
      );
      if (encrypted.isEmpty ||
          encrypted.length >
              StatementImportOutboxLimits.maxCiphertextBytesPerBatch) {
        throw const StatementImportOutboxException('ciphertext_too_large');
      }
      prepared.add(
        _PreparedBatch(
          ordinal: ordinal,
          importKey: importKey,
          digest: digest,
          plaintextBytes: plaintext.length,
          ciphertext: encrypted,
        ),
      );
    }
    final planHash = sha256
        .convert(
          utf8.encode(
            prepared
                .map(
                  (batch) =>
                      '${batch.ordinal}:${batch.importKey}:${batch.digest}:${batch.plaintextBytes}',
                )
                .join('\n'),
          ),
        )
        .toString();
    _beginImmediate();
    try {
      final prior = database.select(
        'SELECT plan_hash FROM statement_import_sessions WHERE namespace=? AND session_id=?',
        [namespace, sessionId],
      );
      if (prior.isNotEmpty) {
        if (prior.single['plan_hash'] != planHash) {
          throw const StatementImportOutboxException('session_plan_conflict');
        }
        database.execute('COMMIT');
        return;
      }
      final expiredTerminal = database.select(
        "SELECT namespace,session_id FROM statement_import_sessions WHERE state IN ('complete','cancelled') AND updated_at_ms<? LIMIT 100",
        [now().subtract(const Duration(days: 30)).millisecondsSinceEpoch],
      );
      for (final row in expiredTerminal) {
        final owner = row['namespace'] as String;
        final id = row['session_id'] as String;
        if (database.select(
          'SELECT 1 FROM statement_import_batches WHERE namespace=? AND session_id=? AND ciphertext IS NOT NULL LIMIT 1',
          [owner, id],
        ).isNotEmpty) {
          continue;
        }
        if (database.select(
          'SELECT 1 FROM statement_import_leases WHERE namespace=? AND session_id=? LIMIT 1',
          [owner, id],
        ).isNotEmpty) {
          continue;
        }
        database.execute(
          'DELETE FROM statement_import_batches WHERE namespace=? AND session_id=?',
          [owner, id],
        );
        database.execute(
          'DELETE FROM statement_import_sessions WHERE namespace=? AND session_id=?',
          [owner, id],
        );
      }
      final retained = _intQuery(
        'SELECT COUNT(*) AS n FROM statement_import_sessions WHERE namespace=?',
      );
      if (retained >=
          StatementImportOutboxLimits.maxRetainedSessionsPerAccount) {
        throw const StatementImportOutboxException('session_history_full');
      }
      final retainedGlobal =
          database
                  .select('SELECT COUNT(*) AS n FROM statement_import_sessions')
                  .single['n']
              as int;
      if (retainedGlobal >=
          StatementImportOutboxLimits.maxRetainedSessionsGlobal) {
        throw const StatementImportOutboxException(
          'global_session_history_full',
        );
      }
      final active = _intQuery(
        "SELECT COUNT(*) AS n FROM statement_import_sessions WHERE namespace=? AND state IN ('pending','needs_review')",
      );
      if (active >= StatementImportOutboxLimits.maxActiveSessionsPerAccount) {
        throw const StatementImportOutboxException('too_many_pending_sessions');
      }
      final pendingBytes = _intQuery(
        'SELECT COALESCE(SUM(length(ciphertext)),0) AS n FROM statement_import_batches WHERE ciphertext IS NOT NULL',
        const [],
      );
      final addBytes = prepared.fold<int>(
        0,
        (sum, batch) => sum + batch.ciphertext.length,
      );
      if (pendingBytes + addBytes >
          StatementImportOutboxLimits.maxCiphertextBytesGlobal) {
        throw const StatementImportOutboxException('outbox_capacity_full');
      }
      for (final batch in prepared) {
        final priorKey = database.select(
          'SELECT session_id,payload_hash FROM statement_import_batches WHERE namespace=? AND import_key=?',
          [namespace, batch.importKey],
        );
        if (priorKey.isNotEmpty) {
          throw StatementImportOutboxException(
            priorKey.single['payload_hash'] != batch.digest
                ? 'batch_key_conflict'
                : 'batch_key_already_planned',
          );
        }
      }
      final timestamp = now().millisecondsSinceEpoch;
      final expiry =
          timestamp + StatementImportOutboxLimits.sessionTtl.inMilliseconds;
      database.execute(
        '''INSERT INTO statement_import_sessions
           (namespace,session_id,plan_hash,batch_count,state,created_at_ms,updated_at_ms,expires_at_ms)
           VALUES (?,?,?,?,'pending',?,?,?)''',
        [
          namespace,
          sessionId,
          planHash,
          prepared.length,
          timestamp,
          timestamp,
          expiry,
        ],
      );
      for (final batch in prepared) {
        database.execute(
          '''INSERT INTO statement_import_batches
             (namespace,session_id,ordinal,import_key,payload_hash,payload_bytes,ciphertext)
             VALUES (?,?,?,?,?,?,?)''',
          [
            namespace,
            sessionId,
            batch.ordinal,
            batch.importKey,
            batch.digest,
            batch.plaintextBytes,
            batch.ciphertext,
          ],
        );
      }
      database.execute('COMMIT');
    } catch (_) {
      _rollbackQuietly();
      rethrow;
    }
  }

  /// Returns active-session metadata only; payloads never appear in listings.
  List<StatementImportSessionSummary> listSessions({
    bool includeTerminal = false,
  }) {
    final where = includeTerminal
        ? 's.namespace=?'
        : "s.namespace=? AND s.state IN ('pending','needs_review')";
    final rows = database.select(
      '''SELECT s.session_id,s.state,s.batch_count,s.created_at_ms,s.expires_at_ms,
                b.completed_summary
           FROM statement_import_sessions s
           LEFT JOIN statement_import_batches b ON b.namespace=s.namespace AND b.session_id=s.session_id
          WHERE $where ORDER BY s.created_at_ms,s.session_id,b.ordinal''',
      [namespace],
    );
    final grouped = <String, _SessionAccumulator>{};
    for (final row in rows) {
      final sessionId = row['session_id'] as String;
      final accumulator = grouped.putIfAbsent(
        sessionId,
        () => _SessionAccumulator(row),
      );
      accumulator.add(row['completed_summary'] as String?);
    }
    return grouped.values
        .map((value) => value.toSummary(now().millisecondsSinceEpoch))
        .toList(growable: false);
  }

  /// Read-only guard for missing-key and portable-capture flows. It exposes
  /// no batch identity or content.
  bool get activePayloadsExist => database
      .select(
        '''SELECT 1 FROM statement_import_batches b
       JOIN statement_import_sessions s ON s.namespace=b.namespace AND s.session_id=b.session_id
       WHERE b.namespace=? AND b.ciphertext IS NOT NULL AND s.state IN ('pending','needs_review') LIMIT 1''',
        [namespace],
      )
      .isNotEmpty;

  int get pendingCount =>
      database
              .select(
                '''SELECT COUNT(*) AS n FROM statement_import_batches b
       JOIN statement_import_sessions s ON s.namespace=b.namespace AND s.session_id=b.session_id
       WHERE b.namespace=? AND b.ciphertext IS NOT NULL AND s.state IN ('pending','needs_review')''',
                [namespace],
              )
              .single['n']
          as int;

  int pendingCountFor(String sessionId) => _intQuery(
    'SELECT COUNT(*) AS n FROM statement_import_batches WHERE namespace=? AND session_id=? AND ciphertext IS NOT NULL',
    [namespace, sessionId],
  );

  bool get hasLiveLease => database.select(
    'SELECT 1 FROM statement_import_leases WHERE namespace=? AND lease_until_ms>? LIMIT 1',
    [namespace, now().millisecondsSinceEpoch],
  ).isNotEmpty;

  Map<String, int> completedTotals({String? sessionId}) {
    final rows = database.select(
      '''SELECT completed_summary FROM statement_import_batches
          WHERE namespace=? AND ciphertext IS NULL AND completed_summary IS NOT NULL
            AND (? IS NULL OR session_id=?)''',
      [namespace, sessionId, sessionId],
    );
    var imported = 0;
    var pendingDuplicates = 0;
    var exactRetries = 0;
    for (final row in rows) {
      final summary =
          jsonDecode(row['completed_summary'] as String)
              as Map<String, dynamic>;
      imported += summary['imported'] as int;
      pendingDuplicates += summary['pendingDuplicates'] as int;
      exactRetries += summary['exactRetries'] as int;
    }
    return {
      'imported': imported,
      'pendingDuplicates': pendingDuplicates,
      'exactRetries': exactRetries,
    };
  }

  /// Claims the next unacknowledged body for this account and decrypts only
  /// that one batch. Expired sessions move to needs_review and retain ciphertext.
  Future<StatementImportLease?> readNext({
    String? sessionId,
    Duration leaseDuration = StatementImportOutboxLimits.leaseDuration,
  }) async {
    if (leaseDuration <= Duration.zero ||
        leaseDuration > const Duration(minutes: 15)) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    final current = now().millisecondsSinceEpoch;
    _beginImmediate();
    String? token;
    String? claimedSessionId;
    String? importKey;
    int? ordinal;
    int? leaseUntil;
    Uint8List? ciphertext;
    String? payloadHash;
    try {
      database.execute(
        "UPDATE statement_import_sessions SET state='needs_review',updated_at_ms=? "
        "WHERE namespace=? AND state='pending' AND expires_at_ms<=?",
        [current, namespace, current],
      );
      final held = database.select(
        'SELECT lease_until_ms FROM statement_import_leases WHERE namespace=?',
        [namespace],
      );
      if (held.isNotEmpty && (held.single['lease_until_ms'] as int) > current) {
        database.execute('COMMIT');
        return null;
      }
      if (held.isNotEmpty) {
        database.execute(
          'DELETE FROM statement_import_leases WHERE namespace=?',
          [namespace],
        );
      }
      final next = database.select(
        '''SELECT b.session_id,b.ordinal,b.import_key,b.ciphertext,b.payload_hash
             FROM statement_import_batches b
             JOIN statement_import_sessions s ON s.namespace=b.namespace AND s.session_id=b.session_id
            WHERE b.namespace=? AND s.state='pending' AND b.ciphertext IS NOT NULL AND (? IS NULL OR b.session_id=?)
            ORDER BY s.created_at_ms,b.ordinal LIMIT 1''',
        [namespace, sessionId, sessionId],
      );
      if (next.isEmpty) {
        database.execute('COMMIT');
        return null;
      }
      final row = next.single;
      claimedSessionId = row['session_id'] as String;
      ordinal = row['ordinal'] as int;
      importKey = row['import_key'] as String;
      ciphertext = Uint8List.fromList(row['ciphertext'] as List<int>);
      payloadHash = row['payload_hash'] as String;
      token = idGenerator();
      if (!_isUuid(token)) {
        throw const StatementImportOutboxException('invalid_lease_token');
      }
      leaseUntil = current + leaseDuration.inMilliseconds;
      database.execute(
        'INSERT INTO statement_import_leases(namespace,session_id,ordinal,lease_token,lease_until_ms) VALUES(?,?,?,?,?)',
        [namespace, claimedSessionId, ordinal, token, leaseUntil],
      );
      database.execute('COMMIT');
    } catch (_) {
      _rollbackQuietly();
      rethrow;
    }
    try {
      final plaintext = await cipher.decrypt(
        namespace: namespace,
        sessionId: claimedSessionId,
        ordinal: ordinal,
        importKey: importKey,
        ciphertext: ciphertext,
      );
      if (plaintext.length >
              StatementImportOutboxLimits.maxPlaintextBytesPerBatch ||
          sha256.convert(plaintext).toString() != payloadHash) {
        throw const StatementImportOutboxException('payload_integrity_error');
      }
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic> ||
          decoded['importKey'] != importKey) {
        throw const StatementImportOutboxException('payload_integrity_error');
      }
      return StatementImportLease(
        sessionId: claimedSessionId,
        ordinal: ordinal,
        importKey: importKey,
        leaseToken: token,
        leaseUntilMs: leaseUntil,
        payload: decoded,
      );
    } catch (_) {
      releaseLease(sessionId: claimedSessionId, leaseToken: token);
      rethrow;
    }
  }

  /// Records a successful server result only for the currently held token.
  /// Pass only after the HTTP future has actually settled with status 200/201.
  void acknowledge({
    required String sessionId,
    required String leaseToken,
    required int httpStatus,
    required Map<String, int> summary,
  }) {
    if (httpStatus != 200 && httpStatus != 201) {
      throw const StatementImportOutboxException('server_result_not_success');
    }
    _validateSummary(summary);
    final current = now().millisecondsSinceEpoch;
    _beginImmediate();
    try {
      final lease = database.select(
        'SELECT session_id,ordinal FROM statement_import_leases WHERE namespace=? AND lease_token=? AND lease_until_ms>?',
        [namespace, leaseToken, current],
      );
      if (lease.isEmpty || lease.single['session_id'] != sessionId) {
        throw const StatementImportOutboxException('lease_lost');
      }
      final ordinal = lease.single['ordinal'] as int;
      database.execute(
        '''UPDATE statement_import_batches SET ciphertext=NULL,completed_summary=?,completed_at_ms=?
           WHERE namespace=? AND session_id=? AND ordinal=? AND ciphertext IS NOT NULL''',
        [jsonEncode(summary), current, namespace, sessionId, ordinal],
      );
      if (database.updatedRows == 0) {
        throw const StatementImportOutboxException(
          'batch_already_acknowledged',
        );
      }
      database.execute(
        'DELETE FROM statement_import_leases WHERE namespace=? AND lease_token=?',
        [namespace, leaseToken],
      );
      final remaining = _intQuery(
        'SELECT COUNT(*) AS n FROM statement_import_batches WHERE namespace=? AND session_id=? AND ciphertext IS NOT NULL',
        [namespace, sessionId],
      );
      if (remaining == 0) {
        database.execute(
          "UPDATE statement_import_sessions SET state='complete',updated_at_ms=? WHERE namespace=? AND session_id=?",
          [current, namespace, sessionId],
        );
      } else {
        database.execute(
          'UPDATE statement_import_sessions SET updated_at_ms=? WHERE namespace=? AND session_id=?',
          [current, namespace, sessionId],
        );
      }
      database.execute('COMMIT');
    } catch (_) {
      _rollbackQuietly();
      rethrow;
    }
  }

  /// Releases only a matching lease. Call after an HTTP attempt has settled;
  /// an ambiguous/lost response should replay the exact same batch later.
  void releaseLease({required String sessionId, required String leaseToken}) {
    database.execute(
      'DELETE FROM statement_import_leases WHERE namespace=? AND session_id=? AND lease_token=?',
      [namespace, sessionId, leaseToken],
    );
  }

  /// Extends a live request's lease; stale tokens cannot renew a newer lease.
  bool renewLease({
    required String sessionId,
    required String leaseToken,
    Duration leaseDuration = StatementImportOutboxLimits.leaseDuration,
  }) {
    if (leaseDuration <= Duration.zero ||
        leaseDuration > const Duration(minutes: 15)) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    final current = now().millisecondsSinceEpoch;
    database.execute(
      'UPDATE statement_import_leases SET lease_until_ms=? WHERE namespace=? AND session_id=? AND lease_token=? AND lease_until_ms>?',
      [
        current + leaseDuration.inMilliseconds,
        namespace,
        sessionId,
        leaseToken,
        current,
      ],
    );
    return database.updatedRows > 0;
  }

  /// Expiration never silently erases financial input; it stops automatic
  /// replay and leaves encrypted payloads for explicit user review/cancel.
  void markExpiredForReview() {
    final current = now().millisecondsSinceEpoch;
    database.execute(
      "UPDATE statement_import_sessions SET state='needs_review',updated_at_ms=? "
      "WHERE namespace=? AND state='pending' AND expires_at_ms<=?",
      [current, namespace, current],
    );
  }

  /// Explicitly resumes an expired session after user review. The encrypted
  /// batch plan and all idempotency keys remain unchanged.
  void resumeReview(String sessionId) {
    final timestamp = now().millisecondsSinceEpoch;
    database.execute(
      "UPDATE statement_import_sessions SET state='pending',expires_at_ms=?,updated_at_ms=? "
      "WHERE namespace=? AND session_id=? AND state='needs_review'",
      [
        timestamp + StatementImportOutboxLimits.sessionTtl.inMilliseconds,
        timestamp,
        namespace,
        sessionId,
      ],
    );
    if (database.updatedRows == 0) {
      throw const StatementImportOutboxException('session_not_resumable');
    }
  }

  /// Explicit user cancellation removes pending ciphertext and leaves only a
  /// terminal session record. Completed batch summaries remain intact.
  void cancel(String sessionId) {
    _beginImmediate();
    try {
      final exists = database.select(
        "SELECT 1 FROM statement_import_sessions WHERE namespace=? AND session_id=? AND state IN ('pending','needs_review')",
        [namespace, sessionId],
      );
      if (exists.isEmpty) {
        throw const StatementImportOutboxException('session_not_cancellable');
      }
      final liveLease = database.select(
        'SELECT 1 FROM statement_import_leases WHERE namespace=? AND session_id=? AND lease_until_ms>? LIMIT 1',
        [namespace, sessionId, now().millisecondsSinceEpoch],
      );
      if (liveLease.isNotEmpty) {
        throw const StatementImportOutboxException('session_request_in_flight');
      }
      database.execute(
        'DELETE FROM statement_import_leases WHERE namespace=? AND session_id=?',
        [namespace, sessionId],
      );
      database.execute(
        'DELETE FROM statement_import_batches WHERE namespace=? AND session_id=? AND ciphertext IS NOT NULL',
        [namespace, sessionId],
      );
      database.execute(
        "UPDATE statement_import_sessions SET state='cancelled',updated_at_ms=? WHERE namespace=? AND session_id=?",
        [now().millisecondsSinceEpoch, namespace, sessionId],
      );
      database.execute('COMMIT');
    } catch (_) {
      _rollbackQuietly();
      rethrow;
    }
  }

  int _intQuery(String sql, [List<Object?>? values]) =>
      database.select(sql, values ?? [namespace]).single['n'] as int;

  void _beginImmediate() => database.execute('BEGIN IMMEDIATE');

  void _rollbackQuietly() {
    try {
      database.execute('ROLLBACK');
    } catch (_) {}
  }

  static void _validateSummary(Map<String, int> summary) {
    const keys = {'imported', 'pendingDuplicates', 'exactRetries'};
    if (summary.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(summary.keys.toSet()).isNotEmpty ||
        summary.values.any((value) => value < 0 || value > 5000) ||
        summary.values.fold<int>(0, (sum, value) => sum + value) > 5000) {
      throw const StatementImportOutboxException('invalid_summary');
    }
  }

  static Object? _canonicalValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalValue(value[key])};
    }
    if (value is List) return value.map(_canonicalValue).toList();
    return value;
  }

  static void _rejectSecrets(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String ||
            RegExp(
              r'(password|token|raw.?pdf|pdf.?bytes|file.?bytes|source.?file)',
              caseSensitive: false,
            ).hasMatch(key)) {
          throw const StatementImportOutboxException(
            'sensitive_field_forbidden',
          );
        }
        _rejectSecrets(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectSecrets(item);
      }
    } else if (value is num && !value.isFinite) {
      throw const StatementImportOutboxException('invalid_payload');
    }
  }

  static bool _isUuid(String value) =>
      RegExp(_uuidPattern, caseSensitive: false).hasMatch(value);
  static bool _isSha256(String value) =>
      RegExp(_sha256Pattern, caseSensitive: false).hasMatch(value);

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class _PreparedBatch {
  final int ordinal;
  final String importKey;
  final String digest;
  final int plaintextBytes;
  final Uint8List ciphertext;

  const _PreparedBatch({
    required this.ordinal,
    required this.importKey,
    required this.digest,
    required this.plaintextBytes,
    required this.ciphertext,
  });
}

class _SessionAccumulator {
  final String sessionId;
  final String state;
  final int batchCount;
  final int createdAtMs;
  final int expiresAtMs;
  int completedBatches = 0;
  int imported = 0;
  int pendingDuplicates = 0;
  int exactRetries = 0;

  _SessionAccumulator(Row row)
    : sessionId = row['session_id'] as String,
      state = row['state'] as String,
      batchCount = row['batch_count'] as int,
      createdAtMs = row['created_at_ms'] as int,
      expiresAtMs = row['expires_at_ms'] as int;

  void add(String? completedSummary) {
    if (completedSummary == null) return;
    final summary = jsonDecode(completedSummary) as Map<String, dynamic>;
    completedBatches++;
    imported += summary['imported'] as int;
    pendingDuplicates += summary['pendingDuplicates'] as int;
    exactRetries += summary['exactRetries'] as int;
  }

  StatementImportSessionSummary toSummary(int currentMs) =>
      StatementImportSessionSummary(
        sessionId: sessionId,
        state: state == 'pending' && expiresAtMs <= currentMs
            ? 'needs_review'
            : state,
        batchCount: batchCount,
        completedBatches: completedBatches,
        createdAtMs: createdAtMs,
        expiresAtMs: expiresAtMs,
        imported: imported,
        pendingDuplicates: pendingDuplicates,
        exactRetries: exactRetries,
      );
}
