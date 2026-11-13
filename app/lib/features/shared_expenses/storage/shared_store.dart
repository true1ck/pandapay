import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

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

/// Server refusals about names, kept on the failed command so the screen that
/// queued it can explain what to change.
const sharedNameCodes = {
  'member_name_taken',
  'friend_name_taken',
  'member_name_reserved',
};

/// A queued name command the server refused for good. [existingContextId] is
/// the chat the person already has when the code is `friend_name_taken`.
class SharedNameException implements Exception {
  final String code;
  final String? existingContextId;
  const SharedNameException(this.code, [this.existingContextId]);

  /// Parses `http_409:friend_name_taken:<uuid>` from a stored command.
  static SharedNameException? fromStored(String? errorCode) {
    if (errorCode == null) return null;
    final parts = errorCode.split(':');
    if (parts.length < 2 || !sharedNameCodes.contains(parts[1])) return null;
    return SharedNameException(
      parts[1],
      parts.length > 2 && sharedUuid(parts[2]) ? parts[2] : null,
    );
  }

  @override
  String toString() => 'Shared name refused: $code';
}

/// A command the server keeps answering with a temporary error (5xx, 408, 429,
/// retryable 409) is sent this many times and then handed to the person as
/// "not synced" instead of retrying for ever. An unreachable network never
/// counts: being offline is not the command's fault.
const sharedMaxAttempts = 10;

/// Set on a command that was waiting for another command (its context was
/// created in the same offline session) when that command was refused.
const sharedDependencyRejected = 'dependency_rejected';

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
  var _lastStamp = 0;
  var _stampSeeded = false;
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

  /// Real enqueue time that never repeats or goes backwards in this process, so
  /// two commands saved in the same millisecond still send in the order they
  /// were saved. A caller-supplied positive time is kept exactly.
  int _stamp(int requested) {
    // After a restart the wall clock may have gone back: never stamp below
    // what is already stored (WP-H2).
    if (!_stampSeeded) {
      _stampSeeded = true;
      final top = database.db
          .select(
            'SELECT MAX(created_at) AS m FROM shared_commands WHERE namespace=?',
            [namespace],
          )
          .single['m'];
      if (top is int && top > _lastStamp) _lastStamp = top;
    }
    if (requested > 0) {
      if (requested > _lastStamp) _lastStamp = requested;
      return requested;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastStamp = now > _lastStamp ? now : _lastStamp + 1;
    return _lastStamp;
  }

  /// The `context.create` for [contextId] that may still commit (queued, in
  /// flight, waiting to retry or for sign-in), or null.
  String? _unconfirmedCreate(String contextId) {
    final rows = database.db.select(
      "SELECT operation_id FROM shared_commands WHERE namespace=? AND context_id=? AND kind='context.create' AND state IN ('pending','sending','retry','awaitingAuth') LIMIT 1",
      [namespace, contextId],
    );
    return rows.isEmpty ? null : rows.single['operation_id'] as String;
  }

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
    // A command that names a context created earlier in this same offline
    // session cannot succeed before that create does (the server answers 403
    // for a context it has not seen), so it waits for the create's receipt.
    if (command.kind != 'context.create') {
      final create = _unconfirmedCreate(command.contextId);
      if (create != null && !dependsOn.contains(create)) {
        dependsOn = [...dependsOn, create];
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
        _stamp(createdAt),
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
    if (receipt.kind == 'context.create') _adoptOwnerMemberId(receipt);
    return true;
  });

  /// Commands queued against a group that was created offline name its owner
  /// by [sharedPendingOwnerMemberId]; now the server's real id is known, so
  /// rewrite them (same operation id, new bytes and hash) before they send.
  void _adoptOwnerMemberId(SharedOperationReceipt receipt) {
    final result = receipt.result;
    final real = result is Map ? result['memberId'] : null;
    if (!sharedUuid(real)) return;
    final stand = sharedPendingOwnerMemberId(receipt.contextId);
    final rows = database.db.select(
      "SELECT * FROM shared_commands WHERE namespace=? AND context_id=? AND state!='committed' AND instr(request_json,?)>0",
      [namespace, receipt.contextId, stand],
    );
    Object? swap(Object? v) => v is String
        ? (v == stand ? real : v)
        : v is List
        ? [for (final e in v) swap(e)]
        : v is Map
        ? {for (final e in v.entries) e.key: swap(e.value)}
        : v;
    for (final row in rows) {
      final next = SharedCommand.fromJson(
        swap(jsonDecode(row['request_json'] as String)),
      );
      // The immutability trigger guards UPDATEs; the row is replaced whole
      // (same key, same state, attempts and dependencies) in this transaction.
      final key = [namespace, row['operation_id']];
      database.db.execute(
        'DELETE FROM shared_commands WHERE namespace=? AND operation_id=?',
        key,
      );
      database.db.execute(
        'INSERT INTO shared_commands(namespace,operation_id,context_id,kind,request_json,request_hash,state,created_at,attempts,next_attempt,lease_id,lease_expires,error_code) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          namespace,
          row['operation_id'],
          row['context_id'],
          row['kind'],
          next.canonicalJson,
          next.requestHash,
          row['state'],
          row['created_at'],
          row['attempts'],
          row['next_attempt'],
          row['lease_id'],
          row['lease_expires'],
          row['error_code'],
        ],
      );
    }
  }
  Future<void> fail(
    SharedCommandClaim claim, {
    int? statusCode,
    bool retryable = false,
    String? serverCode,
    String? existingContextId,
    Duration? retryAfter,
    required int now,
  }) => _write(() {
    if (!_owns(claim)) return;
    // next_attempt==1 marks "made due early by resetBackoff": this try was not
    // sent after a real wait, so it must not use up the attempt budget
    // (~10 app opens during an outage would otherwise reject queued work).
    final earlyRetry =
        database.db
            .select(
              'SELECT next_attempt FROM shared_commands WHERE namespace=? AND operation_id=?',
              [namespace, claim.command.operationId],
            )
            .single['next_attempt'] ==
        _resetMarker;
    final previous = operation(claim.command.operationId)!.attempts;
    final attempts = statusCode != null && earlyRetry && previous > 0
        ? previous
        : previous + 1;
    // The server answers 403 for a context it has not seen yet exactly as for
    // one the person does not own. While this context's own create is still
    // on its way, that 403 is "not yet", not "never".
    final createPending =
        statusCode == 403 &&
        serverCode == 'context_not_authorized' &&
        claim.command.kind != 'context.create' &&
        _unconfirmedCreate(claim.command.contextId) != null;
    final transient =
        retryable ||
        createPending ||
        statusCode == null ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode >= 500;
    var state = statusCode == 409 && !retryable
        ? SharedCommandState.conflict
        : statusCode == 401
        ? SharedCommandState.awaitingAuth
        : transient
        ? SharedCommandState.retry
        : SharedCommandState.rejected;
    var error = statusCode == null
        ? 'network_unavailable'
        : 'http_$statusCode${sharedNameCodes.contains(serverCode) ? ':$serverCode${existingContextId != null && sharedUuid(existingContextId) ? ':$existingContextId' : ''}' : ''}';
    // A temporary server error is not retried for ever. The network being
    // unreachable (no status) never counts: that is not the command's fault.
    if (state == SharedCommandState.retry &&
        statusCode != null &&
        attempts >= sharedMaxAttempts) {
      state = SharedCommandState.rejected;
      error = 'retry_limit:$error';
    }
    var delay = 5000 * (1 << attempts.clamp(0, 6));
    if (retryAfter != null) {
      final asked = retryAfter.inMilliseconds.clamp(0, 3600000);
      if (asked > delay) delay = asked;
    }
    database.db.execute(
      'UPDATE shared_commands SET state=?,attempts=?,next_attempt=?,lease_id=NULL,lease_expires=0,error_code=? WHERE namespace=? AND operation_id=?',
      [
        state.name,
        attempts,
        now + delay,
        error,
        namespace,
        claim.command.operationId,
      ],
    );
    if (state == SharedCommandState.rejected ||
        state == SharedCommandState.conflict) {
      _rejectDependents(claim.command.operationId);
    }
  });

  /// Commands still waiting for [operationId] can never be sent once it is
  /// refused: refuse them too (listed under it, not as separate problems).
  void _rejectDependents(String operationId) {
    final queue = [operationId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final rows = database.db.select(
        "SELECT c.operation_id FROM shared_commands c JOIN shared_command_dependencies d ON d.namespace=c.namespace AND d.operation_id=c.operation_id WHERE c.namespace=? AND d.depends_on=? AND c.state IN ('pending','sending','retry','awaitingAuth')",
        [namespace, current],
      );
      for (final row in rows) {
        final id = row['operation_id'] as String;
        database.db.execute(
          "UPDATE shared_commands SET state='rejected',lease_id=NULL,lease_expires=0,error_code=? WHERE namespace=? AND operation_id=?",
          [sharedDependencyRejected, namespace, id],
        );
        queue.add(id);
      }
    }
  }

  /// A reconnect should not wait out a backoff earned while offline: queued
  /// rows become due now. Attempt counts are kept, so the cap still applies.
  static const _resetMarker = 1;
  Future<void> resetBackoff() => _write(
    () => database.db.execute(
      "UPDATE shared_commands SET next_attempt=$_resetMarker WHERE namespace=? AND state IN ('retry','pending') AND next_attempt>$_resetMarker",
      [namespace],
    ),
  );

  Future<void> resumeAuthentication() => _write(
    () => database.db.execute(
      "UPDATE shared_commands SET state='retry',next_attempt=0,error_code=NULL WHERE namespace=? AND state='awaitingAuth'",
      [namespace],
    ),
  );

  void _projections(List<SharedProjection> records) =>
      _projectionsTo(database.db, namespace, _projRows(records));

  String? get cursor => _cursorOf(database.db, namespace);

  Future<void> applyPage(
    SharedChangePage page, {
    required String? expectedCursor,
  }) => _write(
    () => _applyPageTo(
      database.db,
      namespace,
      _PagePlan.of(page, expectedCursor),
    ),
  );

  /// Same as [applyPage], but a file-backed database applies the page on a
  /// short-lived worker isolate with its own connection (the pattern the SMS
  /// capture and `FinancialReadWorker` already use), so a 100-record write no
  /// longer blocks frames. The page and its cursor still commit in one
  /// transaction, and the call stays inside the account-recovery gate so a
  /// recovery waits for it. In-memory/test databases cannot be opened by a
  /// second connection and take the synchronous path.
  Future<void> applyPageOffThread(
    SharedChangePage page, {
    required String? expectedCursor,
  }) {
    final path = database.filePath;
    if (path == null || page.records.length < 4) {
      return applyPage(page, expectedCursor: expectedCursor);
    }
    final plan = _PagePlan.of(page, expectedCursor);
    final key = database.keyHexForWorker, ns = namespace;
    return recoveryGate.run(() async {
      if (!isCurrent()) throw const SharedLocalException('account_changed');
      await _runPageInIsolate(path, key, ns, plan);
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
    });
  }

  static String? _cursorOf(Database db, String namespace) {
    final rows = db.select(
      "SELECT value FROM shared_sync_state WHERE namespace=? AND key='cursor'",
      [namespace],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  // Static on purpose: the closure must not capture `this`, which holds the
  // native database handle and cannot cross to another isolate.
  static Future<void> _runPageInIsolate(
    String path,
    String? keyHex,
    String namespace,
    _PagePlan plan,
  ) => Isolate.run(() => _applyPageInIsolate(path, keyHex, namespace, plan));

  // Runs in the worker isolate: open, apply in one transaction, close.
  static void _applyPageInIsolate(
    String path,
    String? keyHex,
    String namespace,
    _PagePlan plan,
  ) {
    final connection = keyHex == null
        ? AppDatabase.openUnencryptedFileForTesting(path)
        : AppDatabase.openFile(path, keyHex: keyHex);
    try {
      final db = connection.db;
      db.execute('BEGIN IMMEDIATE');
      try {
        _applyPageTo(db, namespace, plan);
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      connection.db.dispose();
    }
  }

  static void _applyPageTo(Database db, String namespace, _PagePlan plan) {
    if (_cursorOf(db, namespace) != plan.expectedCursor) {
      throw const SharedLocalException('cursor_changed');
    }
    if (plan.hasMore && plan.nextCursor == plan.expectedCursor) {
      throw const SharedLocalException('cursor_not_advancing');
    }
    for (final id in plan.revoked) {
      db.execute(
        'DELETE FROM shared_projections WHERE namespace=? AND context_id=?',
        [namespace, id],
      );
      db.execute(
        "INSERT INTO shared_sync_state VALUES(?,?,'1') ON CONFLICT(namespace,key) DO UPDATE SET value='1'",
        [namespace, 'revoked:$id'],
      );
    }
    // Fresh authorized grant pages can arrive over several bounded pulls.
    // Rows remain quarantined behind the durable tombstone until the server's
    // terminal grant marker; no bulk copy or per-row network lookup is needed.
    _projectionsTo(db, namespace, plan.rows);
    for (final id in plan.granted) {
      db.execute('DELETE FROM shared_sync_state WHERE namespace=? AND key=?', [
        namespace,
        'revoked:$id',
      ]);
    }
    if (plan.nextCursor == null) {
      db.execute(
        "DELETE FROM shared_sync_state WHERE namespace=? AND key='cursor'",
        [namespace],
      );
    } else {
      db.execute(
        "INSERT INTO shared_sync_state VALUES(?,'cursor',?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value",
        [namespace, plan.nextCursor],
      );
    }
  }

  static void _projectionsTo(
    Database db,
    String namespace,
    List<_ProjRow> records,
  ) {
    // The change feed emits one row per event, so one page can repeat a key.
    // Keep the highest revision (the last when equal); two different payloads
    // at one revision is a real conflict.
    final latest = <String, _ProjRow>{};
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
      final previous = db.select(
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
      db.execute(
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

  static const _attentionWhere =
      "c.namespace=? AND c.state IN ('rejected','conflict') AND coalesce(c.error_code,'')!='$sharedDependencyRejected' AND NOT EXISTS(SELECT 1 FROM shared_sync_state s WHERE s.namespace=c.namespace AND s.key='revoked:'||c.context_id)";

  /// Commands the server refused for good (or kept failing on): what the
  /// person has to look at. A command refused only because the one it waited
  /// on was refused is folded into that one and not counted again.
  int get attentionCount =>
      database.db.select(
            'SELECT COUNT(*) AS n FROM shared_commands c WHERE $_attentionWhere',
            [namespace],
          ).single['n']
          as int;

  /// Oldest first, so the list reads in the order things were saved.
  List<SharedQueuedCommand> readAttention({int limit = 100}) {
    if (limit < 1 || limit > 100) {
      throw const SharedLocalException('invalid_query');
    }
    final rows = database.db.select(
      'SELECT c.* FROM shared_commands c WHERE $_attentionWhere ORDER BY c.created_at,c.operation_id LIMIT ?',
      [namespace, limit],
    );
    return List.unmodifiable([
      for (final row in rows)
        SharedQueuedCommand(
          _command(row),
          SharedCommandState.values.byName(row['state'] as String),
          row['attempts'] as int,
          row['error_code'] as String?,
        ),
    ]);
  }

  /// [operationId] plus every command refused only because it waited on it.
  List<String> _withDependents(String operationId) {
    final out = [operationId];
    for (var i = 0; i < out.length; i++) {
      final rows = database.db.select(
        "SELECT c.operation_id FROM shared_commands c JOIN shared_command_dependencies d ON d.namespace=c.namespace AND d.operation_id=c.operation_id WHERE c.namespace=? AND d.depends_on=? AND c.state='rejected' AND c.error_code=?",
        [namespace, out[i], sharedDependencyRejected],
      );
      for (final row in rows) {
        final id = row['operation_id'] as String;
        if (!out.contains(id)) out.add(id);
      }
    }
    return out;
  }

  /// Retry: puts a refused command back in the queue with a fresh attempt
  /// budget. The stored bytes, operation id and hash do not change, so the
  /// server replays rather than duplicates it. False when it is not refused.
  Future<bool> requeue(String operationId) => _write(() {
    final queued = operation(operationId);
    if (queued == null ||
        (queued.state != SharedCommandState.rejected &&
            queued.state != SharedCommandState.conflict)) {
      return false;
    }
    for (final id in _withDependents(operationId)) {
      database.db.execute(
        "UPDATE shared_commands SET state='pending',attempts=0,next_attempt=0,lease_id=NULL,lease_expires=0,error_code=NULL WHERE namespace=? AND operation_id=?",
        [namespace, id],
      );
    }
    return true;
  });

  /// Discard: forgets a refused command (and any that waited on it) together
  /// with its on-phone preview. False when it is not refused.
  Future<bool> discard(String operationId) => _write(() {
    final queued = operation(operationId);
    if (queued == null ||
        (queued.state != SharedCommandState.rejected &&
            queued.state != SharedCommandState.conflict)) {
      return false;
    }
    for (final id in _withDependents(operationId)) {
      final db = database.db;
      db.execute(
        'DELETE FROM shared_provisional WHERE namespace=? AND operation_id=?',
        [namespace, id],
      );
      db.execute(
        'DELETE FROM shared_command_dependencies WHERE namespace=? AND (operation_id=? OR depends_on=?)',
        [namespace, id, id],
      );
      db.execute(
        'DELETE FROM shared_source_dependencies WHERE namespace=? AND operation_id=?',
        [namespace, id],
      );
      db.execute(
        'DELETE FROM shared_editor_receipts WHERE namespace=? AND draft_id=?',
        [namespace, id],
      );
      db.execute(
        'DELETE FROM shared_commands WHERE namespace=? AND operation_id=?',
        [namespace, id],
      );
    }
    return true;
  });

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

/// Plain, sendable copy of one projection row for the worker isolate.
final class _ProjRow {
  final String contextId, entity, id, canonicalJson;
  final int revision;
  final bool deleted;
  const _ProjRow(
    this.contextId,
    this.entity,
    this.id,
    this.revision,
    this.canonicalJson,
    this.deleted,
  );
}

List<_ProjRow> _projRows(List<SharedProjection> records) => [
  for (final r in records)
    _ProjRow(
      r.contextId,
      r.entity,
      r.id,
      r.revision,
      r.canonicalJson,
      r.deleted,
    ),
];

/// Everything `applyPage` needs, as plain data that can cross isolates.
final class _PagePlan {
  final List<_ProjRow> rows;
  final List<String> revoked, granted;
  final String? nextCursor, expectedCursor;
  final bool hasMore;
  const _PagePlan(
    this.rows,
    this.revoked,
    this.granted,
    this.nextCursor,
    this.expectedCursor,
    this.hasMore,
  );
  factory _PagePlan.of(SharedChangePage page, String? expectedCursor) =>
      _PagePlan(
        _projRows(page.records),
        List.of(page.revokedContextIds),
        List.of(page.grantedContextIds),
        page.nextCursor,
        expectedCursor,
        page.hasMore,
      );
}
