import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';

import '../../../data/local/app_database.dart';
import '../../../data/portable_backup/account_recovery_operation_gate.dart';
import '../data/shared_commands.dart';
import 'shared_schema.dart';

enum SharedCommandState {
  pending,
  sending,
  retry,
  conflict,
  awaitingAuth,
  rejected,
  committed,
}

class SharedLocalException implements Exception {
  final String code;
  const SharedLocalException(this.code);
  @override
  String toString() => 'Shared local operation: $code';
}

final class SharedQueuedCommand {
  final SharedCommand command;
  final SharedCommandState state;
  final int attempts;
  final String? errorCode;
  final String? _provisionalJson;
  const SharedQueuedCommand(
    this.command,
    this.state,
    this.attempts,
    this.errorCode, [
    this._provisionalJson,
  ]);
  Map<String, Object?>? get provisional => _provisionalJson == null
      ? null
      : Map<String, Object?>.from(jsonDecode(_provisionalJson) as Map);
}

final class SharedPendingPage {
  final List<SharedQueuedCommand> items;
  final String? nextId;
  const SharedPendingPage(this.items, this.nextId);
}

final class SharedCommandClaim {
  final SharedCommand command;
  final String leaseId;
  const SharedCommandClaim(this.command, this.leaseId);
}

final class SharedStoredPage {
  final List<SharedProjection> items;
  final String? nextId;
  const SharedStoredPage(this.items, this.nextId);
}

/// Private attachment retained only as part of a submitted expense.
final class SharedSubmissionReceipt {
  final String hash, name;
  final String? mimeType;
  final Uint8List bytes;
  SharedSubmissionReceipt({
    required this.name,
    this.mimeType,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       hash = sha256.convert(bytes).toString() {
    if (bytes.isEmpty ||
        bytes.length > 8388608 ||
        name.trim().isEmpty ||
        name.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        mimeType != null &&
            (mimeType!.length > 128 ||
                !RegExp(
                  r'^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$',
                ).hasMatch(mimeType!))) {
      throw const SharedLocalException('invalid_receipt');
    }
  }
}

/// Durable account-bound storage. Immutable wire payloads are distinct from
/// retry/lease metadata and private provisional overlays. Never coalesces money.
class SharedExpensesStore {
  final AppDatabase database;
  final String namespace;
  final AccountRecoveryOperationGate recoveryGate;
  final bool Function() isCurrent;
  final void Function()? onChanged;
  var _sequence = 0;
  SharedExpensesStore(
    this.database, {
    required this.namespace,
    AccountRecoveryOperationGate? recoveryGate,
    bool Function()? isCurrent,
    this.onChanged,
  }) : recoveryGate = recoveryGate ?? AccountRecoveryOperationGate.process,
       isCurrent = isCurrent ?? _alwaysCurrent {
    if (!namespace.startsWith('user:') ||
        namespace.length > 256 ||
        namespace.length <= 5) {
      throw ArgumentError.value(namespace, 'namespace');
    }
    if (this.recoveryGate.isRecovering) throw const AccountRecoveryBusy();
    SharedExpensesSchema.ensure(database.db);
    // Old backups may contain abandoned forms. Remove only unsubmitted input;
    // immutable commands, receipts and original bank transactions stay intact.
    SharedExpensesSchema.discardUnsubmittedEditors(database.db, namespace);
  }
  static bool _alwaysCurrent() => true;
  Future<T> _write<T>(T Function() action) => recoveryGate.run(() async {
    if (!isCurrent()) throw const SharedLocalException('account_changed');
    final name = 'shared_write_${_sequence++}';
    database.db.execute('SAVEPOINT $name');
    late final T result;
    try {
      result = action();
      database.db.execute('RELEASE $name');
    } catch (_) {
      database.db.execute('ROLLBACK TO $name');
      database.db.execute('RELEASE $name');
      rethrow;
    }
    // Observers run after commit and cannot turn durable success into an error
    // that encourages the UI to submit another financial operation.
    try {
      onChanged?.call();
    } catch (_, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: const SharedLocalException('change_listener_failed'),
          stack: stack,
          library: 'shared expenses store',
        ),
      );
    }
    return result;
  });
  SharedCommand _command(Map<String, Object?> row) {
    final command = SharedCommand.fromJson(
      jsonDecode(row['request_json'] as String),
    );
    if (command.requestHash != row['request_hash'] ||
        command.contextId != row['context_id']) {
      throw const SharedLocalException('stored_command_corrupt');
    }
    return command;
  }

  SharedQueuedCommand? operation(String operationId) {
    final rows = database.db.select(
      'SELECT * FROM shared_commands WHERE namespace=? AND operation_id=?',
      [namespace, operationId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SharedQueuedCommand(
      _command(row),
      SharedCommandState.values.byName(row['state'] as String),
      row['attempts'] as int,
      row['error_code'] as String?,
    );
  }

  int get pendingCount =>
      database.db.select(
            "SELECT COUNT(*) AS n FROM shared_commands WHERE namespace=? AND state!='committed'",
            [namespace],
          ).single['n']
          as int;

  /// Commands still on their way to the server. A command the server refused
  /// for good ('rejected' or 'conflict') will never send, so it is not "syncing".
  int get waitingCount =>
      database.db.select(
            "SELECT COUNT(*) AS n FROM shared_commands WHERE namespace=? AND state NOT IN ('committed','rejected','conflict')",
            [namespace],
          ).single['n']
          as int;
  Map<String, Object?>? provisional(String operationId) {
    final queued = operation(operationId);
    if (queued != null && isContextRevoked(queued.command.contextId)) {
      return null;
    }
    final rows = database.db.select(
      'SELECT payload FROM shared_provisional WHERE namespace=? AND operation_id=?',
      [namespace, operationId],
    );
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(
            jsonDecode(rows.single['payload'] as String) as Map,
          );
  }

  SharedOperationReceipt? receipt(String operationId) {
    final rows = database.db.select(
      'SELECT receipt_json FROM shared_operation_receipts WHERE namespace=? AND operation_id=?',
      [namespace, operationId],
    );
    if (rows.isEmpty) return null;
    final value = SharedOperationReceipt.fromJson(
      jsonDecode(rows.single['receipt_json'] as String),
    );
    return isContextRevoked(value.contextId) ? null : value;
  }

  Future<void> enqueue(
    SharedCommand command, {
    List<String> dependsOn = const [],
    List<String> sourceDependencies = const [],
    Map<String, Object?>? provisional,
    int createdAt = 0,
  }) => _write(
    () => _enqueue(
      command,
      dependsOn: dependsOn,
      sourceDependencies: sourceDependencies,
      provisional: provisional,
      createdAt: createdAt,
    ),
  );

  void _enqueue(
    SharedCommand command, {
    List<String> dependsOn = const [],
    List<String> sourceDependencies = const [],
    Map<String, Object?>? provisional,
    int createdAt = 0,
  }) {
    if (dependsOn.length > 100 ||
        sourceDependencies.length > 100 ||
        dependsOn.toSet().length != dependsOn.length ||
        sourceDependencies.toSet().length != sourceDependencies.length) {
      throw const SharedLocalException('dependency_limit');
    }
    final existing = operation(command.operationId);
    if (existing != null) {
      if (existing.command.canonicalJson != command.canonicalJson) {
        throw const SharedLocalException('operation_reuse');
      }
      return;
    }
    for (final id in dependsOn) {
      if (!sharedUuid(id) ||
          id == command.operationId ||
          operation(id) == null) {
        throw const SharedLocalException('invalid_dependency');
      }
    }
    for (final key in sourceDependencies) {
      if (key.isEmpty || key.length > 256) {
        throw const SharedLocalException('invalid_source_dependency');
      }
    }
    final overlay = provisional == null
        ? null
        : sharedCanonicalJson(provisional);
    database.db.execute(
      'INSERT INTO shared_commands(namespace,operation_id,context_id,kind,request_json,request_hash,created_at) VALUES(?,?,?,?,?,?,?)',
      [
        namespace,
        command.operationId,
        command.contextId,
        command.kind,
        command.canonicalJson,
        command.requestHash,
        createdAt,
      ],
    );
    for (final id in dependsOn) {
      database.db.execute(
        'INSERT INTO shared_command_dependencies VALUES(?,?,?)',
        [namespace, command.operationId, id],
      );
    }
    for (final key in sourceDependencies) {
      database.db.execute(
        'INSERT INTO shared_source_dependencies VALUES(?,?,?,0)',
        [namespace, command.operationId, key],
      );
    }
    if (overlay != null) {
      database.db.execute('INSERT INTO shared_provisional VALUES(?,?,?,?)', [
        namespace,
        command.operationId,
        command.contextId,
        overlay,
      ]);
    }
  }

  Future<void> enqueueFriendSetup(
    SharedCommand context,
    SharedCommand member,
  ) => _write(() {
    if (context.kind != 'context.create' ||
        member.kind != 'member.invite' ||
        context.contextId != member.contextId) {
      throw const SharedLocalException('invalid_friend_setup');
    }
    _enqueue(context);
    _enqueue(member, dependsOn: [context.operationId]);
  });

  /// Submit once: command, private preview and optional receipt commit together.
  /// The legacy receipt table/column names are retained for backup compatibility.
  Future<void> enqueueExpenseSubmission(
    SharedCommand command, {
    required Map<String, Object?> provisional,
    SharedSubmissionReceipt? receipt,
    int createdAt = 0,
  }) => _write(() {
    if (command.kind != 'expense.propose' ||
        isContextRevoked(command.contextId)) {
      throw const SharedLocalException('invalid_submission');
    }
    final existing = operation(command.operationId);
    _enqueue(command, provisional: provisional, createdAt: createdAt);
    if (existing != null) {
      if (receipt != null &&
          submissionReceipt(command.operationId, receipt.hash) == null) {
        throw const SharedLocalException('submission_reuse');
      }
      return;
    }
    if (receipt == null) return;
    final usage = database.db.select(
      'SELECT count(*) n,coalesce(sum(length(bytes)),0) size FROM shared_editor_receipts WHERE namespace=?',
      [namespace],
    ).single;
    if ((usage['n'] as int) >= 256 ||
        (usage['size'] as int) + receipt.bytes.length > 134217728) {
      throw const SharedLocalException('receipt_storage_limit');
    }
    database.db
        .execute('INSERT INTO shared_editor_receipts VALUES(?,?,?,?,?,?)', [
          namespace,
          command.operationId,
          receipt.hash,
          receipt.name,
          receipt.mimeType,
          receipt.bytes,
        ]);
  });

  SharedSubmissionReceipt? submissionReceipt(String operationId, String hash) {
    if (!isCurrent()) throw const SharedLocalException('account_changed');
    final queued = operation(operationId);
    if (queued == null || isContextRevoked(queued.command.contextId))
      return null;
    final rows = database.db.select(
      'SELECT name,mime_type,bytes FROM shared_editor_receipts WHERE namespace=? AND draft_id=? AND hash=?',
      [namespace, operationId, hash],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final receipt = SharedSubmissionReceipt(
      name: row['name'] as String,
      mimeType: row['mime_type'] as String?,
      bytes: row['bytes'] as Uint8List,
    );
    if (receipt.hash != hash)
      throw const SharedLocalException('receipt_corrupt');
    return receipt;
  }

  /// Resolves only a durable scheduling dependency. It never changes the source
  /// identity, payload, hash or operation ID; submitting a different expense needs
  /// a new explicit command and operation ID.
  Future<void> resolveSourceDependency(String key) => _write(
    () => database.db.execute(
      'UPDATE shared_source_dependencies SET resolved=1 WHERE namespace=? AND source_key=?',
      [namespace, key],
    ),
  );

  Future<SharedCommandClaim?> claim({
    required int now,
    required String leaseId,
    int leaseDurationMs = 60000,
  }) => _write(() {
    if (leaseId.isEmpty ||
        leaseId.length > 128 ||
        leaseDurationMs < 1 ||
        leaseDurationMs > 300000) {
      throw const SharedLocalException('invalid_lease');
    }
    // A previous crash leaves sending rows leased. Only expired leases may be
    // reclaimed, with their original operation/request bytes intact.
    final rows = database.db.select(
      '''SELECT c.* FROM shared_commands c
WHERE c.namespace=? AND c.next_attempt<=?
AND (c.state IN ('pending','retry') OR (c.state='sending' AND c.lease_expires<=?))
AND NOT EXISTS(SELECT 1 FROM shared_source_dependencies s WHERE s.namespace=c.namespace AND s.operation_id=c.operation_id AND s.resolved=0)
AND NOT EXISTS(SELECT 1 FROM shared_sync_state x WHERE x.namespace=c.namespace AND x.key='revoked:'||c.context_id)
AND NOT EXISTS(SELECT 1 FROM shared_command_dependencies d LEFT JOIN shared_operation_receipts r ON r.namespace=d.namespace AND r.operation_id=d.depends_on WHERE d.namespace=c.namespace AND d.operation_id=c.operation_id AND r.operation_id IS NULL)
ORDER BY c.created_at,c.operation_id LIMIT 1''',
      [namespace, now, now],
    );
    if (rows.isEmpty) return null;
    final command = _command(rows.single);
    // Unique per acquisition: a restarted worker may reuse its label, but a
    // late response from an expired lease must never own the replacement lease.
    final random = Random.secure();
    final token =
        '$leaseId:${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    database.db.execute(
      "UPDATE shared_commands SET state='sending',lease_id=?,lease_expires=? WHERE namespace=? AND operation_id=?",
      [token, now + leaseDurationMs, namespace, command.operationId],
    );
    return SharedCommandClaim(command, token);
  });
  bool _owns(SharedCommandClaim claim) => database.db.select(
    "SELECT 1 FROM shared_commands WHERE namespace=? AND operation_id=? AND state='sending' AND lease_id=? AND request_hash=?",
    [
      namespace,
      claim.command.operationId,
      claim.leaseId,
      claim.command.requestHash,
    ],
  ).isNotEmpty;

  Future<bool> complete(
    SharedCommandClaim claim,
    SharedOperationReceipt receipt,
    List<SharedProjection> records,
  ) => _write(() {
    if (!_owns(claim) || isContextRevoked(claim.command.contextId)) {
      return false;
    }
    if (receipt.operationId != claim.command.operationId ||
        receipt.kind != claim.command.kind ||
        receipt.requestHash != claim.command.requestHash ||
        receipt.contextId != claim.command.contextId) {
      throw const SharedLocalException('receipt_mismatch');
    }
    if (records.length > 100 ||
        records.any((row) => row.contextId != receipt.contextId)) {
      throw const SharedLocalException('projection_scope');
    }
    final receiptJson = sharedCanonicalJson(receipt.toJson(), maxBytes: 262144);
    final retained = database.db.select(
      'SELECT request_hash,receipt_json FROM shared_operation_receipts WHERE namespace=? AND operation_id=?',
      [namespace, receipt.operationId],
    );
    if (retained.isNotEmpty &&
        (retained.single['request_hash'] != receipt.requestHash ||
            retained.single['receipt_json'] != receiptJson)) {
      throw const SharedLocalException('receipt_conflict');
    }
    _projections(records);
    if (retained.isEmpty) {
      database.db.execute(
        'INSERT INTO shared_operation_receipts VALUES(?,?,?,?)',
        [namespace, receipt.operationId, receipt.requestHash, receiptJson],
      );
    }
    database.db.execute(
      "UPDATE shared_commands SET state='committed',lease_id=NULL,lease_expires=0,error_code=NULL WHERE namespace=? AND operation_id=?",
      [namespace, receipt.operationId],
    );
    database.db.execute(
      'DELETE FROM shared_provisional WHERE namespace=? AND operation_id=?',
      [namespace, receipt.operationId],
    );
    return true;
  });
  Future<void> fail(
    SharedCommandClaim claim, {
    int? statusCode,
    bool retryable = false,
    required int now,
  }) => _write(() {
    if (!_owns(claim)) return;
    final attempts = operation(claim.command.operationId)!.attempts + 1;
    final transient =
        retryable ||
        statusCode == null ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode >= 500;
    final state = statusCode == 409 && !retryable
        ? SharedCommandState.conflict
        : statusCode == 401
        ? SharedCommandState.awaitingAuth
        : transient
        ? SharedCommandState.retry
        : SharedCommandState.rejected;
    final delay = 5000 * (1 << attempts.clamp(0, 6));
    database.db.execute(
      'UPDATE shared_commands SET state=?,attempts=?,next_attempt=?,lease_id=NULL,lease_expires=0,error_code=? WHERE namespace=? AND operation_id=?',
      [
        state.name,
        attempts,
        now + delay,
        statusCode == null ? 'network_unavailable' : 'http_$statusCode',
        namespace,
        claim.command.operationId,
      ],
    );
  });
  Future<void> resumeAuthentication() => _write(
    () => database.db.execute(
      "UPDATE shared_commands SET state='retry',next_attempt=0,error_code=NULL WHERE namespace=? AND state='awaitingAuth'",
      [namespace],
    ),
  );

  void _projections(List<SharedProjection> records) {
    // The change feed emits one row per event, so one page can repeat a key.
    // Keep the highest revision (the last when equal); two different payloads
    // at one revision is a real conflict.
    final latest = <String, SharedProjection>{};
    for (final row in records) {
      final key = '${row.contextId}:${row.entity}:${row.id}';
      final held = latest[key];
      if (held != null && held.revision == row.revision) {
        if (held.canonicalJson != row.canonicalJson ||
            held.deleted != row.deleted) {
          throw const SharedLocalException('projection_revision_conflict');
        }
      }
      if (held == null || row.revision >= held.revision) latest[key] = row;
    }
    for (final row in latest.values) {
      final previous = database.db.select(
        'SELECT revision,payload,deleted FROM shared_projections WHERE namespace=? AND context_id=? AND entity=? AND id=?',
        [namespace, row.contextId, row.entity, row.id],
      );
      if (previous.isNotEmpty) {
        final old = previous.single;
        if (old['revision'] == row.revision &&
            (old['payload'] != row.canonicalJson ||
                old['deleted'] != (row.deleted ? 1 : 0))) {
          throw const SharedLocalException('projection_revision_conflict');
        }
        if ((old['revision'] as int) >= row.revision) continue;
      }
      database.db.execute(
        'INSERT INTO shared_projections VALUES(?,?,?,?,?,?,?) ON CONFLICT(namespace,context_id,entity,id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload,deleted=excluded.deleted',
        [
          namespace,
          row.contextId,
          row.entity,
          row.id,
          row.revision,
          row.canonicalJson,
          row.deleted ? 1 : 0,
        ],
      );
    }
  }

  String? get cursor {
    final rows = database.db.select(
      "SELECT value FROM shared_sync_state WHERE namespace=? AND key='cursor'",
      [namespace],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> applyPage(
    SharedChangePage page, {
    required String? expectedCursor,
  }) => _write(() {
    if (cursor != expectedCursor) {
      throw const SharedLocalException('cursor_changed');
    }
    if (page.hasMore && page.nextCursor == expectedCursor) {
      throw const SharedLocalException('cursor_not_advancing');
    }
    for (final id in page.revokedContextIds) {
      database.db.execute(
        'DELETE FROM shared_projections WHERE namespace=? AND context_id=?',
        [namespace, id],
      );
      database.db.execute(
        "INSERT INTO shared_sync_state VALUES(?,?,'1') ON CONFLICT(namespace,key) DO UPDATE SET value='1'",
        [namespace, 'revoked:$id'],
      );
    }
    // Fresh authorized grant pages can arrive over several bounded pulls.
    // Rows remain quarantined behind the durable tombstone until the server's
    // terminal grant marker; no bulk copy or per-row network lookup is needed.
    _projections(page.records);
    for (final id in page.grantedContextIds) {
      database.db.execute(
        'DELETE FROM shared_sync_state WHERE namespace=? AND key=?',
        [namespace, 'revoked:$id'],
      );
    }
    if (page.nextCursor == null) {
      database.db.execute(
        "DELETE FROM shared_sync_state WHERE namespace=? AND key='cursor'",
        [namespace],
      );
    } else {
      database.db.execute(
        "INSERT INTO shared_sync_state VALUES(?,'cursor',?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value",
        [namespace, page.nextCursor],
      );
    }
  });
  SharedStoredPage readPage({
    required String entity,
    required String contextId,
    String? afterId,
    int limit = 50,
  }) {
    if (!sharedProjectionEntities.contains(entity) ||
        !sharedUuid(contextId) ||
        limit < 1 ||
        limit > 100 ||
        afterId != null && afterId.length > 128) {
      throw const SharedLocalException('invalid_query');
    }
    if (isContextRevoked(contextId)) return const SharedStoredPage([], null);
    final rows = database.db.select(
      'SELECT * FROM shared_projections WHERE namespace=? AND context_id=? AND entity=? AND deleted=0 AND id>? ORDER BY id LIMIT ?',
      [namespace, contextId, entity, afterId ?? '', limit + 1],
    );
    final items = [
      for (final row in rows.take(limit))
        SharedProjection(
          entity: row['entity'] as String,
          id: row['id'] as String,
          contextId: row['context_id'] as String,
          revision: row['revision'] as int,
          payload: jsonDecode(row['payload'] as String),
        ),
    ];
    return SharedStoredPage(
      List.unmodifiable(items),
      rows.length > limit ? items.last.id : null,
    );
  }

  /// Hub-only accepted context overview. The supporting SQL index bounds reads
  /// before JSON materialization; other entities still require a context ID.
  SharedStoredPage readContexts({String? afterId, int limit = 50}) {
    if (limit < 1 || limit > 100 || afterId != null && afterId.length > 128) {
      throw const SharedLocalException('invalid_query');
    }
    final rows = database.db.select(
      "SELECT p.* FROM shared_projections p WHERE p.namespace=? AND p.entity='contexts' AND p.deleted=0 AND p.id>? AND NOT EXISTS(SELECT 1 FROM shared_sync_state s WHERE s.namespace=p.namespace AND s.key='revoked:'||p.context_id) ORDER BY p.id LIMIT ?",
      [namespace, afterId ?? '', limit + 1],
    );
    final items = [
      for (final row in rows.take(limit))
        SharedProjection(
          entity: 'contexts',
          id: row['id'] as String,
          contextId: row['context_id'] as String,
          revision: row['revision'] as int,
          payload: jsonDecode(row['payload'] as String),
        ),
    ];
    return SharedStoredPage(
      List.unmodifiable(items),
      rows.length > limit ? items.last.id : null,
    );
  }

  SharedPendingPage readPendingOperations({
    String? contextId,
    String? afterId,
    int limit = 50,
  }) {
    if (limit < 1 ||
        limit > 100 ||
        contextId != null && !sharedUuid(contextId) ||
        afterId != null && !sharedUuid(afterId)) {
      throw const SharedLocalException('invalid_query');
    }
    final rows = database.db.select(
      '''SELECT c.*,p.payload AS provisional_json FROM shared_commands c
LEFT JOIN shared_provisional p ON p.namespace=c.namespace AND p.operation_id=c.operation_id
WHERE c.namespace=? AND c.state!='committed' AND c.operation_id>?
AND NOT EXISTS(SELECT 1 FROM shared_sync_state s WHERE s.namespace=c.namespace AND s.key='revoked:'||c.context_id)
${contextId == null ? '' : 'AND c.context_id=?'} ORDER BY c.operation_id LIMIT ?''',
      [namespace, afterId ?? '', ?contextId, limit + 1],
    );
    final items = [
      for (final row in rows.take(limit))
        SharedQueuedCommand(
          _command(row),
          SharedCommandState.values.byName(row['state'] as String),
          row['attempts'] as int,
          row['error_code'] as String?,
          row['provisional_json'] as String?,
        ),
    ];
    return SharedPendingPage(
      List.unmodifiable(items),
      rows.length > limit ? items.last.command.operationId : null,
    );
  }

  bool isContextRevoked(String contextId) => database.db.select(
    'SELECT 1 FROM shared_sync_state WHERE namespace=? AND key=?',
    [namespace, 'revoked:$contextId'],
  ).isNotEmpty;

  /// An authenticated read denial may precede the change-feed revocation.
  /// Fence this scope without inventing or advancing its feed cursor.
  Future<void> revokeContext(String contextId) => _write(() {
    if (!sharedUuid(contextId)) {
      throw const SharedLocalException('invalid_context');
    }
    database.db.execute(
      'DELETE FROM shared_projections WHERE namespace=? AND context_id=?',
      [namespace, contextId],
    );
    database.db.execute(
      "INSERT INTO shared_sync_state VALUES(?,?,'1') ON CONFLICT(namespace,key) DO UPDATE SET value='1'",
      [namespace, 'revoked:$contextId'],
    );
  });
}
